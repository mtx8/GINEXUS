//! Setup Assistant backend — the onboarding brain. Detects the machine's capabilities and what's
//! installed, then recommends a right-sized local model. Mac-mini-first: the default 30B-A3B daily
//! driver needs ~24 GB of USABLE RAM, which the common 16 GB base Mac mini does not have — so the
//! recommendation engine downshifts to a model that actually fits rather than assuming the flagship.
//!
//! The pure logic (usable_ram / fit / recommend) is unit-tested against real Mac configs; the
//! probes shell out to sysctl/df and check well-known paths (best-effort, never panic).

use serde::Serialize;
use serde_json::{json, Value};
use std::path::Path;

// ── hardware ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize)]
pub struct Hardware {
    pub chip: String,
    pub apple_silicon: bool,
    pub ram_gb: f64,
    /// RAM minus the macOS/app reserve — the realistic budget for model + KV cache.
    pub usable_ram_gb: f64,
    pub free_storage_gb: f64,
    pub cpu_cores: u32,
    pub perf_cores: u32,
}

/// macOS + app overhead reserve. Calibrated to observed reality across the range: a 64 GB machine
/// leaves ~51 GB usable (benchmarks report ~48 with apps open), a 16 GB Mac mini ~13 GB, an 8 GB
/// machine ~5 GB. Reserve = 20% of RAM, floored at 3 GB (macOS is lean on tiny machines) and
/// capped at 16 GB (large machines don't need a proportional reserve).
pub fn usable_ram_gb(ram_gb: f64) -> f64 {
    let reserve = (ram_gb * 0.20).clamp(3.0, 16.0);
    (ram_gb - reserve).max(0.0)
}

fn sysctl(key: &str) -> Option<String> {
    std::process::Command::new("/usr/sbin/sysctl")
        .args(["-n", key])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Free space on the home volume in GB (best-effort via `df -k $HOME`).
fn free_storage_gb() -> f64 {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/".into());
    std::process::Command::new("/bin/df")
        .args(["-k", &home])
        .output()
        .ok()
        .and_then(|o| {
            let s = String::from_utf8_lossy(&o.stdout);
            // Second line, 4th column = available 1K-blocks.
            s.lines().nth(1)?.split_whitespace().nth(3)?.parse::<f64>().ok()
        })
        .map(|kb| kb / 1_048_576.0)
        .unwrap_or(0.0)
}

pub fn probe_hardware() -> Hardware {
    let chip = sysctl("machdep.cpu.brand_string").unwrap_or_else(|| "Unknown CPU".into());
    let apple_silicon = chip.contains("Apple");
    let ram_bytes = sysctl("hw.memsize").and_then(|s| s.parse::<f64>().ok()).unwrap_or(0.0);
    let ram_gb = ram_bytes / 1_073_741_824.0;
    let cpu_cores = sysctl("hw.ncpu").and_then(|s| s.parse().ok()).unwrap_or(0);
    let perf_cores = sysctl("hw.perflevel0.logicalcpu").and_then(|s| s.parse().ok()).unwrap_or(0);
    Hardware {
        chip,
        apple_silicon,
        ram_gb: (ram_gb * 10.0).round() / 10.0,
        usable_ram_gb: (usable_ram_gb(ram_gb) * 10.0).round() / 10.0,
        free_storage_gb: (free_storage_gb() * 10.0).round() / 10.0,
        cpu_cores,
        perf_cores,
    }
}

// ── dependencies ──────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize)]
pub struct Dependencies {
    pub ollama_installed: bool,
    pub ollama_path: Option<String>,
    pub ollama_running: bool,
    pub ollama_version: Option<String>,
    pub homebrew: bool,
    pub prusaslicer: bool,
    pub uvtools: bool,
    pub openscad: bool,
}

fn which(bin: &str, candidates: &[&str]) -> Option<String> {
    for c in candidates {
        if Path::new(c).exists() {
            return Some(c.to_string());
        }
    }
    // Fall back to `command -v` via a login-ish PATH probe.
    std::process::Command::new("/usr/bin/which")
        .arg(bin)
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Probe dependencies. Liveness (`ollama_running` + `ollama_version`) is determined by the caller
/// via the gateway's async HTTP client and passed in — so this stays a pure path/binary probe
/// (installed-but-not-running is a distinct, useful state the wizard shows).
pub fn probe_deps(ollama_running: bool, ollama_version: Option<String>) -> Dependencies {
    let ollama_path = which("ollama", &["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]);
    Dependencies {
        ollama_installed: ollama_path.is_some()
            || ollama_running
            || Path::new("/Applications/Ollama.app").exists(),
        ollama_path,
        ollama_running,
        ollama_version,
        homebrew: which("brew", &["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]).is_some(),
        prusaslicer: Path::new("/Applications/PrusaSlicer.app").exists(),
        uvtools: Path::new("/Applications/UVtools.app").exists(),
        openscad: Path::new("/Applications/OpenSCAD.app").exists(),
    }
}

// ── model catalog + fit ───────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Fit {
    Comfortable,
    Tight,
    WontFit,
}

#[derive(Debug, Clone, Serialize)]
pub struct CatalogModel {
    pub id: String,        // Ollama tag
    pub label: String,
    pub role: String,      // chat | code | reasoning | vision | embed | utility
    pub params: String,
    pub size_gb: f64,      // download / disk
    pub min_ram_gb: f64,   // usable RAM for a COMFORTABLE experience
    pub note: String,
}

/// Assess how a model fits a given usable-RAM budget.
pub fn fit(size_gb: f64, min_ram_gb: f64, usable_ram_gb: f64) -> Fit {
    if usable_ram_gb >= min_ram_gb {
        Fit::Comfortable
    } else if usable_ram_gb >= size_gb + 2.0 {
        Fit::Tight
    } else {
        Fit::WontFit
    }
}

/// The curated catalog — real Ollama tags, verified formats where possible. The daily-driver tag
/// (qwen3:30b-a3b-instruct-2507-q4_K_M) matches the project's pinned roster.
pub fn catalog() -> Vec<CatalogModel> {
    let m = |id: &str, label: &str, role: &str, params: &str, size: f64, min: f64, note: &str| {
        CatalogModel {
            id: id.into(), label: label.into(), role: role.into(), params: params.into(),
            size_gb: size, min_ram_gb: min, note: note.into(),
        }
    };
    vec![
        m("qwen3:1.7b", "Qwen3 1.7B", "utility", "1.7B", 1.4, 6.0,
          "Tiny + fast; router/utility. Runs on anything."),
        m("qwen3:4b", "Qwen3 4B", "chat", "4B", 2.6, 8.0,
          "Light local chat for 8 GB machines."),
        m("qwen3:8b", "Qwen3 8B", "chat", "8B", 5.2, 12.0,
          "Capable local chat; the sweet spot for a 16 GB Mac mini."),
        m("qwen3:14b", "Qwen3 14B", "chat", "14B", 9.3, 18.0,
          "Strong local chat for a 24 GB Mac mini."),
        m("qwen3:30b-a3b-instruct-2507-q4_K_M", "Qwen3 30B-A3B (2507)", "chat", "30B-A3B MoE", 18.0, 30.0,
          "The flagship daily driver — a 3B-active MoE, so fast for its size. Needs a 32 GB+ machine."),
        m("gpt-oss:20b", "GPT-OSS 20B", "reasoning", "20B", 13.0, 24.0,
          "Open reasoning model; a lighter escalation tier."),
        m("gpt-oss:120b", "GPT-OSS 120B", "reasoning", "120B MoE", 63.0, 96.0,
          "Max escalation. Only for 96 GB+ (Studio/Max); otherwise use a cloud API for this tier."),
        m("qwen3-vl:30b-a3b-instruct", "Qwen3-VL 30B-A3B", "vision", "30B-A3B MoE", 18.0, 30.0,
          "Vision (image understanding). Optional; pulls only when you need image input."),
        m("nomic-embed-text", "nomic-embed-text", "embed", "137M", 0.3, 4.0,
          "Embeddings for memory/search. Tiny — always recommended."),
    ]
}

/// The recommended DAILY-DRIVER chat model for a usable-RAM budget. This is the Mac-mini ladder:
/// pick the most capable chat model that at least fits "tight".
pub fn recommend_daily_driver(usable_ram_gb: f64) -> &'static str {
    if usable_ram_gb >= 24.0 {
        "qwen3:30b-a3b-instruct-2507-q4_K_M"
    } else if usable_ram_gb >= 16.0 {
        "qwen3:14b"
    } else if usable_ram_gb >= 10.0 {
        "qwen3:8b"
    } else if usable_ram_gb >= 4.0 {
        "qwen3:4b"
    } else {
        "qwen3:1.7b"
    }
}

/// Full probe → the JSON the Setup Assistant renders. `installed` = model tags already pulled
/// (from Ollama /api/tags) so the wizard can mark them. Liveness is passed in from the async caller.
pub fn probe_json(
    ollama_running: bool, ollama_version: Option<String>, installed: &[String],
) -> Value {
    let hw = probe_hardware();
    let deps = probe_deps(ollama_running, ollama_version);
    let usable = hw.usable_ram_gb;
    let recommended = recommend_daily_driver(usable);
    let models: Vec<Value> = catalog()
        .into_iter()
        .map(|c| {
            let f = fit(c.size_gb, c.min_ram_gb, usable);
            let is_installed = installed.iter().any(|t| tag_matches(t, &c.id));
            json!({
                "id": c.id, "label": c.label, "role": c.role, "params": c.params,
                "size_gb": c.size_gb, "min_ram_gb": c.min_ram_gb, "note": c.note,
                "fit": f, "installed": is_installed, "recommended": c.id == recommended,
            })
        })
        .collect();
    json!({
        "hardware": hw,
        "dependencies": deps,
        "models": models,
        "recommended_daily_driver": recommended,
        "verdict": verdict(usable, recommended),
    })
}

/// Ollama tags may carry a `:latest` suffix or digest differences; match on the base tag.
fn tag_matches(installed: &str, catalog_id: &str) -> bool {
    installed == catalog_id
        || installed.strip_suffix(":latest").map(|b| b == catalog_id).unwrap_or(false)
        || catalog_id.strip_suffix(":latest").map(|b| b == installed).unwrap_or(false)
        // base name match (e.g. "nomic-embed-text:latest" vs "nomic-embed-text")
        || installed.split(':').next() == catalog_id.split(':').next()
            && catalog_id.split(':').nth(1).is_none()
}

/// A one-line human verdict for the System-Check screen.
fn verdict(usable_ram_gb: f64, recommended: &str) -> String {
    let cap = catalog();
    let label = cap.iter().find(|c| c.id == recommended).map(|c| c.label.as_str()).unwrap_or(recommended);
    if usable_ram_gb >= 24.0 {
        format!("Comfortable — runs the full daily driver ({label}) locally.")
    } else if usable_ram_gb >= 10.0 {
        format!("Good — best local fit is {label}; use a cloud API for the heaviest tier.")
    } else {
        format!("Limited local memory — {label} runs locally; lean on a cloud API for capable chat.")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn usable_ram_matches_observed_reality() {
        // 64 GB machine leaves ~51 GB usable (benchmark reports ~48 with apps open).
        assert!((usable_ram_gb(64.0) - 51.2).abs() < 0.5);
        // 16 GB base Mac mini → ~13 GB usable.
        assert!((usable_ram_gb(16.0) - 12.8).abs() < 0.5);
        // 8 GB machine → ~5 GB usable (lean macOS reserve floor).
        assert!((usable_ram_gb(8.0) - 5.0).abs() < 0.5);
        // 192 GB Ultra → reserve capped at 16.
        assert_eq!(usable_ram_gb(192.0), 176.0);
    }

    #[test]
    fn mac_mini_ladder() {
        // The heart of the Mac-mini strategy — right-size the daily driver by usable RAM.
        assert_eq!(recommend_daily_driver(usable_ram_gb(16.0)), "qwen3:8b");   // 16 GB base
        assert_eq!(recommend_daily_driver(usable_ram_gb(24.0)), "qwen3:14b");  // 24 GB
        assert_eq!(recommend_daily_driver(usable_ram_gb(32.0)),                // 32 GB M4 Pro
                   "qwen3:30b-a3b-instruct-2507-q4_K_M");
        assert_eq!(recommend_daily_driver(usable_ram_gb(48.0)),                // 48 GB M4 Pro
                   "qwen3:30b-a3b-instruct-2507-q4_K_M");
        assert_eq!(recommend_daily_driver(usable_ram_gb(64.0)),                // 64 GB M4 Pro
                   "qwen3:30b-a3b-instruct-2507-q4_K_M");
        // 8 GB (old machine) → small but useful.
        assert_eq!(recommend_daily_driver(usable_ram_gb(8.0)), "qwen3:4b");
        // 4 GB (very old) → tiny utility model.
        assert_eq!(recommend_daily_driver(usable_ram_gb(4.0)), "qwen3:1.7b");
    }

    #[test]
    fn fit_assessment() {
        let usable16 = usable_ram_gb(16.0); // ~12.8
        assert_eq!(fit(2.6, 8.0, usable16), Fit::Comfortable);  // 4B fits
        assert_eq!(fit(5.2, 12.0, usable16), Fit::Comfortable); // 8B fits (the 16 GB daily driver)
        assert_eq!(fit(9.3, 18.0, usable16), Fit::Tight);       // 14B tight
        assert_eq!(fit(18.0, 30.0, usable16), Fit::WontFit);    // 30B won't fit on 16 GB
        let usable64 = usable_ram_gb(64.0); // ~51
        assert_eq!(fit(18.0, 30.0, usable64), Fit::Comfortable); // 30B comfortable
        assert_eq!(fit(63.0, 96.0, usable64), Fit::WontFit);     // 120B won't fit
    }

    #[test]
    fn catalog_has_the_daily_driver_with_real_tag() {
        let c = catalog();
        assert!(c.iter().any(|m| m.id == "qwen3:30b-a3b-instruct-2507-q4_K_M"));
        assert!(c.iter().any(|m| m.id == "nomic-embed-text"));
        // Every model has a positive size and a sane min-RAM.
        for m in c {
            assert!(m.size_gb > 0.0 && m.min_ram_gb >= 4.0, "{}", m.id);
        }
    }

    #[test]
    fn tag_matching_is_lenient() {
        assert!(tag_matches("nomic-embed-text:latest", "nomic-embed-text"));
        assert!(tag_matches("qwen3:30b-a3b-instruct-2507-q4_K_M", "qwen3:30b-a3b-instruct-2507-q4_K_M"));
        assert!(!tag_matches("qwen3:1.7b", "qwen3:8b"));
    }
}
