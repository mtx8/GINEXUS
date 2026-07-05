//! Tool registry + sandbox-safe built-in tools (Rust core). Port of `agent/tools.py`.
//! Tools declare an OpenAI-style schema + whether they're IRREVERSIBLE (HITL-gated).
//! The built-ins touch only a notes dir (no network/traversal).

use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;

pub struct ToolResult {
    pub ok: bool,
    pub output: String,
    /// Absolute filesystem paths of any files this tool produced this call (generated images,
    /// written documents, saved copies). Surfaced to the app so it can render an in-app artifact
    /// viewer for "anything I asked GINEXUS to generate." Empty for tools that create no files.
    /// NEVER `~`-abbreviated — the app needs a real path to preview, copy, and reveal the file.
    pub artifacts: Vec<String>,
}

impl ToolResult {
    pub fn ok(output: impl Into<String>) -> Self {
        Self { ok: true, output: output.into(), artifacts: Vec::new() }
    }
    pub fn err(output: impl Into<String>) -> Self {
        Self { ok: false, output: output.into(), artifacts: Vec::new() }
    }
    /// Attach the absolute path of a file this tool just produced (chainable). Empty paths are
    /// ignored so producers can pass a best-effort value without guarding at the call site.
    pub fn with_artifact(mut self, path: impl Into<String>) -> Self {
        let p = path.into();
        if !p.is_empty() {
            self.artifacts.push(p);
        }
        self
    }
}

// Owned-arg closure so the runner can be cloned + moved into spawn_blocking (network/file
// tools run on the blocking pool, never blocking the async agent loop).
pub type ToolFn = Arc<dyn Fn(Value) -> ToolResult + Send + Sync>;

#[derive(Clone)]
pub struct Tool {
    pub name: String,
    pub description: String,
    pub parameters: Value,
    pub irreversible: bool,
    /// Hard-gate: ALWAYS requires explicit approval, even in fully-autonomous mode (the
    /// non-overridable gate for money / external comms / legal / irreversible delete / arbitrary
    /// execution). Ordinary irreversible tools are gated only in HITL mode.
    pub hard_gate: bool,
    run: ToolFn,
}

impl Tool {
    pub fn new(
        name: impl Into<String>, description: impl Into<String>, parameters: Value,
        irreversible: bool, run: ToolFn,
    ) -> Self {
        Self { name: name.into(), description: description.into(), parameters, irreversible, hard_gate: false, run }
    }

    /// Mark this tool as hard-gated (always requires approval, even in autonomous mode).
    pub fn hard_gated(mut self) -> Self {
        self.hard_gate = true;
        self
    }
    pub fn definition(&self) -> Value {
        json!({"type": "function", "function": {
            "name": self.name, "description": self.description, "parameters": self.parameters,
        }})
    }
    pub fn run(&self, args: Value) -> ToolResult {
        (self.run)(args)
    }
    /// Clone the runner closure for off-loop (spawn_blocking) execution.
    pub fn runner(&self) -> ToolFn {
        self.run.clone()
    }
}

#[derive(Default)]
pub struct ToolRegistry {
    tools: BTreeMap<String, Tool>,
}

impl ToolRegistry {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn register(&mut self, t: Tool) {
        self.tools.insert(t.name.clone(), t);
    }
    pub fn get(&self, name: &str) -> Option<&Tool> {
        self.tools.get(name)
    }
    pub fn definitions(&self) -> Vec<Value> {
        self.tools.values().map(|t| t.definition()).collect()
    }
    /// A registry of only read-only (non-irreversible) tools — what subagents are given, so a
    /// worker can never perform an HITL-gated / irreversible action on its own.
    pub fn readonly(&self) -> ToolRegistry {
        ToolRegistry {
            tools: self
                .tools
                .iter()
                .filter(|(_, t)| !t.irreversible)
                .map(|(k, t)| (k.clone(), t.clone()))
                .collect(),
        }
    }
    pub fn names(&self) -> Vec<String> {
        self.tools.keys().cloned().collect()
    }
}

/// Reject names that could escape the notes dir; return the safe path inside `base`.
fn safe_note_path(base: &PathBuf, name: &str) -> Result<PathBuf, String> {
    if name.is_empty() || name.contains('/') || name.contains('\\') || name.contains("..") {
        return Err("invalid note name".into());
    }
    Ok(base.join(name))
}

fn ensure_dir(base: &PathBuf) {
    let _ = std::fs::create_dir_all(base);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(base, std::fs::Permissions::from_mode(0o700));
    }
}

/// Default registry: write_note (irreversible) + read_note (read-only), confined to `notes_dir`.
pub fn notes_registry(notes_dir: PathBuf) -> ToolRegistry {
    let mut reg = ToolRegistry::new();
    let base_w = Arc::new(notes_dir.clone());
    let base_r = Arc::new(notes_dir);

    reg.register(Tool::new(
        "write_note",
        "Save a short text note to the user's local notes (persists on this Mac).",
        json!({"type": "object",
               "properties": {"name": {"type": "string"}, "content": {"type": "string"}},
               "required": ["name", "content"]}),
        true,
        Arc::new(move |args: Value| {
            let name = args.get("name").and_then(|v| v.as_str()).unwrap_or("").trim();
            let content = args.get("content").and_then(|v| v.as_str()).unwrap_or("");
            let path = match safe_note_path(&base_w, name) {
                Ok(p) => p,
                Err(e) => return ToolResult::err(e),
            };
            ensure_dir(&base_w);
            match std::fs::write(&path, content) {
                Ok(_) => ToolResult::ok(format!("wrote {} bytes to note '{}'", content.len(), name)),
                Err(e) => ToolResult::err(format!("write failed: {e}")),
            }
        }),
    ));

    reg.register(Tool::new(
        "read_note",
        "Read back a previously saved local note by name.",
        json!({"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}),
        false,
        Arc::new(move |args: Value| {
            let name = args.get("name").and_then(|v| v.as_str()).unwrap_or("").trim();
            let path = match safe_note_path(&base_r, name) {
                Ok(p) => p,
                Err(e) => return ToolResult::err(e),
            };
            match std::fs::read_to_string(&path) {
                Ok(s) => ToolResult::ok(s),
                Err(_) => ToolResult::err(format!("note '{}' not found", name)),
            }
        }),
    ));
    reg
}

/// Safe terminal tool (SP4): runs an ALLOW-LISTED bare program with TYPED args in a confined
/// workdir, via std::process::Command — NO shell, so no injection/globbing/piping. Irreversible
/// → every invocation is HITL-gated (the approved {program,args} is exactly what executes).
pub fn terminal_tool(workdir: PathBuf, allowlist: Vec<String>) -> Tool {
    use std::collections::HashSet;
    let allow: HashSet<String> = allowlist.into_iter().collect();
    let wd = Arc::new(workdir);
    Tool::new(
        "run_command",
        "Run an allow-listed program with typed args in a confined workspace (NO shell; every \
         invocation requires approval). Provide {program: bare name, args: [string]}.",
        json!({"type": "object",
               "properties": {"program": {"type": "string"},
                              "args": {"type": "array", "items": {"type": "string"}}},
               "required": ["program"]}),
        true, // irreversible → HITL on every run (terminal autonomy max = approve-every-invocation)
        Arc::new(move |a: Value| {
            let program = a.get("program").and_then(|v| v.as_str()).unwrap_or("").to_string();
            if program.is_empty() || program.contains('/') {
                return ToolResult::err("program must be a bare allow-listed name (no path)");
            }
            if !allow.contains(&program) {
                return ToolResult::err(format!("'{program}' is not on the terminal allow-list"));
            }
            let args: Vec<String> = a
                .get("args")
                .and_then(|v| v.as_array())
                .map(|arr| arr.iter().filter_map(|x| x.as_str().map(String::from)).collect())
                .unwrap_or_default();
            let _ = std::fs::create_dir_all(&*wd);
            match std::process::Command::new(&program).args(&args).current_dir(&*wd).output() {
                Ok(o) => {
                    let mut s = String::from_utf8_lossy(&o.stdout).into_owned();
                    if !o.stderr.is_empty() {
                        s.push_str(&format!("\n[stderr] {}", String::from_utf8_lossy(&o.stderr)));
                    }
                    if s.len() > 4000 {
                        s.truncate(4000);
                        s.push_str("…[truncated]");
                    }
                    ToolResult::ok(format!("[exit {}] {}", o.status.code().unwrap_or(-1), s.trim()))
                }
                Err(e) => ToolResult::err(format!("exec failed: {e}")),
            }
        }),
    )
    .hard_gated() // arbitrary execution → always requires approval, even in autonomous mode
}

#[cfg(test)]
mod terminal_tests {
    use super::*;

    fn tool() -> Tool {
        terminal_tool(std::env::temp_dir(), vec!["echo".into(), "date".into()])
    }

    #[test]
    fn rejects_non_allowlisted() {
        assert!(!tool().run(json!({"program": "rm", "args": ["-rf", "/"]})).ok);
    }

    #[test]
    fn rejects_path_program() {
        assert!(!tool().run(json!({"program": "/bin/sh", "args": ["-c", "echo hi"]})).ok);
    }

    #[test]
    fn is_irreversible() {
        assert!(tool().irreversible); // must be HITL-gated
    }

    #[test]
    fn runs_allowlisted_no_shell() {
        // echo with literal args — no shell, so "$(whoami)" is a literal, not executed.
        let res = tool().run(json!({"program": "echo", "args": ["hello", "$(whoami)"]}));
        assert!(res.ok);
        assert!(res.output.contains("hello $(whoami)"), "got: {}", res.output);
    }
}
