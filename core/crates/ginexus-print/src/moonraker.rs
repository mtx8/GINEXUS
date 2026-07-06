//! Moonraker (Klipper) driver over the REST-ish HTTP surface (moonraker.readthedocs.io):
//! `GET /printer/objects/query`, `POST /printer/print/{start|pause|resume|cancel}`,
//! multipart `POST /server/files/upload` (root=gcodes). Optional `X-Api-Key`.
//! Polling only in v1 (JSON-RPC WebSocket subscribe is the documented R2 upgrade).

use crate::driver::{CameraSource, Capabilities, FileRef, PrinterDriver, PrinterState, PrinterStatus};
use serde_json::Value;
use std::path::Path;
use std::time::Duration;

pub struct MoonrakerPrinter {
    base: String,
    api_key: Option<String>,
    client: reqwest::blocking::Client,
}

impl MoonrakerPrinter {
    pub fn new(host: &str, api_key: Option<String>) -> Self {
        let base = if host.starts_with("http") {
            host.trim_end_matches('/').to_string()
        } else {
            format!("http://{host}")
        };
        Self {
            base,
            api_key: api_key.filter(|k| !k.is_empty()),
            client: reqwest::blocking::Client::builder()
                .timeout(Duration::from_secs(20))
                .build()
                .expect("http client"),
        }
    }

    fn req(&self, method: reqwest::Method, path: &str) -> reqwest::blocking::RequestBuilder {
        let mut r = self.client.request(method, format!("{}{path}", self.base));
        if let Some(k) = &self.api_key {
            r = r.header("X-Api-Key", k);
        }
        r
    }

    fn get(&self, path: &str) -> Result<Value, String> {
        let resp = self
            .req(reqwest::Method::GET, path)
            .send()
            .map_err(|e| format!("moonraker unreachable: {e}"))?;
        if !resp.status().is_success() {
            return Err(format!("moonraker {path}: HTTP {}", resp.status()));
        }
        resp.json().map_err(|e| format!("moonraker {path}: bad json: {e}"))
    }

    fn post(&self, path: &str) -> Result<(), String> {
        let resp = self
            .req(reqwest::Method::POST, path)
            .send()
            .map_err(|e| format!("moonraker unreachable: {e}"))?;
        if resp.status().is_success() {
            Ok(())
        } else {
            Err(format!("moonraker {path}: HTTP {}", resp.status()))
        }
    }

    fn map_state(s: &str) -> PrinterState {
        match s {
            "printing" => PrinterState::Printing,
            "paused" => PrinterState::Paused,
            "standby" => PrinterState::Idle,
            "complete" => PrinterState::Complete,
            "cancelled" => PrinterState::Idle,
            "error" => PrinterState::Error,
            _ => PrinterState::Unknown,
        }
    }
}

impl PrinterDriver for MoonrakerPrinter {
    fn kind(&self) -> &'static str {
        "moonraker"
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities { upload: true, start: true, pause: true, resume: true, cancel: true, camera: true }
    }

    fn status(&self) -> Result<PrinterStatus, String> {
        let v = match self.get(
            "/printer/objects/query?print_stats&display_status&virtual_sdcard",
        ) {
            Ok(v) => v,
            Err(e) if e.contains("unreachable") => return Ok(PrinterStatus::offline()),
            Err(e) => return Err(e),
        };
        let s = &v["result"]["status"];
        let ps = &s["print_stats"];
        let state = Self::map_state(ps["state"].as_str().unwrap_or(""));
        let progress = s["virtual_sdcard"]["progress"]
            .as_f64()
            .or_else(|| s["display_status"]["progress"].as_f64())
            .map(|p| p.clamp(0.0, 1.0));
        let job_name =
            ps["filename"].as_str().filter(|n| !n.is_empty()).map(String::from);
        // Klipper reports layer info via print_stats.info when the slicer/macro sets it.
        let current_layer =
            ps["info"]["current_layer"].as_u64().map(|v| v as u32);
        let total_layers = ps["info"]["total_layer"].as_u64().map(|v| v as u32);
        let detail = ps["message"].as_str().filter(|m| !m.is_empty()).map(String::from);
        Ok(PrinterStatus {
            state,
            progress,
            current_layer,
            total_layers,
            time_left_secs: None, // needs estimate math (print_duration vs slicer estimate) — R2
            job_name,
            detail,
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
            .text("root", "gcodes")
            .text("print", "false")
            .part(
                "file",
                reqwest::blocking::multipart::Part::bytes(bytes).file_name(name.clone()),
            );
        let mut r = self.client.post(format!("{}/server/files/upload", self.base));
        if let Some(k) = &self.api_key {
            r = r.header("X-Api-Key", k);
        }
        let resp = r.multipart(form).send().map_err(|e| format!("moonraker upload: {e}"))?;
        if !resp.status().is_success() {
            return Err(format!("moonraker upload failed: HTTP {}", resp.status()));
        }
        Ok(FileRef::new("gcodes", name))
    }

    fn start(&self, file: &FileRef) -> Result<(), String> {
        let encoded: String = file
            .name
            .bytes()
            .map(|b| match b {
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                    (b as char).to_string()
                }
                _ => format!("%{b:02X}"),
            })
            .collect();
        self.post(&format!("/printer/print/start?filename={encoded}"))
    }

    fn pause(&self) -> Result<(), String> {
        self.post("/printer/print/pause")
    }

    fn resume(&self) -> Result<(), String> {
        self.post("/printer/print/resume")
    }

    fn cancel(&self) -> Result<(), String> {
        self.post("/printer/print/cancel")
    }

    fn camera(&self) -> Result<CameraSource, String> {
        // Moonraker registers webcams under /server/webcams/list.
        let v = self.get("/server/webcams/list")?;
        let cams = v["result"]["webcams"].as_array().cloned().unwrap_or_default();
        for cam in cams {
            if let Some(url) = cam["stream_url"].as_str().filter(|u| !u.is_empty()) {
                let url = if url.starts_with("http") {
                    url.to_string()
                } else {
                    format!("{}{}", self.base, url)
                };
                return Ok(CameraSource::MjpegUrl { url });
            }
        }
        Ok(CameraSource::None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_states() {
        assert_eq!(MoonrakerPrinter::map_state("printing"), PrinterState::Printing);
        assert_eq!(MoonrakerPrinter::map_state("paused"), PrinterState::Paused);
        assert_eq!(MoonrakerPrinter::map_state("standby"), PrinterState::Idle);
        assert_eq!(MoonrakerPrinter::map_state("complete"), PrinterState::Complete);
        assert_eq!(MoonrakerPrinter::map_state("error"), PrinterState::Error);
        assert_eq!(MoonrakerPrinter::map_state("weird"), PrinterState::Unknown);
    }

    #[test]
    fn start_urlencodes_filename() {
        // Pure logic check of the encoder used in start().
        let name = "my part+v2.gcode";
        let encoded: String = name
            .bytes()
            .map(|b| match b {
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                    (b as char).to_string()
                }
                _ => format!("%{b:02X}"),
            })
            .collect();
        assert_eq!(encoded, "my%20part%2Bv2.gcode");
    }
}
