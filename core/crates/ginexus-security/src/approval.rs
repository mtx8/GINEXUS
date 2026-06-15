//! Approval-token trust boundary (Rust core). Port of `approval.py`.
//!
//! An irreversible/external action runs only against a single-use token the signed app minted
//! after biometric auth. The token is an HMAC-SHA256 over a *canonical* serialization of the
//! exact action — `{v, action, args, target, nonce, expiry_ms, boot_id}` — with sorted keys
//! and compact separators (serde_json's default `Map` is a `BTreeMap`, so keys serialize sorted,
//! matching Python's `json.dumps(sort_keys=True, separators=(",",":"))`). Properties:
//! preview==execution, single-use (nonce burned), bounded TTL, boot-id-bound (no cross-restart
//! replay), floats rejected. Verification is constant-time (`Mac::verify_slice`).

use hmac::{Hmac, Mac};
use sha2::Sha256;
use serde_json::{json, Map, Value};
use std::collections::BTreeSet;
use std::sync::Mutex;
use thiserror::Error;

type HmacSha256 = Hmac<Sha256>;

pub const CANON_VERSION: i64 = 1;
pub const DEFAULT_MAX_TTL_MS: i64 = 120_000;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ApprovalError {
    #[error("approval minted for a different server boot")]
    WrongBoot,
    #[error("approval expired or TTL exceeded")]
    Expired,
    #[error("approval nonce already used")]
    Replayed,
    #[error("approval does not match the action to be executed")]
    Mismatch,
    #[error("args may not contain a float")]
    FloatInArgs,
    #[error("approval key must be >= 256 bits")]
    BadKey,
}

fn reject_floats(v: &Value) -> Result<(), ApprovalError> {
    match v {
        Value::Number(n) if n.is_f64() => Err(ApprovalError::FloatInArgs),
        Value::Array(a) => a.iter().try_for_each(reject_floats),
        Value::Object(o) => o.values().try_for_each(reject_floats),
        _ => Ok(()),
    }
}

/// Deterministic, language-neutral serialization — the single source of truth both ends sign.
pub fn canonical_payload(
    action: &str, args: &Value, target: &str, nonce: &str, expiry_ms: i64, boot_id: &str,
) -> Result<String, ApprovalError> {
    reject_floats(args)?;
    let mut m = Map::new();
    m.insert("v".into(), json!(CANON_VERSION));
    m.insert("action".into(), json!(action));
    m.insert("args".into(), args.clone());
    m.insert("target".into(), json!(target));
    m.insert("nonce".into(), json!(nonce));
    m.insert("expiry_ms".into(), json!(expiry_ms));
    m.insert("boot_id".into(), json!(boot_id));
    // serde_json's default Map is a BTreeMap → keys serialize sorted; to_string is compact.
    Ok(serde_json::to_string(&Value::Object(m)).expect("canonical serialize"))
}

pub fn mint(
    key: &[u8], action: &str, args: &Value, target: &str, nonce: &str, expiry_ms: i64, boot_id: &str,
) -> Result<String, ApprovalError> {
    let payload = canonical_payload(action, args, target, nonce, expiry_ms, boot_id)?;
    let mut mac = HmacSha256::new_from_slice(key).map_err(|_| ApprovalError::BadKey)?;
    mac.update(payload.as_bytes());
    Ok(hex::encode(mac.finalize().into_bytes()))
}

pub struct ApprovalVerifier {
    key: Vec<u8>,
    boot_id: String,
    max_ttl_ms: i64,
    // Interior mutability: the verifier is shared (Arc) across request tasks; the nonce set is
    // the only mutable state. Burning a nonce on success enforces single-use.
    seen: Mutex<BTreeSet<String>>,
}

impl ApprovalVerifier {
    pub fn new(key: Vec<u8>, boot_id: impl Into<String>) -> Result<Self, ApprovalError> {
        if key.len() < 32 {
            return Err(ApprovalError::BadKey);
        }
        Ok(Self { key, boot_id: boot_id.into(), max_ttl_ms: DEFAULT_MAX_TTL_MS, seen: Mutex::new(BTreeSet::new()) })
    }

    pub fn boot_id(&self) -> &str {
        &self.boot_id
    }

    /// Verify and (on success) burn the nonce. Constant-time HMAC comparison. `&self` (the
    /// nonce set is interior-mutable) so a single verifier can be shared across tasks.
    #[allow(clippy::too_many_arguments)]
    pub fn verify(
        &self, token: &str, action: &str, args: &Value, target: &str, nonce: &str,
        expiry_ms: i64, boot_id: &str, now_ms: i64,
    ) -> Result<(), ApprovalError> {
        if boot_id != self.boot_id {
            return Err(ApprovalError::WrongBoot);
        }
        if expiry_ms <= now_ms {
            return Err(ApprovalError::Expired);
        }
        if expiry_ms - now_ms > self.max_ttl_ms {
            return Err(ApprovalError::Expired);
        }
        // Hold the nonce lock across the whole check so verify+burn is atomic (no replay race).
        let mut seen = self.seen.lock().unwrap();
        if seen.contains(nonce) {
            return Err(ApprovalError::Replayed);
        }
        let payload = canonical_payload(action, args, target, nonce, expiry_ms, boot_id)?;
        let mut mac = HmacSha256::new_from_slice(&self.key).map_err(|_| ApprovalError::BadKey)?;
        mac.update(payload.as_bytes());
        let token_bytes = hex::decode(token).map_err(|_| ApprovalError::Mismatch)?;
        mac.verify_slice(&token_bytes).map_err(|_| ApprovalError::Mismatch)?;
        seen.insert(nonce.to_string());
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key() -> Vec<u8> {
        (0u8..32).collect()
    }
    const BOOT: &str = "boot-xyz";
    const NOW: i64 = 1_000_000;
    const EXP: i64 = 1_060_000; // +60s, within the 120s max TTL

    // --- cross-language parity with the Python reference (golden vectors) ---

    #[test]
    fn canonical_golden_vector() {
        let p = canonical_payload("killswitch.reset", &json!({}), "killswitch", "nonce-1", 1_718_000_000_000, BOOT).unwrap();
        assert_eq!(
            p,
            r#"{"action":"killswitch.reset","args":{},"boot_id":"boot-xyz","expiry_ms":1718000000000,"nonce":"nonce-1","target":"killswitch","v":1}"#
        );
        // byte-identical HMAC to Python's brainstem.approval.mint
        assert_eq!(
            mint(&key(), "killswitch.reset", &json!({}), "killswitch", "nonce-1", 1_718_000_000_000, BOOT).unwrap(),
            "30f2b224641b070b35a1544ac212fd223552325ee040f3d0ef0d26b7d87a2255"
        );
    }

    #[test]
    fn nested_args_sorted_parity() {
        let args = json!({"name": "shopping", "content": "milk, eggs"});
        let p = canonical_payload("write_note", &args, "shopping", "n1", 1_718_000_000_000, BOOT).unwrap();
        assert_eq!(
            p,
            r#"{"action":"write_note","args":{"content":"milk, eggs","name":"shopping"},"boot_id":"boot-xyz","expiry_ms":1718000000000,"nonce":"n1","target":"shopping","v":1}"#
        );
        assert_eq!(
            mint(&key(), "write_note", &args, "shopping", "n1", 1_718_000_000_000, BOOT).unwrap(),
            "f38b0c1d7fdbc9a7afda23b05fe910a9d40489f20e5923debc88f3385741a80e"
        );
    }

    // --- behavior parity ---

    fn verifier() -> ApprovalVerifier {
        ApprovalVerifier::new(key(), BOOT).unwrap()
    }

    #[test]
    fn valid_token_verifies_once() {
        let args = json!({"path": "/tmp/x", "flags": ["-f"]});
        let tok = mint(&key(), "terminal.exec", &args, "t", "n1", EXP, BOOT).unwrap();
        assert!(verifier().verify(&tok, "terminal.exec", &args, "t", "n1", EXP, BOOT, NOW).is_ok());
    }

    #[test]
    fn replay_rejected() {
        let tok = mint(&key(), "a", &json!({}), "t", "n1", EXP, BOOT).unwrap();
        let v = verifier();
        v.verify(&tok, "a", &json!({}), "t", "n1", EXP, BOOT, NOW).unwrap();
        assert_eq!(v.verify(&tok, "a", &json!({}), "t", "n1", EXP, BOOT, NOW), Err(ApprovalError::Replayed));
    }

    #[test]
    fn expired_and_unbounded_ttl_rejected() {
        let tok = mint(&key(), "a", &json!({}), "t", "n1", NOW - 1, BOOT).unwrap();
        assert_eq!(verifier().verify(&tok, "a", &json!({}), "t", "n1", NOW - 1, BOOT, NOW), Err(ApprovalError::Expired));
        let far = NOW + 10_000_000;
        let tok2 = mint(&key(), "a", &json!({}), "t", "n2", far, BOOT).unwrap();
        assert_eq!(verifier().verify(&tok2, "a", &json!({}), "t", "n2", far, BOOT, NOW), Err(ApprovalError::Expired));
    }

    #[test]
    fn cross_boot_replay_rejected() {
        let tok = mint(&key(), "a", &json!({}), "t", "n1", EXP, "boot-OLD").unwrap();
        assert_eq!(verifier().verify(&tok, "a", &json!({}), "t", "n1", EXP, "boot-OLD", NOW), Err(ApprovalError::WrongBoot));
    }

    #[test]
    fn tampered_args_rejected() {
        let tok = mint(&key(), "terminal.exec", &json!({"path": "/tmp/x"}), "t", "n1", EXP, BOOT).unwrap();
        assert_eq!(
            verifier().verify(&tok, "terminal.exec", &json!({"path": "/etc/passwd"}), "t", "n1", EXP, BOOT, NOW),
            Err(ApprovalError::Mismatch)
        );
    }

    #[test]
    fn wrong_key_rejected() {
        let tok = mint(&key(), "a", &json!({}), "t", "n1", EXP, BOOT).unwrap();
        let v = ApprovalVerifier::new(vec![9u8; 32], BOOT).unwrap();
        assert_eq!(v.verify(&tok, "a", &json!({}), "t", "n1", EXP, BOOT, NOW), Err(ApprovalError::Mismatch));
    }

    #[test]
    fn floats_rejected() {
        assert_eq!(canonical_payload("a", &json!({"amt": 1.5}), "t", "n", EXP, BOOT), Err(ApprovalError::FloatInArgs));
    }

    #[test]
    fn short_key_rejected() {
        assert_eq!(ApprovalVerifier::new(vec![0u8; 16], BOOT).err(), Some(ApprovalError::BadKey));
    }
}
