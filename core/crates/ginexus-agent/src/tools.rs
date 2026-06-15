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
}

impl ToolResult {
    pub fn ok(output: impl Into<String>) -> Self {
        Self { ok: true, output: output.into() }
    }
    pub fn err(output: impl Into<String>) -> Self {
        Self { ok: false, output: output.into() }
    }
}

// Owned-arg closure so the runner can be cloned + moved into spawn_blocking (network/file
// tools run on the blocking pool, never blocking the async agent loop).
pub type ToolFn = Arc<dyn Fn(Value) -> ToolResult + Send + Sync>;

pub struct Tool {
    pub name: String,
    pub description: String,
    pub parameters: Value,
    pub irreversible: bool,
    run: ToolFn,
}

impl Tool {
    pub fn new(
        name: impl Into<String>, description: impl Into<String>, parameters: Value,
        irreversible: bool, run: ToolFn,
    ) -> Self {
        Self { name: name.into(), description: description.into(), parameters, irreversible, run }
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
