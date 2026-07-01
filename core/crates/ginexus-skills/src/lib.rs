//! Hot-loadable Skills — the "modular plugins" pillar. The core runs with ZERO skills; drop a
//! folder under the skills dir, restart, and the agent gains tools. A skill is `<dir>/skill.json`.
//!
//! Security model (hardened after an adversarial audit — this executes OS commands for an LLM):
//!   - NO shell (execvp); `{param}` values are substituted as SEPARATE argv elements.
//!   - Flag-injection guard: a substituted value may NOT introduce an argv element starting with
//!     `-` (skill authors put literal flags / `--` in the manifest `run` template themselves).
//!   - argv[0] must be ABSOLUTE, must exist, and must canonicalize to a path OUTSIDE the skills dir
//!     (so a malicious skill can't run a binary it shipped in its own folder; no $PATH hijack).
//!   - autonomy:"auto" (unattended, no Touch-ID) is honored ONLY for executables the CORE vouches
//!     for (DEFAULT_AUTO_ALLOW + operator-set GINEXUS_SKILLS_AUTO_ALLOW). A skill can NEVER
//!     self-enroll a non-vouched command into auto; everything else is HITL regardless of manifest.
//!   - Children run with a SCRUBBED env (no inherited secrets), a confined working dir, in their own
//!     process group (killed as a tree on timeout); output is bounded (no OOM), stdin is null.

pub mod playbooks; // Learning-loop B2: prose procedural "playbooks" (read + view; write side is B2b)

use ginexus_agent::{Tool, ToolResult};
use serde::Deserialize;
use serde_json::{json, Value};
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// Executables the core vouches for as safe to run UNATTENDED. Only these may be autonomy:"auto";
/// the operator can extend this out-of-band (never a skill manifest).
const DEFAULT_AUTO_ALLOW: &[&str] = &["/usr/bin/say", "/usr/bin/pbpaste"];
const MAX_OUTPUT: usize = 256 * 1024; // hard read cap (DoS) ; display is further trimmed

fn default_params() -> Value {
    json!({"type": "object", "properties": {}})
}
fn default_autonomy() -> String {
    "hitl".into()
}
fn default_kind() -> String {
    "command".into()
}

#[derive(Deserialize)]
pub struct SkillManifest {
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub version: String,
    #[serde(default)]
    pub tools: Vec<SkillTool>,
}

#[derive(Deserialize, Clone)]
pub struct SkillTool {
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default = "default_params")]
    pub params: Value,
    #[serde(default)]
    pub run: Vec<String>,
    #[serde(rename = "type", default = "default_kind")]
    pub kind: String,
    #[serde(default = "default_autonomy")]
    pub autonomy: String,
    #[serde(default)]
    pub timeout_secs: u64,
}

/// An MCP-server skill for the server to spawn + import via the existing MCP host.
pub struct McpSkill {
    pub name: String,
    /// argv[0] is already validated (absolute, exists, outside the skills dir).
    pub run: Vec<String>,
    pub autonomy: String,
}

/// The core-vouched executables permitted to run unattended (autonomy:"auto"). The operator can
/// extend this out-of-band; a skill manifest cannot.
pub fn default_auto_allow() -> Vec<String> {
    DEFAULT_AUTO_ALLOW.iter().map(|s| s.to_string()).collect()
}

#[derive(Default)]
pub struct Loaded {
    pub command_tools: Vec<Tool>,
    pub mcp_skills: Vec<McpSkill>,
    /// "name (N tools[, auto: …])" lines for boot logging.
    pub summary: Vec<String>,
}

/// Validate a skill executable: absolute, exists, and (canonicalized) NOT inside the skills dir.
/// Returns the canonical path to execute, or None to reject the tool.
fn validate_exec(argv0: &str, skills_dir: &Path) -> Option<String> {
    if !argv0.starts_with('/') {
        return None; // no relative / $PATH lookup
    }
    let canon = std::fs::canonicalize(argv0).ok()?; // resolves symlinks/..; None if missing
    if let Ok(skills_canon) = std::fs::canonicalize(skills_dir) {
        if canon.starts_with(&skills_canon) {
            return None; // refuse a binary the skill shipped inside its own (writable) folder
        }
    }
    Some(canon.to_string_lossy().to_string())
}

/// Scan `dir/*/skill.json` and produce command tools + MCP-skill specs. `auto_allow` is the set of
/// executables permitted to run unattended (autonomy:"auto"). `workdir` confines command CWD/HOME.
pub fn load_skills(dir: &Path, workdir: &Path, auto_allow: &[String]) -> Loaded {
    let mut out = Loaded::default();
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return out, // no skills dir → zero skills (valid)
    };
    for entry in entries.flatten() {
        let manifest = entry.path().join("skill.json");
        if !manifest.exists() {
            continue;
        }
        let m: SkillManifest = match std::fs::read_to_string(&manifest)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
        {
            Some(m) => m,
            None => {
                out.summary.push(format!("{}: SKIPPED (bad manifest)", entry.path().display()));
                continue;
            }
        };
        let mut n = 0usize;
        let mut autos: Vec<String> = Vec::new();
        for t in &m.tools {
            match t.kind.as_str() {
                "command" => {
                    if let Some((tool, is_auto)) = build_command_tool(t, dir, workdir, auto_allow) {
                        if is_auto {
                            autos.push(tool.name.clone());
                        }
                        out.command_tools.push(tool);
                        n += 1;
                    }
                }
                "mcp" if !t.run.is_empty() => {
                    if validate_exec(&t.run[0], dir).is_some() {
                        out.mcp_skills.push(McpSkill {
                            name: t.name.clone(),
                            run: t.run.clone(),
                            autonomy: t.autonomy.clone(),
                        });
                        n += 1;
                    }
                }
                _ => {}
            }
        }
        let auto_note = if autos.is_empty() { String::new() } else { format!(", auto: {}", autos.join("+")) };
        out.summary.push(format!("{} ({} tools{})", m.name, n, auto_note));
    }
    out
}

/// Stringify a JSON arg value for argv. Scalars only; arrays/objects are rejected upstream.
fn arg_string(v: &Value) -> Option<String> {
    match v {
        Value::String(s) => Some(s.clone()),
        Value::Null => Some(String::new()),
        Value::Bool(b) => Some(b.to_string()),
        Value::Number(n) => Some(n.to_string()),
        _ => None, // arrays/objects not allowed as command args
    }
}

/// Returns (tool, is_auto). is_auto means it runs unattended (no HITL).
fn build_command_tool(
    t: &SkillTool, skills_dir: &Path, workdir: &Path, auto_allow: &[String],
) -> Option<(Tool, bool)> {
    if t.run.is_empty() {
        return None;
    }
    let declared = t.run[0].clone();
    let canon_exec = validate_exec(&declared, skills_dir)?;
    let template: Vec<String> = t.run[1..].to_vec();
    let timeout = Duration::from_secs(if t.timeout_secs == 0 { 30 } else { t.timeout_secs.min(120) });
    // auto ONLY for core-vouched executables — a manifest can never self-grant unattended exec.
    let is_auto = t.autonomy == "auto" && auto_allow.iter().any(|a| a == &declared);
    let irreversible = !is_auto;
    let workdir = workdir.to_path_buf();
    let tool = Tool::new(
        &t.name,
        &t.description,
        t.params.clone(),
        irreversible,
        Arc::new(move |args| {
            // Build argv from the template, substituting {param} as one argv element each.
            let mut argv: Vec<String> = Vec::with_capacity(template.len());
            for tmpl in &template {
                match substitute(tmpl, &args) {
                    Ok(sub) => {
                        // Flag-injection guard: substitution must not turn an element into an option.
                        if &sub != tmpl && sub.starts_with('-') {
                            return ToolResult::err(
                                "skill argument may not begin with '-' (option injection); the skill's \
                                 run template must place flags itself (use '--' for option-bearing tools)",
                            );
                        }
                        argv.push(sub);
                    }
                    Err(e) => return ToolResult::err(e),
                }
            }
            run_command(&canon_exec, &argv, timeout, &workdir)
        }),
    );
    Some((tool, is_auto))
}

/// Replace `{key}` with the scalar value of args[key]. Each template element stays ONE argv element.
fn substitute(template: &str, args: &Value) -> Result<String, String> {
    let mut s = template.to_string();
    if let Some(obj) = args.as_object() {
        for (k, v) in obj {
            let needle = format!("{{{k}}}");
            if s.contains(&needle) {
                let val = arg_string(v).ok_or_else(|| format!("arg '{k}' must be a scalar value"))?;
                s = s.replace(&needle, &val);
            }
        }
    }
    Ok(s)
}

/// Run with no shell, scrubbed env, confined CWD, own process group (killed as a tree on timeout),
/// bounded output, draining pipes concurrently to avoid deadlock.
fn run_command(prog: &str, args: &[String], timeout: Duration, workdir: &Path) -> ToolResult {
    use std::io::Read;
    use std::os::unix::process::CommandExt;
    use std::process::{Child, ChildStderr, ChildStdout, Command, Stdio};

    fn drain<R: Read + Send + 'static>(pipe: Option<R>) -> std::thread::JoinHandle<String> {
        std::thread::spawn(move || {
            let mut kept: Vec<u8> = Vec::new();
            if let Some(mut r) = pipe {
                let mut buf = [0u8; 8192];
                loop {
                    match r.read(&mut buf) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            if kept.len() < MAX_OUTPUT {
                                let take = n.min(MAX_OUTPUT - kept.len());
                                kept.extend_from_slice(&buf[..take]);
                            } // else: keep reading to EOF but discard (prevents pipe-fill deadlock)
                        }
                    }
                }
            }
            String::from_utf8_lossy(&kept).to_string()
        })
    }

    let mut cmd = Command::new(prog);
    cmd.args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .current_dir(workdir)
        .env_clear()
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin")
        .env("HOME", workdir)
        .env("LANG", "en_US.UTF-8")
        .process_group(0); // own group → kill the whole tree on timeout
    if let Some(tmp) = std::env::var_os("TMPDIR") {
        cmd.env("TMPDIR", tmp);
    }

    let mut child: Child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return ToolResult::err(format!("spawn '{prog}' failed: {e}")),
    };
    let pgid = child.id() as i32; // group leader pid == pgid
    let oh = drain::<ChildStdout>(child.stdout.take());
    let eh = drain::<ChildStderr>(child.stderr.take());

    let start = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(st)) => break Some(st),
            Ok(None) => {
                if start.elapsed() > timeout {
                    // kill the whole process group (catches forked/detached grandchildren)
                    let _ = Command::new("/bin/kill").arg("-KILL").arg(format!("-{pgid}")).status();
                    let _ = child.kill();
                    let _ = child.wait();
                    break None;
                }
                std::thread::sleep(Duration::from_millis(40));
            }
            Err(e) => return ToolResult::err(format!("wait failed: {e}")),
        }
    };

    let stdout = oh.join().unwrap_or_default();
    let stderr = eh.join().unwrap_or_default();
    let status = match status {
        Some(s) => s,
        None => return ToolResult::err("skill command timed out"),
    };
    let mut body = if stdout.trim().is_empty() { stderr } else { stdout };
    if body.len() > 4000 {
        body.truncate(4000);
        body.push_str("…[truncated]");
    }
    let body = body.trim().to_string();
    if status.success() {
        ToolResult::ok(if body.is_empty() { "(done)".into() } else { body })
    } else {
        ToolResult::err(format!("[exit {}] {}", status.code().unwrap_or(-1), body))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static CTR: AtomicU64 = AtomicU64::new(0);
    fn dirs() -> (PathBuf, PathBuf) {
        let n = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let base = std::env::temp_dir().join(format!("gx-skills-{}-{}-{}", std::process::id(), n, CTR.fetch_add(1, Ordering::Relaxed)));
        let skills = base.join("skills");
        let work = base.join("work");
        std::fs::create_dir_all(&skills).unwrap();
        std::fs::create_dir_all(&work).unwrap();
        (skills, work)
    }
    fn write_skill(root: &Path, name: &str, json: &str) {
        let d = root.join(name);
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("skill.json"), json).unwrap();
    }

    #[test]
    fn loads_and_runs_command_skill() {
        let (skills, work) = dirs();
        write_skill(&skills, "echoer", r#"{"name":"echoer","tools":[
            {"name":"shout","type":"command","autonomy":"auto",
             "params":{"type":"object","properties":{"text":{"type":"string"}}},
             "run":["/bin/echo","{text}"]}]}"#);
        // /bin/echo is auto-allowed for this test
        let loaded = load_skills(&skills, &work, &["/bin/echo".to_string()]);
        assert_eq!(loaded.command_tools.len(), 1);
        let t = &loaded.command_tools[0];
        assert!(!t.irreversible); // auto + allow-listed → unattended
        assert_eq!(t.run(json!({"text": "hello world"})).output, "hello world");
        std::fs::remove_dir_all(skills.parent().unwrap()).ok();
    }

    #[test]
    fn auto_denied_unless_executable_is_vouched() {
        let (skills, work) = dirs();
        write_skill(&skills, "x", r#"{"name":"x","tools":[
            {"name":"x","type":"command","autonomy":"auto","run":["/bin/echo","hi"]}]}"#);
        // /bin/echo NOT in auto_allow → autonomy:auto is downgraded to HITL
        let loaded = load_skills(&skills, &work, &[]);
        assert!(loaded.command_tools[0].irreversible, "non-vouched exec must stay HITL even if manifest says auto");
        std::fs::remove_dir_all(skills.parent().unwrap()).ok();
    }

    #[test]
    fn no_shell_injection() {
        let (skills, work) = dirs();
        write_skill(&skills, "e", r#"{"name":"e","tools":[
            {"name":"e","type":"command","autonomy":"auto",
             "params":{"type":"object","properties":{"t":{"type":"string"}}},
             "run":["/bin/echo","{t}"]}]}"#);
        let t = &load_skills(&skills, &work, &["/bin/echo".to_string()]).command_tools[0];
        let r = t.run(json!({"t": "x; touch /tmp/gx_pwn; $(whoami)"}));
        assert!(r.ok);
        assert_eq!(r.output, "x; touch /tmp/gx_pwn; $(whoami)"); // literal, no shell
        std::fs::remove_dir_all(skills.parent().unwrap()).ok();
    }

    #[test]
    fn flag_injection_rejected() {
        let (skills, work) = dirs();
        write_skill(&skills, "e", r#"{"name":"e","tools":[
            {"name":"e","type":"command","autonomy":"auto",
             "params":{"type":"object","properties":{"t":{"type":"string"}}},
             "run":["/bin/echo","{t}"]}]}"#);
        let t = &load_skills(&skills, &work, &["/bin/echo".to_string()]).command_tools[0];
        let r = t.run(json!({"t": "--n=evil"})); // substituted value introduces an option
        assert!(!r.ok);
        assert!(r.output.contains("option injection"));
        std::fs::remove_dir_all(skills.parent().unwrap()).ok();
    }

    #[test]
    fn relative_and_skills_dir_executables_rejected() {
        let (skills, work) = dirs();
        // relative
        write_skill(&skills, "rel", r#"{"name":"rel","tools":[{"name":"r","type":"command","run":["echo","hi"]}]}"#);
        // a binary inside the skill's own folder (copy /bin/echo there)
        let payload = skills.join("evil");
        std::fs::create_dir_all(&payload).unwrap();
        let bin = payload.join("payload");
        std::fs::copy("/bin/echo", &bin).ok();
        let json = format!(r#"{{"name":"evil","tools":[{{"name":"p","type":"command","run":["{}","hi"]}}]}}"#, bin.display());
        std::fs::write(payload.join("skill.json"), json).unwrap();
        let loaded = load_skills(&skills, &work, &[]);
        assert_eq!(loaded.command_tools.len(), 0, "relative + in-skill-dir executables must be rejected");
        std::fs::remove_dir_all(skills.parent().unwrap()).ok();
    }

    #[test]
    fn default_autonomy_is_hitl() {
        let (skills, work) = dirs();
        write_skill(&skills, "w", r#"{"name":"w","tools":[{"name":"w","type":"command","run":["/bin/echo","hi"]}]}"#);
        assert!(load_skills(&skills, &work, &["/bin/echo".to_string()]).command_tools[0].irreversible);
        std::fs::remove_dir_all(skills.parent().unwrap()).ok();
    }

    #[test]
    fn timeout_kills_runaway() {
        let (skills, work) = dirs();
        write_skill(&skills, "slow", r#"{"name":"slow","tools":[
            {"name":"slow","type":"command","timeout_secs":1,"run":["/bin/sleep","30"]}]}"#);
        let t = &load_skills(&skills, &work, &[]).command_tools[0];
        let start = Instant::now();
        let r = t.run(json!({}));
        assert!(!r.ok && r.output.contains("timed out"));
        assert!(start.elapsed().as_secs() < 5);
        std::fs::remove_dir_all(skills.parent().unwrap()).ok();
    }

    #[test]
    fn missing_dir_is_empty() {
        let loaded = load_skills(Path::new("/nonexistent/gx/skills"), Path::new("/tmp"), &[]);
        assert!(loaded.command_tools.is_empty() && loaded.mcp_skills.is_empty());
    }
}
