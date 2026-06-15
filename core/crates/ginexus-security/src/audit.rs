//! Append-only, tamper-evident audit log: HMAC-anchored SHA-256 hash chain (Rust core).
//! Port of `audit.py`. Since the Rust core is the sole writer/reader, the on-disk format is
//! compact JSON (internal consistency, not Python byte-parity). Forgery resistance comes from
//! HMAC-keying each link; rollback/truncation from an out-of-band head anchor + `contains_hash`.

use hmac::{Hmac, Mac};
use serde_json::{json, Map, Value};
use sha2::Sha256;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

type HmacSha256 = Hmac<Sha256>;
const GENESIS: &str = "0000000000000000000000000000000000000000000000000000000000000000";
const ANCHOR_NAME: &str = "audit.head";

fn mac_hex(key: &[u8], s: &str) -> String {
    let mut mac = HmacSha256::new_from_slice(key).expect("hmac key");
    mac.update(s.as_bytes());
    hex::encode(mac.finalize().into_bytes())
}

fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

/// Canonical (sorted, compact) JSON over exactly the hashed fields — record/verify must agree.
fn body(ts: i64, event: &str, data: &Value, prev_hash: &str) -> String {
    let mut m = Map::new();
    m.insert("ts".into(), json!(ts));
    m.insert("event".into(), json!(event));
    m.insert("data".into(), data.clone());
    m.insert("prev_hash".into(), json!(prev_hash));
    serde_json::to_string(&Value::Object(m)).expect("body serialize")
}

pub struct AuditLog {
    path: PathBuf,
    key: Vec<u8>,
    head: Mutex<Option<String>>,
}

impl AuditLog {
    pub fn new(path: impl Into<PathBuf>, key: Vec<u8>) -> Self {
        let path = path.into();
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        Self { path, key, head: Mutex::new(None) }
    }

    fn last_hash(&self) -> String {
        let text = match std::fs::read_to_string(&self.path) {
            Ok(t) => t,
            Err(_) => return GENESIS.to_string(),
        };
        for line in text.lines().rev() {
            if let Ok(v) = serde_json::from_str::<Value>(line) {
                if let Some(h) = v.get("hash").and_then(|h| h.as_str()) {
                    return h.to_string();
                }
            }
        }
        GENESIS.to_string()
    }

    pub fn head(&self) -> String {
        let mut g = self.head.lock().unwrap();
        if g.is_none() {
            *g = Some(self.last_hash());
        }
        g.clone().unwrap()
    }

    /// Append an entry; returns its hash. Lock-guarded read-head→append (no fork/TOCTOU).
    pub fn record(&self, event: &str, data: Value) -> std::io::Result<String> {
        let mut g = self.head.lock().unwrap();
        let prev = match g.as_ref() {
            Some(h) => h.clone(),
            None => self.last_hash(),
        };
        let ts = now_ms();
        let b = body(ts, event, &data, &prev);
        let hash = mac_hex(&self.key, &format!("{prev}{b}"));
        let mut entry = Map::new();
        entry.insert("ts".into(), json!(ts));
        entry.insert("event".into(), json!(event));
        entry.insert("data".into(), data);
        entry.insert("prev_hash".into(), json!(prev));
        entry.insert("hash".into(), json!(hash));
        let line = serde_json::to_string(&Value::Object(entry)).expect("entry serialize");
        let mut f = OpenOptions::new().create(true).append(true).open(&self.path)?;
        writeln!(f, "{line}")?;
        *g = Some(hash.clone());
        Ok(hash)
    }

    pub fn verify(&self, expected_head: Option<&str>) -> bool {
        let text = match std::fs::read_to_string(&self.path) {
            Ok(t) => t,
            Err(_) => return matches!(expected_head, None | Some(GENESIS)),
        };
        let mut prev = GENESIS.to_string();
        for line in text.lines() {
            let v: Value = match serde_json::from_str(line) {
                Ok(v) => v,
                Err(_) => return false,
            };
            let (ts, event, data, ph, hash) = match (
                v.get("ts").and_then(|x| x.as_i64()),
                v.get("event").and_then(|x| x.as_str()),
                v.get("data"),
                v.get("prev_hash").and_then(|x| x.as_str()),
                v.get("hash").and_then(|x| x.as_str()),
            ) {
                (Some(a), Some(b), Some(c), Some(d), Some(e)) => (a, b, c, d, e),
                _ => return false,
            };
            if ph != prev {
                return false;
            }
            if mac_hex(&self.key, &format!("{ph}{}", body(ts, event, data, ph))) != hash {
                return false;
            }
            prev = hash.to_string();
        }
        match expected_head {
            Some(h) => prev == h,
            None => true,
        }
    }

    /// True iff `h` is genesis or appears as some entry's hash (anchor is an ancestor of head).
    pub fn contains_hash(&self, h: &str) -> bool {
        if h == GENESIS {
            return true;
        }
        let text = match std::fs::read_to_string(&self.path) {
            Ok(t) => t,
            Err(_) => return false,
        };
        text.lines().any(|line| {
            serde_json::from_str::<Value>(line)
                .ok()
                .and_then(|v| v.get("hash").and_then(|x| x.as_str()).map(|s| s == h))
                .unwrap_or(false)
        })
    }

    pub fn write_anchor(&self, dir: &Path) -> std::io::Result<PathBuf> {
        std::fs::create_dir_all(dir)?;
        let head = self.head();
        let anchor = json!({"head": head, "mac": mac_hex(&self.key, &format!("anchor:{head}"))});
        let p = dir.join(ANCHOR_NAME);
        std::fs::write(&p, serde_json::to_string(&anchor).unwrap())?;
        Ok(p)
    }

    pub fn read_anchor(&self, dir: &Path) -> Option<String> {
        let p = dir.join(ANCHOR_NAME);
        let v: Value = serde_json::from_str(&std::fs::read_to_string(p).ok()?).ok()?;
        let head = v.get("head")?.as_str()?;
        let mac = v.get("mac")?.as_str()?;
        let expected = mac_hex(&self.key, &format!("anchor:{head}"));
        // constant-time compare of the hex strings
        if mac.len() == expected.len()
            && mac.bytes().zip(expected.bytes()).fold(0u8, |acc, (a, b)| acc | (a ^ b)) == 0
        {
            Some(head.to_string())
        } else {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::sync::atomic::{AtomicU64, Ordering};
    static CTR: AtomicU64 = AtomicU64::new(0);

    fn uniq() -> String {
        let n = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        format!("{}-{}-{}", std::process::id(), n, CTR.fetch_add(1, Ordering::Relaxed))
    }
    fn tmp() -> PathBuf {
        std::env::temp_dir().join(format!("ginexus-audit-{}.jsonl", uniq()))
    }
    fn key() -> Vec<u8> {
        (0u8..32).collect()
    }

    #[test]
    fn chain_links_and_verifies() {
        let p = tmp();
        let log = AuditLog::new(&p, key());
        log.record("a", json!({})).unwrap();
        log.record("b", json!({"x": 1})).unwrap();
        assert!(AuditLog::new(&p, key()).verify(None));
        std::fs::remove_file(&p).ok();
    }

    #[test]
    fn tamper_detected() {
        let p = tmp();
        let log = AuditLog::new(&p, key());
        log.record("a", json!({})).unwrap();
        log.record("b", json!({})).unwrap();
        // rewrite line 0 with a different event
        let mut lines: Vec<String> = std::fs::read_to_string(&p).unwrap().lines().map(String::from).collect();
        lines[0] = lines[0].replace("\"a\"", "\"HACKED\"");
        std::fs::write(&p, lines.join("\n") + "\n").unwrap();
        assert!(!AuditLog::new(&p, key()).verify(None));
        std::fs::remove_file(&p).ok();
    }

    #[test]
    fn wrong_key_fails() {
        let p = tmp();
        AuditLog::new(&p, key()).record("a", json!({})).unwrap();
        assert!(!AuditLog::new(&p, vec![1u8; 32]).verify(None));
        std::fs::remove_file(&p).ok();
    }

    #[test]
    fn anchor_detects_rollback() {
        let p = tmp();
        let dir = p.parent().unwrap().to_path_buf();
        let log = AuditLog::new(&p, key());
        log.record("a", json!({})).unwrap();
        log.record("b", json!({})).unwrap();
        let anchored = log.head();
        log.record("c", json!({})).unwrap(); // legit forward growth
        assert!(AuditLog::new(&p, key()).contains_hash(&anchored)); // ancestor present
        // attacker truncates below the anchor
        let first = std::fs::read_to_string(&p).unwrap().lines().next().unwrap().to_string();
        std::fs::write(&p, first + "\n").unwrap();
        assert!(!AuditLog::new(&p, key()).contains_hash(&anchored)); // rollback caught
        let _ = dir;
        std::fs::remove_file(&p).ok();
    }

    #[test]
    fn anchor_mac_tamper_rejected() {
        let p = tmp();
        let dir = std::env::temp_dir().join(format!("ginexus-anchor-{}", uniq()));
        let log = AuditLog::new(&p, key());
        log.record("a", json!({})).unwrap();
        let ap = log.write_anchor(&dir).unwrap();
        std::fs::write(&ap, r#"{"head":"ffff","mac":"deadbeef"}"#).unwrap();
        assert!(AuditLog::new(&p, key()).read_anchor(&dir).is_none());
        std::fs::remove_file(&p).ok();
        std::fs::remove_dir_all(&dir).ok();
    }
}
