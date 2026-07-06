//! PrinterRegistry — the configured printer fleet, persisted as JSON in the GINEXUS state dir
//! (`fab/printers.json`, 0o700 like every other state dir). API keys are NEVER stored here —
//! only the name of an environment variable the signed app injects from the Keychain
//! (same discipline as settings.mcpServers).

use crate::driver::PrinterDriver;
use crate::mock::MockPrinter;
use crate::moonraker::MoonrakerPrinter;
use crate::octoprint::OctoPrinter;
use crate::sdcp::client::SdcpPrinter;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrinterConfig {
    pub id: String,
    pub name: String,
    /// "sdcp" | "octoprint" | "moonraker" | "mock"
    pub kind: String,
    /// ip[:port] or base URL. Empty for mock.
    #[serde(default)]
    pub host: String,
    /// SDCP MainboardID (from discovery); empty for HTTP backends.
    #[serde(default)]
    pub mainboard_id: String,
    /// Printer model string (drives the slice format map), e.g. "ELEGOO Saturn 4 Ultra".
    #[serde(default)]
    pub model: String,
    /// Env var holding the API key (OctoPrint/Moonraker). The key itself never lands on disk.
    #[serde(default)]
    pub api_key_env: String,
}

impl PrinterConfig {
    /// Build the live driver for this config. Mock requires no host.
    pub fn driver(&self) -> Result<Box<dyn PrinterDriver>, String> {
        match self.kind.as_str() {
            "mock" => Ok(Box::new(MockPrinter::new())),
            "sdcp" => {
                if self.host.is_empty() {
                    return Err("sdcp printer needs a host/IP".into());
                }
                Ok(Box::new(SdcpPrinter::new(self.host.clone(), self.mainboard_id.clone())))
            }
            "octoprint" => {
                let key = self.api_key().unwrap_or_default();
                if key.is_empty() {
                    return Err(format!(
                        "octoprint printer '{}' needs an API key (set env {})",
                        self.name,
                        if self.api_key_env.is_empty() { "GINEXUS_FAB_KEY_<id>" } else { &self.api_key_env }
                    ));
                }
                Ok(Box::new(OctoPrinter::new(&self.host, key)))
            }
            "moonraker" => Ok(Box::new(MoonrakerPrinter::new(&self.host, self.api_key()))),
            other => Err(format!("unknown printer kind '{other}'")),
        }
    }

    fn api_key(&self) -> Option<String> {
        if self.api_key_env.is_empty() {
            return None;
        }
        std::env::var(&self.api_key_env).ok().filter(|v| !v.is_empty())
    }
}

pub struct PrinterRegistry {
    path: PathBuf,
    printers: Vec<PrinterConfig>,
}

impl PrinterRegistry {
    /// Open (or create) the registry under `fab_dir`.
    pub fn open(fab_dir: PathBuf) -> Self {
        let _ = std::fs::create_dir_all(&fab_dir);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&fab_dir, std::fs::Permissions::from_mode(0o700));
        }
        let path = fab_dir.join("printers.json");
        let printers = std::fs::read_to_string(&path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        Self { path, printers }
    }

    fn save(&self) {
        if let Ok(json) = serde_json::to_string_pretty(&self.printers) {
            let _ = std::fs::write(&self.path, json);
        }
    }

    pub fn list(&self) -> &[PrinterConfig] {
        &self.printers
    }

    pub fn get(&self, id: &str) -> Option<&PrinterConfig> {
        self.printers.iter().find(|p| p.id == id)
    }

    /// Add a printer; the id is derived from the name (stable, filesystem-safe, unique).
    pub fn add(&mut self, mut cfg: PrinterConfig) -> Result<String, String> {
        if cfg.name.trim().is_empty() {
            return Err("printer needs a name".into());
        }
        if !matches!(cfg.kind.as_str(), "sdcp" | "octoprint" | "moonraker" | "mock") {
            return Err(format!("unknown printer kind '{}'", cfg.kind));
        }
        if cfg.kind != "mock" && cfg.host.trim().is_empty() {
            return Err("printer needs a host/IP".into());
        }
        let base: String = cfg
            .name
            .to_lowercase()
            .chars()
            .map(|c| if c.is_alphanumeric() { c } else { '-' })
            .collect::<String>()
            .trim_matches('-')
            .chars()
            .take(40)
            .collect();
        let base = if base.is_empty() { "printer".to_string() } else { base };
        let mut id = base.clone();
        let mut n = 1;
        while self.printers.iter().any(|p| p.id == id) {
            n += 1;
            id = format!("{base}-{n}");
        }
        cfg.id = id.clone();
        self.printers.push(cfg);
        self.save();
        Ok(id)
    }

    pub fn remove(&mut self, id: &str) -> bool {
        let before = self.printers.len();
        self.printers.retain(|p| p.id != id);
        let removed = self.printers.len() != before;
        if removed {
            self.save();
        }
        removed
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_dir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("gx-fabreg-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        d
    }

    #[test]
    fn add_persist_reload_remove() {
        let dir = tmp_dir("basic");
        let mut reg = PrinterRegistry::open(dir.clone());
        let id = reg
            .add(PrinterConfig {
                id: String::new(),
                name: "Saturn 4 Ultra".into(),
                kind: "sdcp".into(),
                host: "192.168.1.44".into(),
                mainboard_id: "mb1".into(),
                model: "ELEGOO Saturn 4 Ultra".into(),
                api_key_env: String::new(),
            })
            .expect("add");
        assert_eq!(id, "saturn-4-ultra");

        // Duplicate names get numbered ids.
        let id2 = reg
            .add(PrinterConfig {
                id: String::new(),
                name: "Saturn 4 Ultra".into(),
                kind: "mock".into(),
                host: String::new(),
                mainboard_id: String::new(),
                model: String::new(),
                api_key_env: String::new(),
            })
            .unwrap();
        assert_eq!(id2, "saturn-4-ultra-2");

        // Reload from disk.
        let reg2 = PrinterRegistry::open(dir.clone());
        assert_eq!(reg2.list().len(), 2);
        assert_eq!(reg2.get("saturn-4-ultra").unwrap().host, "192.168.1.44");

        let mut reg3 = PrinterRegistry::open(dir.clone());
        assert!(reg3.remove("saturn-4-ultra"));
        assert!(!reg3.remove("saturn-4-ultra"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn rejects_bad_configs() {
        let dir = tmp_dir("bad");
        let mut reg = PrinterRegistry::open(dir.clone());
        assert!(reg
            .add(PrinterConfig {
                id: String::new(),
                name: "".into(),
                kind: "sdcp".into(),
                host: "1.2.3.4".into(),
                mainboard_id: String::new(),
                model: String::new(),
                api_key_env: String::new(),
            })
            .is_err());
        assert!(reg
            .add(PrinterConfig {
                id: String::new(),
                name: "X".into(),
                kind: "teleporter".into(),
                host: "1.2.3.4".into(),
                mainboard_id: String::new(),
                model: String::new(),
                api_key_env: String::new(),
            })
            .is_err());
        // Driver construction: octoprint without a key errors; mock always works.
        let cfg = PrinterConfig {
            id: "x".into(),
            name: "X".into(),
            kind: "octoprint".into(),
            host: "1.2.3.4".into(),
            mainboard_id: String::new(),
            model: String::new(),
            api_key_env: "GX_TEST_NO_SUCH_ENV".into(),
        };
        assert!(cfg.driver().is_err());
        let mock = PrinterConfig {
            id: "m".into(),
            name: "M".into(),
            kind: "mock".into(),
            host: String::new(),
            mainboard_id: String::new(),
            model: String::new(),
            api_key_env: String::new(),
        };
        assert!(mock.driver().is_ok());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
