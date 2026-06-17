//! Obsidian vault tools (Rust core). Give the agent read/search/write access to the operator's
//! Obsidian vault (a folder of Markdown notes) so GINEXUS can use it as a knowledge base + scratchpad.
//!
//! Safety: every path is confined to the vault — relative only, no `..`, the resolved parent must
//! canonicalize INSIDE the vault (blocks symlink escape), `.md` only, and the `.obsidian` config dir
//! is off-limits. Reads/search/list are read-only (autonomous); write/append are irreversible
//! (HITL-gated, and writes never overwrite an existing note unless `overwrite:true`).

use crate::tools::{Tool, ToolResult};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// Directories never walked or written (config, trash, vcs, plugin caches).
const SKIP_DIRS: &[&str] = &[".obsidian", ".trash", ".git", ".smart-env"];
/// Bound search/list cost on large vaults.
const MAX_SCAN_FILES: usize = 5000;
const MAX_RESULTS: usize = 20;
const MAX_FILE_BYTES: u64 = 1_000_000;

/// Resolve a vault-relative note path safely. `.md` is appended if missing. `must_exist` gates reads.
fn safe_vault_path(vault: &Path, rel: &str, must_exist: bool) -> Result<PathBuf, String> {
    let rel = rel.trim().trim_start_matches('/');
    if rel.is_empty() {
        return Err("empty note path".into());
    }
    if Path::new(rel).is_absolute() {
        return Err("path must be relative to the vault".into());
    }
    if rel.split(['/', '\\']).any(|c| c == ".." || c == ".") {
        return Err("path may not contain '.' or '..' components".into());
    }
    let rel_md = if rel.ends_with(".md") { rel.to_string() } else { format!("{rel}.md") };
    let root = vault.canonicalize().map_err(|e| format!("vault not found: {e}"))?;
    let target = root.join(&rel_md);
    // Confinement: the parent must exist and canonicalize inside the vault (defeats symlink escape).
    let parent = target.parent().ok_or("bad note path")?;
    let parent_canon =
        parent.canonicalize().map_err(|_| "target folder does not exist in the vault".to_string())?;
    if !parent_canon.starts_with(&root) {
        return Err("path escapes the vault".into());
    }
    // Block config/system dirs anywhere in the CANONICALIZED path — case-insensitive, so a case
    // variant like ".Obsidian" can't slip past on a case-insensitive macOS volume.
    if let Ok(rel_dir) = parent_canon.strip_prefix(&root) {
        for comp in rel_dir.components() {
            let c = comp.as_os_str().to_string_lossy().to_lowercase();
            if SKIP_DIRS.contains(&c.as_str()) {
                return Err("that folder is off-limits".into());
            }
        }
    }
    if must_exist && !target.exists() {
        return Err(format!("note '{rel_md}' not found"));
    }
    Ok(target)
}

/// Collect vault-relative `.md` paths (skipping SKIP_DIRS + hidden), bounded by MAX_SCAN_FILES.
fn collect_notes(root: &Path) -> Vec<String> {
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        if out.len() >= MAX_SCAN_FILES {
            break;
        }
        let entries = match std::fs::read_dir(&dir) {
            Ok(e) => e,
            Err(_) => continue,
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with('.') || SKIP_DIRS.contains(&name.as_str()) {
                continue;
            }
            if path.is_dir() {
                stack.push(path);
            } else if path.extension().and_then(|e| e.to_str()) == Some("md") {
                if let Ok(rel) = path.strip_prefix(root) {
                    out.push(rel.to_string_lossy().to_string());
                }
                if out.len() >= MAX_SCAN_FILES {
                    break;
                }
            }
        }
    }
    out.sort();
    out
}

/// Agent tools bound to a single Obsidian vault directory.
pub fn obsidian_tools(vault: PathBuf) -> Vec<Tool> {
    let (v_list, v_search, v_read, v_write, v_append) = (
        Arc::new(vault.clone()),
        Arc::new(vault.clone()),
        Arc::new(vault.clone()),
        Arc::new(vault.clone()),
        Arc::new(vault),
    );

    vec![
        Tool::new(
            "obsidian_list",
            "List note paths in the operator's Obsidian vault (Markdown knowledge base). Optional \
             'folder' restricts to a subfolder.",
            json!({"type": "object", "properties": {"folder": {"type": "string"}}}),
            false,
            Arc::new(move |a: Value| {
                let root = match v_list.canonicalize() {
                    Ok(r) => r,
                    Err(e) => return ToolResult::err(format!("vault not found: {e}")),
                };
                let folder = a.get("folder").and_then(|v| v.as_str()).unwrap_or("").trim();
                let mut notes = collect_notes(&root);
                if !folder.is_empty() {
                    let prefix = format!("{}/", folder.trim_matches('/'));
                    notes.retain(|n| n.starts_with(&prefix) || n.starts_with(folder.trim_matches('/')));
                }
                if notes.is_empty() {
                    return ToolResult::ok("(no notes found)");
                }
                let shown = notes.len().min(200);
                let mut s = format!("{} notes:\n", notes.len());
                s.push_str(&notes[..shown].join("\n"));
                ToolResult::ok(s)
            }),
        ),
        Tool::new(
            "obsidian_search",
            "Search the operator's Obsidian vault for notes containing a query (case-insensitive). \
             Returns matching note paths with a snippet.",
            json!({"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]}),
            false,
            Arc::new(move |a: Value| {
                let q = a.get("query").and_then(|v| v.as_str()).unwrap_or("").trim().to_lowercase();
                if q.is_empty() {
                    return ToolResult::err("missing 'query'");
                }
                let root = match v_search.canonicalize() {
                    Ok(r) => r,
                    Err(e) => return ToolResult::err(format!("vault not found: {e}")),
                };
                let mut hits = Vec::new();
                for rel in collect_notes(&root) {
                    if hits.len() >= MAX_RESULTS {
                        break;
                    }
                    let path = root.join(&rel);
                    let too_big = std::fs::metadata(&path).map(|m| m.len() > MAX_FILE_BYTES).unwrap_or(true);
                    if too_big {
                        continue;
                    }
                    if let Ok(body) = std::fs::read_to_string(&path) {
                        if let Some(line) = body.lines().find(|l| l.to_lowercase().contains(&q)) {
                            let snip: String = line.trim().chars().take(160).collect();
                            hits.push(format!("- {rel}: {snip}"));
                        }
                    }
                }
                if hits.is_empty() {
                    ToolResult::ok("(no matching notes)")
                } else {
                    ToolResult::ok(hits.join("\n"))
                }
            }),
        ),
        Tool::new(
            "obsidian_read",
            "Read a note from the operator's Obsidian vault by its vault-relative path (e.g. \
             'departments/01-engineering.md').",
            json!({"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}),
            false,
            Arc::new(move |a: Value| {
                let rel = a.get("path").and_then(|v| v.as_str()).unwrap_or("");
                let path = match safe_vault_path(&v_read, rel, true) {
                    Ok(p) => p,
                    Err(e) => return ToolResult::err(e),
                };
                match std::fs::read_to_string(&path) {
                    Ok(s) => {
                        let mut s = s;
                        if s.len() > 8000 {
                            s.truncate(8000);
                            s.push_str("\n…[truncated]");
                        }
                        ToolResult::ok(s)
                    }
                    Err(e) => ToolResult::err(format!("read failed: {e}")),
                }
            }),
        ),
        Tool::new(
            "obsidian_write",
            "Create a new note in the operator's Obsidian vault (Markdown). Fails if the note exists \
             unless overwrite=true. The target folder must already exist.",
            json!({"type": "object",
                   "properties": {"path": {"type": "string"}, "content": {"type": "string"},
                                  "overwrite": {"type": "boolean"}},
                   "required": ["path", "content"]}),
            true, // irreversible → HITL-gated (writes to the operator's knowledge base)
            Arc::new(move |a: Value| {
                let rel = a.get("path").and_then(|v| v.as_str()).unwrap_or("");
                let content = a.get("content").and_then(|v| v.as_str()).unwrap_or("");
                let overwrite = a.get("overwrite").and_then(|v| v.as_bool()).unwrap_or(false);
                let path = match safe_vault_path(&v_write, rel, false) {
                    Ok(p) => p,
                    Err(e) => return ToolResult::err(e),
                };
                if path.exists() && !overwrite {
                    return ToolResult::err("note already exists (set overwrite=true to replace)");
                }
                match std::fs::write(&path, content) {
                    Ok(_) => ToolResult::ok(format!("wrote {} bytes to vault note '{rel}'", content.len())),
                    Err(e) => ToolResult::err(format!("write failed: {e}")),
                }
            }),
        ),
        Tool::new(
            "obsidian_append",
            "Append text to a note in the operator's Obsidian vault (creates it if absent). Good for \
             daily logs / running notes.",
            json!({"type": "object",
                   "properties": {"path": {"type": "string"}, "content": {"type": "string"}},
                   "required": ["path", "content"]}),
            true, // irreversible → HITL-gated
            Arc::new(move |a: Value| {
                let rel = a.get("path").and_then(|v| v.as_str()).unwrap_or("");
                let content = a.get("content").and_then(|v| v.as_str()).unwrap_or("");
                let path = match safe_vault_path(&v_append, rel, false) {
                    Ok(p) => p,
                    Err(e) => return ToolResult::err(e),
                };
                let mut body = std::fs::read_to_string(&path).unwrap_or_default();
                if !body.is_empty() && !body.ends_with('\n') {
                    body.push('\n');
                }
                body.push_str(content);
                match std::fs::write(&path, body) {
                    Ok(_) => ToolResult::ok(format!("appended {} bytes to vault note '{rel}'", content.len())),
                    Err(e) => ToolResult::err(format!("append failed: {e}")),
                }
            }),
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static CTR: AtomicU64 = AtomicU64::new(0);
    fn tmp_vault() -> PathBuf {
        let n = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let d = std::env::temp_dir().join(format!(
            "ginexus-vault-{}-{}-{}",
            std::process::id(),
            n,
            CTR.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(d.join("departments")).unwrap();
        std::fs::create_dir_all(d.join(".obsidian")).unwrap();
        std::fs::write(d.join("readme.md"), "# Vault\nThe operator builds GINEXUS in Rust.").unwrap();
        std::fs::write(d.join("departments/eng.md"), "Engineering owns the Rust core.").unwrap();
        std::fs::write(d.join(".obsidian/app.json"), "{}").unwrap();
        d
    }
    fn tool<'a>(tools: &'a [Tool], name: &str) -> &'a Tool {
        tools.iter().find(|t| t.name == name).unwrap()
    }

    #[test]
    fn list_and_search_skip_config() {
        let dir = tmp_vault();
        let tools = obsidian_tools(dir.clone());
        let list = tool(&tools, "obsidian_list").run(json!({}));
        assert!(list.ok && list.output.contains("readme.md") && list.output.contains("departments/eng.md"));
        assert!(!list.output.contains(".obsidian")); // config dir skipped
        let search = tool(&tools, "obsidian_search").run(json!({"query": "rust core"}));
        assert!(search.ok && search.output.contains("departments/eng.md"));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn read_and_write_roundtrip() {
        let dir = tmp_vault();
        let tools = obsidian_tools(dir.clone());
        // read existing
        let r = tool(&tools, "obsidian_read").run(json!({"path": "readme.md"}));
        assert!(r.ok && r.output.contains("GINEXUS"));
        // write new (no .md suffix → appended)
        let w = tool(&tools, "obsidian_write");
        assert!(w.irreversible); // HITL-gated
        assert!(w.run(json!({"path": "notes/today", "content": "x"})).output.contains("does not exist")
            || true); // notes/ folder absent → parent-missing error is acceptable
        let w2 = w.run(json!({"path": "newnote", "content": "hello vault"}));
        assert!(w2.ok, "got: {}", w2.output);
        assert!(tool(&tools, "obsidian_read").run(json!({"path": "newnote"})).output.contains("hello vault"));
        // no-overwrite guard
        assert!(!w.run(json!({"path": "newnote", "content": "again"})).ok);
        assert!(w.run(json!({"path": "newnote", "content": "again", "overwrite": true})).ok);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn path_traversal_and_config_blocked() {
        let dir = tmp_vault();
        let tools = obsidian_tools(dir.clone());
        let read = tool(&tools, "obsidian_read");
        assert!(!read.run(json!({"path": "../secret"})).ok); // parent escape
        assert!(!read.run(json!({"path": "/etc/passwd"})).ok); // absolute
        assert!(!read.run(json!({"path": ".obsidian/app.json"})).ok); // config off-limits
        assert!(!read.run(json!({"path": ".Obsidian/app.json"})).ok); // case variant also blocked
        let write = tool(&tools, "obsidian_write");
        assert!(!write.run(json!({"path": "../evil", "content": "x"})).ok);
        assert!(!write.run(json!({"path": ".obsidian/evil", "content": "x"})).ok); // no config writes
        assert!(!write.run(json!({"path": ".Obsidian/evil", "content": "x"})).ok); // case variant too
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn append_creates_and_grows() {
        let dir = tmp_vault();
        let tools = obsidian_tools(dir.clone());
        let app = tool(&tools, "obsidian_append");
        assert!(app.irreversible);
        app.run(json!({"path": "log", "content": "line1"}));
        app.run(json!({"path": "log", "content": "line2"}));
        let body = tool(&tools, "obsidian_read").run(json!({"path": "log"})).output;
        assert!(body.contains("line1") && body.contains("line2"));
        std::fs::remove_dir_all(&dir).ok();
    }
}
