//! MockDriver — a deterministic in-memory printer for tests, agent-loop wiring, and UI
//! development before any hardware exists. Prints "complete" after a fixed number of
//! status polls so flows are reproducible without wall-clock coupling.

use crate::driver::{CameraSource, Capabilities, FileRef, PrinterDriver, PrinterState, PrinterStatus};
use std::path::Path;
use std::sync::Mutex;

const TOTAL_LAYERS: u32 = 100;
/// Layers advanced per status poll — a full mock print completes in 10 polls.
const LAYERS_PER_POLL: u32 = 10;

struct MockState {
    state: PrinterState,
    layer: u32,
    job: Option<String>,
    uploaded: Vec<String>,
}

pub struct MockPrinter {
    state: Mutex<MockState>,
}

impl Default for MockPrinter {
    fn default() -> Self {
        Self::new()
    }
}

impl MockPrinter {
    pub fn new() -> Self {
        Self {
            state: Mutex::new(MockState {
                state: PrinterState::Idle,
                layer: 0,
                job: None,
                uploaded: Vec::new(),
            }),
        }
    }
}

impl PrinterDriver for MockPrinter {
    fn kind(&self) -> &'static str {
        "mock"
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities { upload: true, start: true, pause: true, resume: true, cancel: true, camera: false }
    }

    fn status(&self) -> Result<PrinterStatus, String> {
        let mut s = self.state.lock().unwrap();
        if s.state == PrinterState::Printing {
            s.layer = (s.layer + LAYERS_PER_POLL).min(TOTAL_LAYERS);
            if s.layer >= TOTAL_LAYERS {
                s.state = PrinterState::Complete;
            }
        }
        Ok(PrinterStatus {
            state: s.state,
            progress: if s.job.is_some() {
                Some(f64::from(s.layer) / f64::from(TOTAL_LAYERS))
            } else {
                None
            },
            current_layer: s.job.as_ref().map(|_| s.layer),
            total_layers: s.job.as_ref().map(|_| TOTAL_LAYERS),
            time_left_secs: s.job.as_ref().map(|_| u64::from(TOTAL_LAYERS - s.layer) * 6),
            job_name: s.job.clone(),
            detail: Some("mock printer".into()),
        })
    }

    fn upload(&self, local_path: &Path) -> Result<FileRef, String> {
        if !local_path.exists() {
            return Err("file does not exist".into());
        }
        let name = local_path
            .file_name()
            .and_then(|n| n.to_str())
            .ok_or_else(|| "invalid file name".to_string())?
            .to_string();
        self.state.lock().unwrap().uploaded.push(name.clone());
        Ok(FileRef::new("local", name))
    }

    fn start(&self, file: &FileRef) -> Result<(), String> {
        let mut s = self.state.lock().unwrap();
        if !s.uploaded.contains(&file.name) {
            return Err(format!("file '{}' was never uploaded", file.name));
        }
        if s.state == PrinterState::Printing {
            return Err("a print is already running".into());
        }
        s.state = PrinterState::Printing;
        s.layer = 0;
        s.job = Some(file.name.clone());
        Ok(())
    }

    fn pause(&self) -> Result<(), String> {
        let mut s = self.state.lock().unwrap();
        if s.state != PrinterState::Printing {
            return Err("nothing is printing".into());
        }
        s.state = PrinterState::Paused;
        Ok(())
    }

    fn resume(&self) -> Result<(), String> {
        let mut s = self.state.lock().unwrap();
        if s.state != PrinterState::Paused {
            return Err("printer is not paused".into());
        }
        s.state = PrinterState::Printing;
        Ok(())
    }

    fn cancel(&self) -> Result<(), String> {
        let mut s = self.state.lock().unwrap();
        if s.state != PrinterState::Printing && s.state != PrinterState::Paused {
            return Err("no active print to cancel".into());
        }
        s.state = PrinterState::Idle;
        s.layer = 0;
        s.job = None;
        Ok(())
    }

    fn camera(&self) -> Result<CameraSource, String> {
        Ok(CameraSource::None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn full_print_lifecycle() {
        let p = MockPrinter::new();
        assert_eq!(p.status().unwrap().state, PrinterState::Idle);

        let f = std::env::temp_dir().join("gx-mock-part.goo");
        std::fs::write(&f, b"layers").unwrap();
        let fref = p.upload(&f).unwrap();

        // Cannot start a file that was never uploaded.
        assert!(p.start(&FileRef::new("local", "ghost.goo")).is_err());

        p.start(&fref).unwrap();
        assert_eq!(p.status().unwrap().state, PrinterState::Printing);
        p.pause().unwrap();
        assert_eq!(p.status().unwrap().state, PrinterState::Paused);
        p.resume().unwrap();
        // Drive to completion: 10 polls total advance 100 layers.
        let mut last = p.status().unwrap();
        for _ in 0..12 {
            last = p.status().unwrap();
        }
        assert_eq!(last.state, PrinterState::Complete);
        assert_eq!(last.current_layer, Some(100));
        let _ = std::fs::remove_file(&f);
    }

    #[test]
    fn cancel_resets() {
        let p = MockPrinter::new();
        let f = std::env::temp_dir().join("gx-mock-part2.goo");
        std::fs::write(&f, b"x").unwrap();
        let fref = p.upload(&f).unwrap();
        p.start(&fref).unwrap();
        p.cancel().unwrap();
        assert_eq!(p.status().unwrap().state, PrinterState::Idle);
        assert!(p.cancel().is_err());
        let _ = std::fs::remove_file(&f);
    }
}
