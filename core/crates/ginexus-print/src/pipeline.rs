//! Slice pipeline — external, unmodified CLIs only (AGPL isolation, same doctrine as
//! robotics.rs): PrusaSlicer for FDM gcode and SLA .sl1, UVtoolsCmd for SL1→native resin
//! conversion + post-slice validation (islands / resin traps / suction cups).
//!
//! Resin flow:  model.stl ─PrusaSlicer──▶ part.sl1 ─UVtoolsCmd convert──▶ part.goo/.ctb/.pm7…
//!              └ UVtoolsCmd print-issues part.<ext>  (the authoritative post-slice gate)
//! FDM flow:    model.stl ─PrusaSlicer──▶ part.gcode
//!
//! Exposure/lift settings are NEVER synthesized here — they come from the curated profile .ini
//! the caller passes (UVtools ships per-printer PrusaSlicer profiles embedding the
//! FILEFORMAT_ token that `convert … auto` uses to pick the right native container).

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

// PSS: external tools run ONLY from fixed /Applications bundle paths — never a $PATH lookup
// (PATH hijacking) and never a user-writable prefix like /usr/local/bin. The module NEVER
// downloads or installs anything; missing tools produce an instruction to install the OFFICIAL
// build manually (PrusaSlicer from prusa3d.com — Developer ID: Prusa Research; UVtools from
// github.com/sn4k3/UVtools releases). Both are invoked as unmodified external CLIs (AGPL
// isolation) and their code signature is verified before first use each run.
pub const PRUSASLICER: &str = "/Applications/PrusaSlicer.app/Contents/MacOS/PrusaSlicer";
pub const UVTOOLSCMD: &str = "/Applications/UVtools.app/Contents/MacOS/UVtoolsCmd";
const PRUSASLICER_APP: &str = "/Applications/PrusaSlicer.app";
const UVTOOLS_APP: &str = "/Applications/UVtools.app";

/// PSS gate: refuse to execute an external tool whose bundle fails macOS code-signature
/// verification (tamper/substitution guard). `codesign -v` exits 0 for a valid signature.
/// Operators running an unsigned build can consciously override with
/// GINEXUS_FAB_ALLOW_UNSIGNED_TOOLS=1 — the override is loud in the error text otherwise.
fn verify_signature(app_bundle: &str) -> Result<(), String> {
    if std::env::var("GINEXUS_FAB_ALLOW_UNSIGNED_TOOLS").map(|v| v == "1").unwrap_or(false) {
        return Ok(());
    }
    let out = Command::new("/usr/bin/codesign")
        .args(["-v", app_bundle])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    match out {
        Ok(s) if s.success() => Ok(()),
        Ok(_) => Err(format!(
            "{app_bundle} fails code-signature verification — refusing to run it (PSS). \
             Reinstall the official build, or set GINEXUS_FAB_ALLOW_UNSIGNED_TOOLS=1 to \
             consciously accept the risk."
        )),
        Err(e) => Err(format!("cannot verify {app_bundle} signature: {e}")),
    }
}

/// Printer technology drives which pipeline runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tech {
    Fdm,
    Resin,
}

/// Native file extension expected per printer model (verified against UVtools' shipped
/// profiles). The LIVE printer attributes (`SupportFileType`) win over this table when known.
pub fn native_format_for(model: &str) -> (Tech, &'static str) {
    let m = model.to_lowercase();
    if m.contains("centauri") {
        return (Tech::Fdm, "gcode");
    }
    if m.contains("saturn 4 ultra") {
        // Encrypted CTB is the default, but .goo keeps our validators usable — prefer it.
        return (Tech::Resin, "goo");
    }
    if m.contains("saturn 4") || m.contains("mars 5") || m.contains("mars 4") {
        return (Tech::Resin, "goo");
    }
    if m.contains("saturn") || m.contains("mars") {
        return (Tech::Resin, "ctb");
    }
    if m.contains("m7 pro") {
        return (Tech::Resin, "pwsz");
    }
    if m.contains("m7 max") {
        return (Tech::Resin, "pm7m");
    }
    if m.contains("m7") {
        return (Tech::Resin, "pm7");
    }
    if m.contains("photon") {
        return (Tech::Resin, "pwmx");
    }
    // Unknown models default to FDM gcode — the safest wrong answer (fails loudly at upload).
    (Tech::Fdm, "gcode")
}

pub fn uvtools_path() -> Option<&'static str> {
    if Path::new(UVTOOLSCMD).exists() { Some(UVTOOLSCMD) } else { None }
}

pub fn prusaslicer_available() -> bool {
    Path::new(PRUSASLICER).exists()
}

/// PSS preflight for a pipeline step: tool present AND signature-valid.
fn preflight(app: &str, binary: &str, install_hint: &str) -> Result<(), String> {
    if !Path::new(binary).exists() {
        return Err(format!("{install_hint} — GINEXUS never downloads or installs tools itself"));
    }
    verify_signature(app)
}

/// Run a command with a wall-clock timeout (slicing pathological geometry is a DoS vector).
fn run_with_timeout(mut cmd: Command, secs: u64) -> Result<std::process::Output, String> {
    let mut child = cmd
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("spawn failed: {e}"))?;
    let start = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return child.wait_with_output().map_err(|e| format!("wait: {e}")),
            Ok(None) => {
                if start.elapsed() > Duration::from_secs(secs) {
                    let _ = child.kill();
                    return Err(format!("timed out after {secs}s"));
                }
                std::thread::sleep(Duration::from_millis(150));
            }
            Err(e) => return Err(format!("wait: {e}")),
        }
    }
}

fn stderr_head(out: &std::process::Output) -> String {
    String::from_utf8_lossy(&out.stderr).lines().take(4).collect::<Vec<_>>().join(" ")
}

/// FDM: STL → gcode. `config_ini` = a full exported PrusaSlicer config for the target printer
/// (profile-name flags need a configured datadir; --load is the robust headless pattern).
pub fn slice_fdm(stl: &Path, config_ini: Option<&Path>, out_dir: &Path) -> Result<PathBuf, String> {
    preflight(PRUSASLICER_APP, PRUSASLICER,
              "PrusaSlicer is not installed — install the official build from prusa3d.com into /Applications")?;
    std::fs::create_dir_all(out_dir).map_err(|e| format!("workspace: {e}"))?;
    let stem = stl.file_stem().and_then(|s| s.to_str()).unwrap_or("part");
    let gcode = out_dir.join(format!("{stem}.gcode"));
    let mut cmd = Command::new(PRUSASLICER);
    if let Some(cfg) = config_ini {
        cmd.arg("--load").arg(cfg);
    }
    cmd.arg("--export-gcode").arg(stl).arg("--output").arg(&gcode);
    let out = run_with_timeout(cmd, 300)?;
    if gcode.exists() && std::fs::metadata(&gcode).map(|m| m.len() > 0).unwrap_or(false) {
        Ok(gcode)
    } else {
        Err(format!("slicing produced no G-code: {}", stderr_head(&out)))
    }
}

/// Resin step 1: STL → SL1 zip via PrusaSlicer SLA. The profile .ini MUST be a resin printer
/// profile (e.g. the UVtools-shipped "Elegoo Saturn 4 Ultra.ini") — it carries layer height,
/// exposure, lift, and the FILEFORMAT_ token for auto conversion.
pub fn slice_resin_sl1(stl: &Path, profile_ini: &Path, out_dir: &Path) -> Result<PathBuf, String> {
    preflight(PRUSASLICER_APP, PRUSASLICER,
              "PrusaSlicer is not installed — install the official build from prusa3d.com into /Applications")?;
    if !profile_ini.exists() {
        return Err(format!("resin profile not found: {}", profile_ini.display()));
    }
    std::fs::create_dir_all(out_dir).map_err(|e| format!("workspace: {e}"))?;
    let stem = stl.file_stem().and_then(|s| s.to_str()).unwrap_or("part");
    let sl1 = out_dir.join(format!("{stem}.sl1"));
    let mut cmd = Command::new(PRUSASLICER);
    cmd.arg("--load")
        .arg(profile_ini)
        .arg("--export-sla")
        .arg("--printer-technology")
        .arg("SLA")
        .arg(stl)
        .arg("--output")
        .arg(&sl1);
    let out = run_with_timeout(cmd, 600)?;
    if sl1.exists() && std::fs::metadata(&sl1).map(|m| m.len() > 0).unwrap_or(false) {
        Ok(sl1)
    } else {
        Err(format!("SLA slicing produced no SL1: {}", stderr_head(&out)))
    }
}

/// Resin step 2: SL1 → native container. `target_ext` like "goo"/"ctb"/"pm7", or "auto" to let
/// UVtools read the FILEFORMAT_ token from the profile notes.
pub fn convert_sl1(sl1: &Path, target_ext: &str, out_dir: &Path) -> Result<PathBuf, String> {
    preflight(UVTOOLS_APP, UVTOOLSCMD,
              "UVtools is not installed — install the official release from github.com/sn4k3/UVtools into /Applications")?;
    let uv = UVTOOLSCMD;
    std::fs::create_dir_all(out_dir).map_err(|e| format!("workspace: {e}"))?;
    let mut cmd = Command::new(uv);
    cmd.arg("convert").arg(sl1).arg(target_ext).arg(out_dir);
    let out = run_with_timeout(cmd, 600)?;
    // UVtools writes <stem>.<ext> into out_dir; find the newest non-sl1 artifact with the stem.
    let stem = sl1.file_stem().and_then(|s| s.to_str()).unwrap_or("part").to_string();
    let found = std::fs::read_dir(out_dir)
        .map_err(|e| format!("read workspace: {e}"))?
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            p.file_stem().and_then(|s| s.to_str()) == Some(stem.as_str())
                && p.extension().and_then(|x| x.to_str()) != Some("sl1")
                && p.extension().and_then(|x| x.to_str()) != Some("stl")
        })
        .max_by_key(|p| std::fs::metadata(p).and_then(|m| m.modified()).ok());
    match found {
        Some(p) => Ok(p),
        None => Err(format!("UVtools conversion produced no output: {}", stderr_head(&out))),
    }
}

/// Post-slice resin gate: UVtoolsCmd print-issues — islands, resin traps, suction cups.
/// Returns the raw (trimmed) report text; empty/“no issues” output means clean. This can take
/// minutes on 12K files — callers must not run it inline in a UI thread.
pub fn validate_sliced(file: &Path) -> Result<String, String> {
    preflight(UVTOOLS_APP, UVTOOLSCMD,
              "UVtools is not installed — cannot validate the sliced file (install the official release from github.com/sn4k3/UVtools)")?;
    let uv = UVTOOLSCMD;
    let mut cmd = Command::new(uv);
    cmd.arg("print-issues").arg(file);
    let out = run_with_timeout(cmd, 900)?;
    let mut text = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if text.len() > 4000 {
        text.truncate(4000);
        text.push_str("…[truncated]");
    }
    if text.is_empty() {
        text = "no issues reported".into();
    }
    Ok(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_map_is_sane() {
        assert_eq!(native_format_for("ELEGOO Saturn 4 Ultra"), (Tech::Resin, "goo"));
        assert_eq!(native_format_for("Elegoo Mars 5 Ultra"), (Tech::Resin, "goo"));
        assert_eq!(native_format_for("ELEGOO Saturn 3"), (Tech::Resin, "ctb"));
        assert_eq!(native_format_for("Anycubic Photon Mono M7 Pro"), (Tech::Resin, "pwsz"));
        assert_eq!(native_format_for("Anycubic Photon Mono M7 Max"), (Tech::Resin, "pm7m"));
        assert_eq!(native_format_for("Anycubic Photon Mono M7"), (Tech::Resin, "pm7"));
        assert_eq!(native_format_for("ELEGOO Centauri Carbon"), (Tech::Fdm, "gcode"));
        assert_eq!(native_format_for("Some Unknown Printer"), (Tech::Fdm, "gcode"));
    }

    #[test]
    fn missing_tools_error_cleanly() {
        // These paths exist only when the operator installed the apps — on a bare machine the
        // pipeline must return instructive errors, never panic.
        let stl = std::env::temp_dir().join("gx-pipe-nonexistent.stl");
        if !prusaslicer_available() {
            assert!(slice_fdm(&stl, None, &std::env::temp_dir()).is_err());
        }
        if uvtools_path().is_none() {
            let e = validate_sliced(&stl).unwrap_err();
            assert!(e.contains("UVtools"), "got: {e}");
        }
    }
}
