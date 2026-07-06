//! OctoPrint REST driver (docs.octoprint.org): auth via `X-Api-Key`; job state from
//! `GET /api/job`; control via `POST /api/job`; upload via multipart `POST /api/files/local`.
//! Polling only in v1 (the SockJS push socket needs a passive-login flow — documented R2).

use crate::driver::{CameraSource, Capabilities, FileRef, PrinterDriver, PrinterState, PrinterStatus};
use serde_json::{json, Value};
use std::path::Path;
use std::time::Duration;

pub struct OctoPrinter {
    base: String,
    api_key: String,
    client: reqwest::blocking::Client,
}

impl OctoPrinter {
    /// `host` may be `ip[:port]` or a full `http://…` base URL.
    pub fn new(host: &str, api_key: impl Into<String>) -> Self {
        let base = if host.starts_with("http") {
            host.trim_end_matches('/').to_string()
        } else {
            format!("http://{host}")
        };
        Self {
            base,
            api_key: api_key.into(),
            client: reqwest::blocking::Client::builder()
                .timeout(Duration::from_secs(20))
                .build()
                .expect("http client"),
        }
    }

    fn get(&self, path: &str) -> Result<Value, String> {
        let resp = self
            .client
            .get(format!("{}{path}", self.base))
            .header("X-Api-Key", &self.api_key)
            .send()
            .map_err(|e| format!("octoprint unreachable: {e}"))?;
        if !resp.status().is_success() {
            return Err(format!("octoprint {path}: HTTP {}", resp.status()));
        }
        resp.json().map_err(|e| format!("octoprint {path}: bad json: {e}"))
    }

    fn post_job(&self, body: Value) -> Result<(), String> {
        let resp = self
            .client
            .post(format!("{}/api/job", self.base))
            .header("X-Api-Key", &self.api_key)
            .json(&body)
            .send()
            .map_err(|e| format!("octoprint unreachable: {e}"))?;
        if resp.status().is_success() || resp.status().as_u16() == 204 {
            Ok(())
        } else {
            Err(format!("octoprint job command failed: HTTP {}", resp.status()))
        }
    }

    fn map_state(text: &str, flags: Option<&Value>) -> PrinterState {
        let get = |k: &str| flags.and_then(|f| f.get(k)).and_then(|v| v.as_bool()).unwrap_or(false);
        if get("error") || get("closedOrError") && !get("operational") {
            // closedOrError also covers "no printer connected" — treat as error only with text hint
            if text.to_lowercase().contains("error") {
                return PrinterState::Error;
            }
            return PrinterState::Offline;
        }
        if get("paused") || get("pausing") {
            return PrinterState::Paused;
        }
        if get("cancelling") {
            return PrinterState::Stopping;
        }
        if get("printing") {
            return PrinterState::Printing;
        }
        if get("operational") {
            return PrinterState::Idle;
        }
        match text.to_lowercase().as_str() {
            t if t.contains("printing") => PrinterState::Printing,
            t if t.contains("paus") => PrinterState::Paused,
            t if t.contains("operational") => PrinterState::Idle,
            t if t.contains("error") => PrinterState::Error,
            t if t.contains("offline") || t.contains("closed") => PrinterState::Offline,
            _ => PrinterState::Unknown,
        }
    }
}

impl PrinterDriver for OctoPrinter {
    fn kind(&self) -> &'static str {
        "octoprint"
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities { upload: true, start: true, pause: true, resume: true, cancel: true, camera: true }
    }

    fn status(&self) -> Result<PrinterStatus, String> {
        let job = match self.get("/api/job") {
            Ok(v) => v,
            Err(e) if e.contains("unreachable") => return Ok(PrinterStatus::offline()),
            Err(e) => return Err(e),
        };
        let text = job.get("state").and_then(|v| v.as_str()).unwrap_or("");
        // /api/job's state is a string; the flags live on /api/printer — one extra call, best-effort.
        let flags = self
            .get("/api/printer?exclude=temperature,sd")
            .ok()
            .and_then(|p| p.get("state").and_then(|s| s.get("flags")).cloned());
        let state = Self::map_state(text, flags.as_ref());
        let progress = job
            .get("progress")
            .and_then(|p| p.get("completion"))
            .and_then(|v| v.as_f64())
            .map(|pct| (pct / 100.0).clamp(0.0, 1.0));
        let time_left_secs = job
            .get("progress")
            .and_then(|p| p.get("printTimeLeft"))
            .and_then(|v| v.as_u64());
        let job_name = job
            .get("job")
            .and_then(|j| j.get("file"))
            .and_then(|f| f.get("name"))
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .map(String::from);
        Ok(PrinterStatus {
            state,
            progress,
            current_layer: None, // OctoPrint core does not report layers (plugin territory)
            total_layers: None,
            time_left_secs,
            job_name,
            detail: Some(text.to_string()).filter(|s| !s.is_empty()),
        })
    }

    fn upload(&self, local_path: &Path) -> Result<FileRef, String> {
        let name = local_path
            .file_name()
            .and_then(|n| n.to_str())
            .ok_or_else(|| "invalid file name".to_string())?
            .to_string();
        let bytes = std::fs::read(local_path).map_err(|e| format!("read: {e}"))?;
        let form = reqwest::blocking::multipart::Form::new()
            .text("select", "false")
            .text("print", "false")
            .part(
                "file",
                reqwest::blocking::multipart::Part::bytes(bytes).file_name(name.clone()),
            );
        let resp = self
            .client
            .post(format!("{}/api/files/local", self.base))
            .header("X-Api-Key", &self.api_key)
            .multipart(form)
            .send()
            .map_err(|e| format!("octoprint upload: {e}"))?;
        if !resp.status().is_success() {
            return Err(format!("octoprint upload failed: HTTP {}", resp.status()));
        }
        Ok(FileRef::new("local", name))
    }

    fn start(&self, file: &FileRef) -> Result<(), String> {
        // Select the file, then start.
        let resp = self
            .client
            .post(format!("{}/api/files/{}/{}", self.base, file.storage, file.name))
            .header("X-Api-Key", &self.api_key)
            .json(&json!({"command": "select", "print": true}))
            .send()
            .map_err(|e| format!("octoprint select: {e}"))?;
        if resp.status().is_success() || resp.status().as_u16() == 204 {
            Ok(())
        } else {
            Err(format!("octoprint select+print failed: HTTP {}", resp.status()))
        }
    }

    fn pause(&self) -> Result<(), String> {
        self.post_job(json!({"command": "pause", "action": "pause"}))
    }

    fn resume(&self) -> Result<(), String> {
        self.post_job(json!({"command": "pause", "action": "resume"}))
    }

    fn cancel(&self) -> Result<(), String> {
        self.post_job(json!({"command": "cancel"}))
    }

    fn camera(&self) -> Result<CameraSource, String> {
        // Webcam URL lives in settings; stream is usually /webcam/?action=stream via mjpg-streamer.
        let settings = self.get("/api/settings")?;
        let stream = settings
            .get("webcam")
            .and_then(|w| w.get("streamUrl"))
            .and_then(|v| v.as_str())
            .unwrap_or("");
        if stream.is_empty() {
            return Ok(CameraSource::None);
        }
        let url = if stream.starts_with("http") {
            stream.to_string()
        } else {
            format!("{}{}", self.base, stream)
        };
        Ok(CameraSource::MjpegUrl { url })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_states() {
        let flags = serde_json::json!({"printing": true});
        assert_eq!(OctoPrinter::map_state("Printing", Some(&flags)), PrinterState::Printing);
        let flags = serde_json::json!({"paused": true});
        assert_eq!(OctoPrinter::map_state("Paused", Some(&flags)), PrinterState::Paused);
        let flags = serde_json::json!({"operational": true});
        assert_eq!(OctoPrinter::map_state("Operational", Some(&flags)), PrinterState::Idle);
        assert_eq!(OctoPrinter::map_state("Offline", None), PrinterState::Offline);
        assert_eq!(OctoPrinter::map_state("Error: thermal runaway", None), PrinterState::Error);
    }
}
