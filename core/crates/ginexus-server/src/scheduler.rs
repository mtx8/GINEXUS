//! Scheduler / heartbeat — run agent tasks UNATTENDED on a cadence (Phase 4: "a scheduled task
//! runs unattended and reports back"). Scheduled tasks run with the READ-ONLY toolset (no
//! irreversible/HITL actions without a human), respect the kill switch, and persist their last
//! result for retrieval. Persisted to `run/schedules.json` so they survive restarts.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Mutex;

/// Floor on cadence so a schedule can't hammer the model.
pub const MIN_EVERY_SECS: i64 = 30;
pub const MAX_SCHEDULES: usize = 50;

fn default_true() -> bool {
    true
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Schedule {
    pub id: String,
    /// Human-friendly title for the task (e.g. "Morning news digest"). Older records without a name
    /// load with an empty string; callers fall back to the prompt for display.
    #[serde(default)]
    pub name: String,
    pub prompt: String,
    pub every_secs: i64,
    /// Paused tasks stay in the list but never fire. Defaults to `true` so pre-existing schedules
    /// (written before this field existed) keep running.
    #[serde(default = "default_true")]
    pub enabled: bool,
    /// Absolute paths to attached files (copies stored under App Support, owned by this task). Their
    /// contents are injected as context when the task runs.
    #[serde(default)]
    pub attachments: Vec<String>,
    pub next_run_ms: i64,
    pub last_run_ms: i64,
    pub runs: u64,
    pub last_result: String,
}

pub struct ScheduleStore {
    path: PathBuf,
    items: Mutex<Vec<Schedule>>,
}

impl ScheduleStore {
    pub fn open(path: PathBuf) -> Self {
        let items: Vec<Schedule> = std::fs::read_to_string(&path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        Self { path, items: Mutex::new(items) }
    }

    fn save(&self, items: &[Schedule]) {
        if let Ok(s) = serde_json::to_string_pretty(items) {
            let _ = std::fs::write(&self.path, s);
        }
    }

    /// Per-task folder for attachment copies: `<run>/schedule_files/<id>/`. Derived from the store's
    /// own path so it lives beside `schedules.json` under App Support (writable by the sidecar).
    pub fn files_dir(&self, id: &str) -> PathBuf {
        let run = self.path.parent().map(|p| p.to_path_buf()).unwrap_or_default();
        run.join("schedule_files").join(id)
    }

    /// Add a schedule. First run fires on the next heartbeat tick (immediate-ish), then every N.
    pub fn add(
        &self,
        name: String,
        prompt: String,
        every_secs: i64,
        attachments: Vec<String>,
        now_ms: i64,
        id: String,
    ) -> Result<Schedule, String> {
        let mut items = self.items.lock().unwrap();
        if items.len() >= MAX_SCHEDULES {
            return Err("too many schedules".into());
        }
        if prompt.trim().is_empty() {
            return Err("empty prompt".into());
        }
        let s = Schedule {
            id,
            name: name.trim().chars().take(120).collect(),
            prompt,
            every_secs: every_secs.max(MIN_EVERY_SECS),
            enabled: true,
            attachments,
            next_run_ms: now_ms, // fire soon, then every_secs
            last_run_ms: 0,
            runs: 0,
            last_result: String::new(),
        };
        items.push(s.clone());
        self.save(&items);
        Ok(s)
    }

    pub fn remove(&self, id: &str) -> bool {
        let mut items = self.items.lock().unwrap();
        let before = items.len();
        items.retain(|s| s.id != id);
        let changed = items.len() != before;
        if changed {
            self.save(&items);
        }
        changed
    }

    /// Pause or resume a task. Returns false if the id is unknown.
    pub fn set_enabled(&self, id: &str, enabled: bool) -> bool {
        let mut items = self.items.lock().unwrap();
        if let Some(s) = items.iter_mut().find(|s| s.id == id) {
            s.enabled = enabled;
            self.save(&items);
            true
        } else {
            false
        }
    }

    pub fn list(&self) -> Vec<Schedule> {
        self.items.lock().unwrap().clone()
    }

    /// Full records for ENABLED schedules due at `now_ms`; immediately bumps their next_run to avoid
    /// double-firing while the (possibly slow) task runs. Paused tasks are skipped.
    pub fn take_due(&self, now_ms: i64) -> Vec<Schedule> {
        let mut items = self.items.lock().unwrap();
        let mut due = Vec::new();
        for s in items.iter_mut() {
            if s.enabled && s.next_run_ms <= now_ms {
                s.next_run_ms = now_ms + s.every_secs * 1000;
                due.push(s.clone());
            }
        }
        if !due.is_empty() {
            self.save(&items);
        }
        due
    }

    pub fn record_result(&self, id: &str, now_ms: i64, result: &str) {
        let mut items = self.items.lock().unwrap();
        if let Some(s) = items.iter_mut().find(|s| s.id == id) {
            s.last_run_ms = now_ms;
            s.runs += 1;
            s.last_result = result.chars().take(2000).collect();
        }
        self.save(&items);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    static CTR: AtomicU64 = AtomicU64::new(0);
    fn tmp() -> PathBuf {
        let n = CTR.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!("gx-sched-{}-{}.json", std::process::id(), n))
    }

    #[test]
    fn add_due_record_persist() {
        let p = tmp();
        {
            let s = ScheduleStore::open(p.clone());
            s.add("Digest".into(), "research X".into(), 60, vec![], 1000, "a".into()).unwrap();
            // due at now (next_run == now on add)
            let due = s.take_due(1000);
            assert_eq!(due.len(), 1);
            assert_eq!(due[0].prompt, "research X");
            assert_eq!(due[0].name, "Digest");
            // not due again immediately (bumped to now + 60s)
            assert!(s.take_due(1000).is_empty());
            s.record_result("a", 2000, "the answer");
        }
        // reopen → persisted
        let s2 = ScheduleStore::open(p.clone());
        let items = s2.list();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].runs, 1);
        assert_eq!(items[0].last_result, "the answer");
        assert_eq!(items[0].every_secs, 60);
        assert!(items[0].enabled); // enabled by default
        assert!(s2.remove("a"));
        assert!(s2.list().is_empty());
        std::fs::remove_file(&p).ok();
    }

    #[test]
    fn cadence_floor_and_caps() {
        let p = tmp();
        let s = ScheduleStore::open(p.clone());
        let sch = s.add("X".into(), "x".into(), 5, vec![], 0, "a".into()).unwrap();
        assert_eq!(sch.every_secs, MIN_EVERY_SECS); // floored
        assert!(s.add("".into(), "".into(), 60, vec![], 0, "b".into()).is_err()); // empty prompt rejected
        std::fs::remove_file(&p).ok();
    }

    #[test]
    fn paused_tasks_do_not_fire() {
        let p = tmp();
        let s = ScheduleStore::open(p.clone());
        s.add("X".into(), "x".into(), 60, vec![], 1000, "a".into()).unwrap();
        assert!(s.set_enabled("a", false)); // pause
        assert!(s.take_due(1000).is_empty(), "paused task must not be due");
        assert!(s.set_enabled("a", true)); // resume
        assert_eq!(s.take_due(1000).len(), 1, "resumed task fires");
        assert!(!s.set_enabled("nope", false)); // unknown id
        std::fs::remove_file(&p).ok();
    }

    #[test]
    fn files_dir_is_beside_store() {
        let p = std::env::temp_dir().join("run").join("schedules.json");
        let s = ScheduleStore::open(p);
        let d = s.files_dir("abc123");
        assert!(d.ends_with("run/schedule_files/abc123"));
    }
}
