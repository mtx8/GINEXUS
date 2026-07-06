//! Durable JSON persistence for the fab state stores. Two guarantees the naive
//! `fs::write` + `from_str().ok().unwrap_or_default()` pattern did NOT provide, and which the
//! safety gates depend on:
//!   1. **Atomic writes** — serialize to `<path>.tmp` then `rename` over the target, so a reader
//!      (or a crash mid-write) never sees a half-written file that parses as an empty store.
//!   2. **Corrupt-file quarantine** — a present-but-unparseable file is NOT silently treated as
//!      an empty store (which would erase the job queue and defeat the manual-unload plate gate).
//!      It is renamed aside and the load reports poisoned so callers can refuse unsafe actions.

use serde::{de::DeserializeOwned, Serialize};
use std::path::Path;

/// Outcome of loading a JSON store.
pub enum Load<T> {
    /// File absent — a fresh, empty store is correct.
    Fresh,
    /// File parsed cleanly.
    Loaded(T),
    /// File was present but unparseable; it has been quarantined. The store is DEGRADED —
    /// safety-critical reads must refuse until a human intervenes.
    Poisoned(String),
}

/// Load a JSON file, quarantining it (rename to `<path>.corrupt-<n>`) if present but unparseable.
pub fn load<T: DeserializeOwned>(path: &Path) -> Load<T> {
    let raw = match std::fs::read_to_string(path) {
        Ok(s) => s,
        Err(_) => return Load::Fresh, // absent (or unreadable) → fresh store
    };
    if raw.trim().is_empty() {
        return Load::Fresh;
    }
    match serde_json::from_str::<T>(&raw) {
        Ok(v) => Load::Loaded(v),
        Err(e) => {
            // Quarantine so the next save doesn't clobber the evidence, and so we don't loop.
            let mut n = 0;
            let mut dest = path.with_extension("corrupt");
            while dest.exists() && n < 1000 {
                n += 1;
                dest = path.with_extension(format!("corrupt-{n}"));
            }
            let _ = std::fs::rename(path, &dest);
            Load::Poisoned(format!("{path:?} was corrupt ({e}); quarantined to {dest:?}"))
        }
    }
}

/// Atomically write a value as pretty JSON: temp file in the same dir, fsync, then rename over
/// the target. The fsync guarantees the bytes hit disk before the rename publishes them, so a
/// power loss can't leave a renamed-but-empty file.
pub fn save<T: Serialize>(path: &Path, value: &T) -> Result<(), String> {
    use std::io::Write;
    let json = serde_json::to_string_pretty(value).map_err(|e| format!("serialize: {e}"))?;
    let tmp = path.with_extension("tmp");
    {
        let mut f = std::fs::File::create(&tmp).map_err(|e| format!("create temp: {e}"))?;
        f.write_all(json.as_bytes()).map_err(|e| format!("write temp: {e}"))?;
        f.sync_all().map_err(|e| format!("fsync temp: {e}"))?;
    }
    std::fs::rename(&tmp, path).map_err(|e| format!("rename: {e}"))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_and_corrupt_quarantine() {
        let dir = std::env::temp_dir().join(format!("gx-persist-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("store.json");

        // Fresh when absent.
        assert!(matches!(load::<Vec<i32>>(&p), Load::Fresh));

        // Save + load round-trips.
        save(&p, &vec![1, 2, 3]).unwrap();
        match load::<Vec<i32>>(&p) {
            Load::Loaded(v) => assert_eq!(v, vec![1, 2, 3]),
            _ => panic!("expected Loaded"),
        }

        // Corrupt file → Poisoned + quarantined (NOT silently empty).
        std::fs::write(&p, b"{ this is not json").unwrap();
        match load::<Vec<i32>>(&p) {
            Load::Poisoned(msg) => assert!(msg.contains("corrupt")),
            _ => panic!("corrupt file must poison, never silently empty"),
        }
        assert!(!p.exists(), "corrupt file should have been renamed aside");
        assert!(dir.join("store.corrupt").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
