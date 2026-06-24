//! SP-Robotics (Phase 1+2) — the design → fabricate pipeline.
//!
//! GINEXUS authors a part as OpenSCAD source (a *sandboxed geometry DSL*: no shell, no network, no
//! arbitrary code execution — confirmed against OpenSCAD's own issue #4747), renders it to an STL via
//! the OFFICIAL, notarized OpenSCAD (Developer ID: Marius Kintel, checksum-verified install), then
//! slices the STL to printable G-code via the OFFICIAL Prusa Research PrusaSlicer (invoked only as an
//! unmodified external CLI, so its AGPL stays isolated from GINEXUS's code).
//!
//! PSS: SCAD's ONLY filesystem reach is the file primitives (import/include/use/surface) — there is no
//! network/exec — so `cad_generate` REJECTS any SCAD containing them, making generation fully
//! self-contained (robot parts are authored inline anyway). Both tools only produce files (no hardware
//! is touched), so they are autonomous; sending G-code to a real printer (Phase 3) will be HITL.
use crate::{abbreviate_home, Tool, ToolResult};
use serde_json::json;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

const OPENSCAD: &str = "/Applications/OpenSCAD.app/Contents/MacOS/OpenSCAD";
const PRUSASLICER: &str = "/Applications/PrusaSlicer.app/Contents/MacOS/PrusaSlicer";

/// Reject SCAD that reaches the filesystem. import/include/use/surface are the only file primitives
/// (SCAD has no shell/network/eval), so forbidding them eliminates the read vector entirely.
fn scad_file_ref(scad: &str) -> Option<&'static str> {
    let l = scad.to_lowercase();
    for bad in ["import(", "include ", "include<", "use ", "use<", "surface("] {
        if l.contains(bad) {
            return Some(bad);
        }
    }
    None
}

fn is_icloud(p: &str) -> bool {
    p.contains("Mobile Documents") || p.contains("com~apple~CloudDocs")
}

fn sanitize_name(raw: &str) -> String {
    let s: String = raw
        .chars()
        .map(|c| if c.is_alphanumeric() || c == '-' || c == '_' { c } else { '_' })
        .collect();
    let s = s.trim_matches('_').to_string();
    if s.is_empty() {
        "part".into()
    } else {
        s.chars().take(60).collect()
    }
}

/// Run a command with a wall-clock timeout, killing the child if it overruns (DoS guard against
/// pathological geometry). No external crates.
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
                std::thread::sleep(Duration::from_millis(100));
            }
            Err(e) => return Err(format!("wait: {e}")),
        }
    }
}

/// Resolve an stl/config path: absolute or `~` honored (iCloud refused); a bare name resolves inside
/// the robotics workspace.
fn resolve_in(dir: &Path, raw: &str) -> Option<PathBuf> {
    let expanded = if let Some(rest) = raw.strip_prefix('~') {
        match std::env::var("HOME") {
            Ok(h) => format!("{h}{rest}"),
            Err(_) => raw.to_string(),
        }
    } else {
        raw.to_string()
    };
    if is_icloud(&expanded) {
        return None;
    }
    let p = PathBuf::from(&expanded);
    if p.is_absolute() {
        Some(p)
    } else {
        // bare/relative → single filename inside the workspace (no traversal)
        let name = Path::new(&expanded).file_name()?.to_string_lossy().to_string();
        Some(dir.join(name))
    }
}

pub fn cad_generate_tool(robotics_dir: PathBuf) -> Tool {
    let dir = Arc::new(robotics_dir);
    Tool::new(
        "cad_generate",
        "Design a 3D-printable PART by writing OpenSCAD code and rendering it to an STL mesh. `scad` = \
         complete OpenSCAD source with the geometry authored INLINE (cube/cylinder/sphere/hull/\
         difference/union/linear_extrude/rotate_extrude/etc.). Do NOT use import/include/use/surface — \
         they are rejected for safety; build the part from primitives. `name` = the part name. Returns \
         the saved STL path. Use for robot parts (brackets, motor mounts, gears, enclosures); then call \
         cad_slice to make printable G-code. Do not paste the absolute path or username in your reply.",
        json!({"type": "object",
               "properties": {
                   "scad": {"type": "string", "description": "complete OpenSCAD source; geometry authored inline (no import/include/use/surface)"},
                   "name": {"type": "string", "description": "part name (used as the file basename)"}},
               "required": ["scad", "name"]}),
        false, // autonomous: produces a file, touches no hardware
        Arc::new(move |a| {
            let scad = a.get("scad").and_then(|v| v.as_str()).unwrap_or("").trim();
            if scad.is_empty() {
                return ToolResult::err("missing 'scad'");
            }
            if let Some(bad) = scad_file_ref(scad) {
                return ToolResult::err(format!(
                    "for safety, SCAD may not reference files (found '{}') — author the geometry inline from primitives",
                    bad.trim()
                ));
            }
            if !Path::new(OPENSCAD).exists() {
                return ToolResult::err("OpenSCAD is not installed (/Applications/OpenSCAD.app). Install the official build first.");
            }
            let name = sanitize_name(a.get("name").and_then(|v| v.as_str()).unwrap_or("part"));
            if std::fs::create_dir_all(dir.as_path()).is_err() {
                return ToolResult::err("could not create the robotics workspace");
            }
            let scad_path = dir.join(format!("{name}.scad"));
            let stl_path = dir.join(format!("{name}.stl"));
            if std::fs::write(&scad_path, scad).is_err() {
                return ToolResult::err("could not write the SCAD file");
            }
            let mut cmd = Command::new(OPENSCAD);
            cmd.args([
                "-o",
                &stl_path.to_string_lossy(),
                "--hardwarnings",
                &scad_path.to_string_lossy(),
            ]);
            match run_with_timeout(cmd, 60) {
                Ok(out) => {
                    let ok = stl_path.exists()
                        && std::fs::metadata(&stl_path).map(|m| m.len() > 0).unwrap_or(false);
                    if ok {
                        ToolResult::ok(format!("Rendered part → {}", abbreviate_home(&stl_path.to_string_lossy())))
                    } else {
                        let err = String::from_utf8_lossy(&out.stderr);
                        ToolResult::err(format!(
                            "OpenSCAD produced no STL (check the geometry): {}",
                            err.lines().take(4).collect::<Vec<_>>().join(" ")
                        ))
                    }
                }
                Err(e) => ToolResult::err(format!("OpenSCAD render failed: {e}")),
            }
        }),
    )
}

pub fn cad_slice_tool(robotics_dir: PathBuf) -> Tool {
    let dir = Arc::new(robotics_dir);
    Tool::new(
        "cad_slice",
        "Slice an STL into printable G-code with PrusaSlicer. `stl` = the STL path returned by \
         cad_generate (or a filename in the robotics workspace). Optional `config` = path to a \
         PrusaSlicer config.ini exported for your printer (File → Export → Export Config); without it, \
         factory defaults (generic 0.4 mm FDM) are used. Returns the G-code path + print estimate. \
         Sending G-code to a real printer is a later, approval-gated step. Do not paste the absolute \
         path or username in your reply.",
        json!({"type": "object",
               "properties": {
                   "stl": {"type": "string", "description": "STL path or workspace filename"},
                   "config": {"type": "string", "description": "optional PrusaSlicer config.ini path for your printer"}},
               "required": ["stl"]}),
        false, // autonomous: produces a file, touches no hardware
        Arc::new(move |a| {
            if !Path::new(PRUSASLICER).exists() {
                return ToolResult::err("PrusaSlicer is not installed (/Applications/PrusaSlicer.app).");
            }
            let stl_raw = a.get("stl").and_then(|v| v.as_str()).unwrap_or("").trim();
            if stl_raw.is_empty() {
                return ToolResult::err("missing 'stl'");
            }
            let stl_path = match resolve_in(dir.as_path(), stl_raw) {
                Some(p) => p,
                None => return ToolResult::err("refusing an iCloud path — keep files local"),
            };
            if !stl_path.exists() {
                return ToolResult::err(format!("STL not found: {}", abbreviate_home(&stl_path.to_string_lossy())));
            }
            let stem = stl_path.file_stem().and_then(|s| s.to_str()).unwrap_or("part");
            let gcode_path = dir.join(format!("{stem}.gcode"));
            let mut cmd = Command::new(PRUSASLICER);
            cmd.arg("--export-gcode");
            if let Some(cfg) = a.get("config").and_then(|v| v.as_str()) {
                if let Some(cfgp) = resolve_in(dir.as_path(), cfg.trim()) {
                    if cfgp.exists() {
                        cmd.arg("--load").arg(&cfgp);
                    }
                }
            }
            cmd.arg(&stl_path).arg("-o").arg(&gcode_path);
            match run_with_timeout(cmd, 180) {
                Ok(out) => {
                    let ok = gcode_path.exists()
                        && std::fs::metadata(&gcode_path).map(|m| m.len() > 0).unwrap_or(false);
                    if ok {
                        let est = gcode_summary(&gcode_path);
                        ToolResult::ok(format!("Sliced → {} {est}", abbreviate_home(&gcode_path.to_string_lossy())))
                    } else {
                        let err = String::from_utf8_lossy(&out.stderr);
                        ToolResult::err(format!(
                            "slicing produced no G-code: {}",
                            err.lines().take(4).collect::<Vec<_>>().join(" ")
                        ))
                    }
                }
                Err(e) => ToolResult::err(format!("slicing failed: {e}")),
            }
        }),
    )
}

/// Extract the print-time + filament estimate PrusaSlicer writes as footer comments.
fn gcode_summary(path: &Path) -> String {
    let content = std::fs::read_to_string(path).unwrap_or_default();
    let mut time = String::new();
    let mut grams = String::new();
    for line in content.lines().rev().take(80) {
        if time.is_empty() && line.contains("estimated printing time") {
            time = line.split('=').next_back().unwrap_or("").trim().to_string();
        }
        if grams.is_empty() && line.contains("filament used [g]") {
            grams = line.split('=').next_back().unwrap_or("").trim().to_string();
        }
    }
    match (time.is_empty(), grams.is_empty()) {
        (false, false) => format!("(~{time}, {grams} g filament)"),
        (false, true) => format!("(~{time})"),
        (true, false) => format!("({grams} g filament)"),
        _ => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_file_references() {
        assert!(scad_file_ref("import(\"/etc/passwd\");").is_some());
        assert!(scad_file_ref("include <secret.scad>").is_some());
        assert!(scad_file_ref("use <thing.scad>").is_some());
        assert!(scad_file_ref("surface(\"h.dat\");").is_some());
        assert!(scad_file_ref("cube([10,10,10]); difference() { sphere(5); }").is_none());
    }

    #[test]
    fn names_sanitized() {
        assert_eq!(sanitize_name("../../etc/passwd"), "etc_passwd");
        assert_eq!(sanitize_name("NEMA-17 bracket!"), "NEMA-17_bracket");
        assert_eq!(sanitize_name(""), "part");
    }

    // End-to-end: render a real STL via the installed OpenSCAD (skips if not installed).
    #[test]
    fn cad_generate_renders_stl() {
        if !Path::new(OPENSCAD).exists() {
            eprintln!("skip: OpenSCAD not installed");
            return;
        }
        let dir = std::env::temp_dir().join(format!("gx-robo-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let tool = cad_generate_tool(dir.clone());
        let r = tool.run(json!({"scad": "cube([12,12,12], center=true);", "name": "tcube"}));
        assert!(r.ok, "render failed: {}", r.output);
        assert!(dir.join("tcube.stl").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn cad_generate_rejects_unsafe_scad() {
        let dir = std::env::temp_dir().join("gx-robo-reject");
        let tool = cad_generate_tool(dir);
        let r = tool.run(json!({"scad": "import(\"/Users/x/secret.stl\");", "name": "x"}));
        assert!(!r.ok);
        assert!(r.output.contains("may not reference files"));
    }
}
