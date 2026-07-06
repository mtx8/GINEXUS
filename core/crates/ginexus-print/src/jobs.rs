//! JobQueue — the fabrication job state machine, persisted as JSON (`fab/jobs.json`).
//! States move strictly forward; Start requires the printer Idle AND the plate cleared
//! (resin prints end with a part dripping on the plate — the manual-unload gate is physical
//! reality, not ceremony).

use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JobState {
    /// Model analyzed, not yet sliced.
    Draft,
    /// Native print file exists (sliced + converted), optionally validated.
    Sliced,
    /// File uploaded to printer storage; waiting for the hard-gated start approval.
    Uploaded,
    Printing,
    Complete,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FabJob {
    pub id: String,
    pub name: String,
    pub printer_id: String,
    /// Source model (STL) path.
    #[serde(default)]
    pub model_path: String,
    /// Sliced native file path on disk.
    #[serde(default)]
    pub sliced_path: String,
    /// FileRef name in printer storage after upload.
    #[serde(default)]
    pub remote_name: String,
    #[serde(default)]
    pub remote_storage: String,
    pub state: JobState,
    /// UVtools print-issues summary (resin) or slicer estimate (FDM).
    #[serde(default)]
    pub validation: String,
    /// True once this job actually reached the printer (Uploaded→Printing). A job cancelled
    /// while still Draft/Sliced/Uploaded never put a part on the plate, so it need not block the
    /// manual-unload gate; a job that WAS printing leaves a partial part and must block until
    /// physically cleared. Persisted so the gate survives a restart.
    #[serde(default)]
    pub printed: bool,
    pub created_ms: i64,
    pub updated_ms: i64,
}

fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

pub struct JobQueue {
    path: PathBuf,
    jobs: Vec<FabJob>,
    /// Set when jobs.json was present but corrupt: the queue is DEGRADED and safety-critical
    /// reads (printer_clear) refuse rather than silently trusting an empty queue.
    poisoned: Option<String>,
}

impl JobQueue {
    pub fn open(fab_dir: PathBuf) -> Self {
        let _ = std::fs::create_dir_all(&fab_dir);
        let path = fab_dir.join("jobs.json");
        let (jobs, poisoned) = match crate::persist::load::<Vec<FabJob>>(&path) {
            crate::persist::Load::Loaded(v) => (v, None),
            crate::persist::Load::Fresh => (Vec::new(), None),
            crate::persist::Load::Poisoned(msg) => (Vec::new(), Some(msg)),
        };
        Self { path, jobs, poisoned }
    }

    fn save(&self) {
        if let Err(e) = crate::persist::save(&self.path, &self.jobs) {
            eprintln!("fab: failed to persist jobs.json: {e}");
        }
    }

    /// True when the on-disk queue was corrupt at open — the plate-clear gate can't be trusted.
    pub fn is_poisoned(&self) -> bool {
        self.poisoned.is_some()
    }

    pub fn list(&self) -> &[FabJob] {
        &self.jobs
    }

    pub fn get(&self, id: &str) -> Option<&FabJob> {
        self.jobs.iter().find(|j| j.id == id)
    }

    pub fn create(&mut self, name: &str, printer_id: &str, model_path: &str) -> String {
        let id = format!("job-{:x}", now_ms());
        let mut id = id;
        while self.jobs.iter().any(|j| j.id == id) {
            id.push('x');
        }
        self.jobs.push(FabJob {
            id: id.clone(),
            name: name.to_string(),
            printer_id: printer_id.to_string(),
            model_path: model_path.to_string(),
            sliced_path: String::new(),
            remote_name: String::new(),
            remote_storage: String::new(),
            state: JobState::Draft,
            validation: String::new(),
            printed: false,
            created_ms: now_ms(),
            updated_ms: now_ms(),
        });
        self.save();
        id
    }

    /// Apply a forward transition; illegal moves are refused with an explanation.
    pub fn transition(&mut self, id: &str, to: JobState) -> Result<(), String> {
        let job = self
            .jobs
            .iter_mut()
            .find(|j| j.id == id)
            .ok_or_else(|| format!("no job '{id}'"))?;
        let ok = matches!(
            (job.state, to),
            (JobState::Draft, JobState::Sliced)
                | (JobState::Sliced, JobState::Uploaded)
                | (JobState::Uploaded, JobState::Printing)
                | (JobState::Printing, JobState::Complete)
                | (JobState::Printing, JobState::Failed)
                | (JobState::Printing, JobState::Cancelled)
                | (JobState::Draft, JobState::Cancelled)
                | (JobState::Sliced, JobState::Cancelled)
                | (JobState::Uploaded, JobState::Cancelled)
        );
        if !ok {
            return Err(format!(
                "job '{}' cannot move {:?} → {:?}",
                job.name, job.state, to
            ));
        }
        if to == JobState::Printing {
            job.printed = true; // it reached the plate — now it gates the manual-unload check
        }
        job.state = to;
        job.updated_ms = now_ms();
        self.save();
        Ok(())
    }

    pub fn update<F: FnOnce(&mut FabJob)>(&mut self, id: &str, f: F) -> Result<(), String> {
        let job = self
            .jobs
            .iter_mut()
            .find(|j| j.id == id)
            .ok_or_else(|| format!("no job '{id}'"))?;
        f(job);
        job.updated_ms = now_ms();
        self.save();
        Ok(())
    }

    /// Remove a job — but REFUSE to silently drop a Printing job (that would strand a live print
    /// with no queue record). Callers must cancel first. Returns Ok(true) if removed, Ok(false)
    /// if no such job.
    pub fn remove(&mut self, id: &str) -> Result<bool, String> {
        if let Some(j) = self.jobs.iter().find(|j| j.id == id) {
            if j.state == JobState::Printing {
                return Err(format!(
                    "'{}' is still printing — cancel it first (fab_cancel_print) before removing",
                    j.name
                ));
            }
        } else {
            return Ok(false);
        }
        self.jobs.retain(|j| j.id != id);
        self.save();
        Ok(true)
    }

    /// The manual-unload gate: a printer is start-clear only if NO job on it left something on the
    /// plate. Printing (live), Complete (finished part), and Cancelled/Failed jobs that WERE
    /// printing (partial part bonded to the plate) all block until physically cleared. A corrupt
    /// queue at open() poisons this check — we refuse rather than trust an empty (wiped) queue.
    pub fn printer_clear(&self, printer_id: &str) -> Result<(), String> {
        if let Some(msg) = &self.poisoned {
            return Err(format!(
                "job records were corrupt — cannot confirm the plate is clear. Physically verify \
                 the printer, then clear jobs to acknowledge. ({msg})"
            ));
        }
        for j in &self.jobs {
            if j.printer_id != printer_id {
                continue;
            }
            match j.state {
                JobState::Printing => {
                    return Err(format!("'{}' is still printing on this printer", j.name))
                }
                JobState::Complete => {
                    return Err(format!(
                        "'{}' finished but the plate has not been cleared — remove the part and \
                         clear the job first",
                        j.name
                    ))
                }
                // A cancelled/failed print that actually ran leaves a partial part on the plate.
                JobState::Cancelled | JobState::Failed if j.printed => {
                    return Err(format!(
                        "'{}' was {:?} mid-print — a partial part may remain on the plate; clear \
                         the job after removing it",
                        j.name, j.state
                    ))
                }
                _ => {}
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn queue(tag: &str) -> (JobQueue, PathBuf) {
        let d = std::env::temp_dir().join(format!("gx-fabjobs-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        (JobQueue::open(d.clone()), d)
    }

    #[test]
    fn lifecycle_and_gates() {
        let (mut q, dir) = queue("life");
        let id = q.create("bracket", "saturn", "/tmp/bracket.stl");
        assert_eq!(q.get(&id).unwrap().state, JobState::Draft);

        // Cannot jump Draft → Printing.
        assert!(q.transition(&id, JobState::Printing).is_err());

        q.transition(&id, JobState::Sliced).unwrap();
        q.transition(&id, JobState::Uploaded).unwrap();
        assert!(q.printer_clear("saturn").is_ok());
        q.transition(&id, JobState::Printing).unwrap();
        // While printing, the printer is NOT clear for another job.
        assert!(q.printer_clear("saturn").is_err());
        q.transition(&id, JobState::Complete).unwrap();
        // Complete-but-not-cleared still blocks (manual-unload gate).
        let err = q.printer_clear("saturn").unwrap_err();
        assert!(err.contains("plate"), "got: {err}");
        assert!(q.remove(&id).unwrap());
        assert!(q.printer_clear("saturn").is_ok());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn cancelled_mid_print_blocks_the_gate() {
        let (mut q, dir) = queue("cancel");
        let id = q.create("part", "saturn", "/tmp/p.stl");
        q.transition(&id, JobState::Sliced).unwrap();
        q.transition(&id, JobState::Uploaded).unwrap();
        q.transition(&id, JobState::Printing).unwrap(); // now printed = true
        q.transition(&id, JobState::Cancelled).unwrap();
        // A partial part remains — gate must still block until cleared.
        let err = q.printer_clear("saturn").unwrap_err();
        assert!(err.contains("partial"), "got: {err}");
        assert!(q.remove(&id).unwrap());
        assert!(q.printer_clear("saturn").is_ok());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn cancelled_before_print_does_not_block() {
        let (mut q, dir) = queue("cancel-early");
        let id = q.create("part", "saturn", "/tmp/p.stl");
        q.transition(&id, JobState::Sliced).unwrap();
        q.transition(&id, JobState::Cancelled).unwrap(); // never reached the plate
        assert!(q.printer_clear("saturn").is_ok());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn remove_refuses_printing_job() {
        let (mut q, dir) = queue("rm");
        let id = q.create("part", "saturn", "/tmp/p.stl");
        q.transition(&id, JobState::Sliced).unwrap();
        q.transition(&id, JobState::Uploaded).unwrap();
        q.transition(&id, JobState::Printing).unwrap();
        assert!(q.remove(&id).is_err(), "must not silently drop a live print");
        assert!(!q.remove("nonexistent").unwrap());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn corrupt_queue_poisons_the_gate() {
        let dir = std::env::temp_dir().join(format!("gx-fabjobs-poison-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        // Simulate a crash mid-save: a truncated jobs.json.
        std::fs::write(dir.join("jobs.json"), b"[{\"id\":\"job-1\",\"na").unwrap();
        let q = JobQueue::open(dir.clone());
        assert!(q.is_poisoned());
        // The gate REFUSES rather than trusting a wiped (empty) queue.
        assert!(q.printer_clear("saturn").is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn persists_across_reopen() {
        let (mut q, dir) = queue("persist");
        let id = q.create("part", "mock", "/tmp/p.stl");
        q.update(&id, |j| j.sliced_path = "/tmp/p.goo".into()).unwrap();
        drop(q);
        let q2 = JobQueue::open(dir.clone());
        assert_eq!(q2.get(&id).unwrap().sliced_path, "/tmp/p.goo");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
