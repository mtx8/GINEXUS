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

#[derive(Serialize, Deserialize, Clone)]
pub struct Schedule {
    pub id: String,
    pub prompt: String,
    pub every_secs: i64,
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

    /// Add a schedule. First run fires on the next heartbeat tick (immediate-ish), then every N.
    pub fn add(&self, prompt: String, every_secs: i64, now_ms: i64, id: String) -> Result<Schedule, String> {
        let mut items = self.items.lock().unwrap();
        if items.len() >= MAX_SCHEDULES {
            return Err("too many schedules".into());
        }
        if prompt.trim().is_empty() {
            return Err("empty prompt".into());
        }
        let s = Schedule {
            id,
            prompt,
            every_secs: every_secs.max(MIN_EVERY_SECS),
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

    pub fn list(&self) -> Vec<Schedule> {
        self.items.lock().unwrap().clone()
    }

    /// (id, prompt) for schedules due at `now_ms`; immediately bumps their next_run to avoid
    /// double-firing while the (possibly slow) task runs.
    pub fn take_due(&self, now_ms: i64) -> Vec<(String, String)> {
        let mut items = self.items.lock().unwrap();
        let mut due = Vec::new();
        for s in items.iter_mut() {
            if s.next_run_ms <= now_ms {
                due.push((s.id.clone(), s.prompt.clone()));
                s.next_run_ms = now_ms + s.every_secs * 1000;
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
            s.add("research X".into(), 60, 1000, "a".into()).unwrap();
            // due at now (next_run == now on add)
            let due = s.take_due(1000);
            assert_eq!(due.len(), 1);
            assert_eq!(due[0].1, "research X");
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
        assert!(s2.remove("a"));
        assert!(s2.list().is_empty());
        std::fs::remove_file(&p).ok();
    }

    #[test]
    fn cadence_floor_and_caps() {
        let p = tmp();
        let s = ScheduleStore::open(p.clone());
        let sch = s.add("x".into(), 5, 0, "a".into()).unwrap();
        assert_eq!(sch.every_secs, MIN_EVERY_SECS); // floored
        assert!(s.add("".into(), 60, 0, "b".into()).is_err()); // empty rejected
        std::fs::remove_file(&p).ok();
    }
}
