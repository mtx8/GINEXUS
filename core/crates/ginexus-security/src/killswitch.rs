//! Three-tier kill switch — monotonic, persistent, biometric-gated reset (Rust core).
//! Port of `killswitch.py`. A lower tier never downgrades a higher active one; the engaged
//! tier persists to a 0600 state file and rehydrates on construction (a restart cannot
//! silently clear a `nuclear` panic); reset requires an authorized (biometric-backed) caller.

use std::path::PathBuf;
use thiserror::Error;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Tier {
    Soft = 1,
    Hard = 2,
    Nuclear = 3,
}

impl Tier {
    pub fn as_str(self) -> &'static str {
        match self {
            Tier::Soft => "soft",
            Tier::Hard => "hard",
            Tier::Nuclear => "nuclear",
        }
    }
    pub fn parse(s: &str) -> Option<Tier> {
        match s {
            "soft" => Some(Tier::Soft),
            "hard" => Some(Tier::Hard),
            "nuclear" => Some(Tier::Nuclear),
            _ => None,
        }
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum KillSwitchError {
    #[error("kill switch engaged (tier={0})")]
    Engaged(String),
    #[error("kill-switch reset requires biometric authorization")]
    ResetDenied,
}

pub struct KillSwitch {
    engaged: bool,
    tier: Option<Tier>,
    state_path: Option<PathBuf>,
}

impl KillSwitch {
    pub fn new(state_path: Option<PathBuf>) -> Self {
        let mut ks = Self { engaged: false, tier: None, state_path };
        ks.rehydrate();
        ks
    }

    fn rehydrate(&mut self) {
        if let Some(p) = &self.state_path {
            if let Ok(s) = std::fs::read_to_string(p) {
                if let Some(t) = Tier::parse(s.trim()) {
                    self.engaged = true;
                    self.tier = Some(t);
                }
            }
        }
    }

    fn persist(&self, t: Tier) {
        if let Some(p) = &self.state_path {
            if let Some(parent) = p.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            if std::fs::write(p, t.as_str()).is_ok() {
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    let _ = std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o600));
                }
            }
        }
    }

    fn clear_persisted(&self) {
        if let Some(p) = &self.state_path {
            let _ = std::fs::remove_file(p);
        }
    }

    pub fn engaged(&self) -> bool {
        self.engaged
    }
    pub fn tier(&self) -> Option<Tier> {
        self.tier
    }

    /// Engage at `tier`; return the EFFECTIVE tier. Monotonic + persisted before returning.
    pub fn engage(&mut self, tier: Tier, _reason: &str) -> Tier {
        if self.engaged {
            if let Some(cur) = self.tier {
                if tier < cur {
                    return cur; // refuse to relax a higher active tier
                }
            }
        }
        self.engaged = true;
        self.tier = Some(tier);
        self.persist(tier);
        tier
    }

    /// Disengage. PRIVILEGED: requires an authorized (biometric-backed) caller.
    pub fn reset(&mut self, authorized: bool) -> Result<(), KillSwitchError> {
        if !authorized {
            return Err(KillSwitchError::ResetDenied);
        }
        self.engaged = false;
        self.tier = None;
        self.clear_persisted();
        Ok(())
    }

    pub fn guard(&self) -> Result<(), KillSwitchError> {
        if self.engaged {
            return Err(KillSwitchError::Engaged(
                self.tier.map(|t| t.as_str().to_string()).unwrap_or_default(),
            ));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn tmp() -> PathBuf {
        let n = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        std::env::temp_dir().join(format!("ginexus-ks-{}-{}.state", std::process::id(), n))
    }

    #[test]
    fn starts_disengaged() {
        let ks = KillSwitch::new(None);
        assert!(!ks.engaged());
        assert!(ks.guard().is_ok());
    }

    #[test]
    fn soft_engage_blocks_guard() {
        let mut ks = KillSwitch::new(None);
        ks.engage(Tier::Soft, "t");
        assert!(matches!(ks.guard(), Err(KillSwitchError::Engaged(_))));
    }

    #[test]
    fn monotonic_no_downgrade() {
        let mut ks = KillSwitch::new(None);
        ks.engage(Tier::Nuclear, "panic");
        assert_eq!(ks.engage(Tier::Soft, "oops"), Tier::Nuclear);
        assert_eq!(ks.tier(), Some(Tier::Nuclear));
    }

    #[test]
    fn escalation_raises_tier() {
        let mut ks = KillSwitch::new(None);
        assert_eq!(ks.engage(Tier::Soft, ""), Tier::Soft);
        assert_eq!(ks.engage(Tier::Hard, ""), Tier::Hard);
        assert_eq!(ks.engage(Tier::Nuclear, ""), Tier::Nuclear);
    }

    #[test]
    fn nuclear_survives_restart() {
        let p = tmp();
        let mut ks = KillSwitch::new(Some(p.clone()));
        ks.engage(Tier::Nuclear, "panic");
        // new instance over the same state file = a "restart"
        let ks2 = KillSwitch::new(Some(p.clone()));
        assert!(ks2.engaged() && ks2.tier() == Some(Tier::Nuclear));
        std::fs::remove_file(&p).ok();
    }

    #[test]
    fn unauthorized_reset_denied() {
        let mut ks = KillSwitch::new(None);
        ks.engage(Tier::Hard, "x");
        assert_eq!(ks.reset(false), Err(KillSwitchError::ResetDenied));
        assert!(ks.engaged());
    }

    #[test]
    fn authorized_reset_clears_state() {
        let p = tmp();
        let mut ks = KillSwitch::new(Some(p.clone()));
        ks.engage(Tier::Hard, "x");
        ks.reset(true).unwrap();
        assert!(!p.exists());
        assert!(!KillSwitch::new(Some(p.clone())).engaged());
        std::fs::remove_file(&p).ok();
    }
}
