//! Personal-data export ingestion (SP3 ingestion tail).
//!
//! Parses sanitized chat exports (ChatGPT / Claude / a generic role+text shape) and loads the
//! user's own messages into ARCHIVAL memory tagged `Origin::Untrusted` — the injection-into-memory
//! defense: imported text is surfaced as DATA via `recall`, never as instructions.
//!
//! Canonical PII sanitization is the operator's external `ai-export-sanitizer` (run FIRST). This
//! module adds a light defense-in-depth scrub for obvious secrets and caps volume; it does NOT
//! replace the sanitizer.

use crate::{MemoryStore, Origin};
use ginexus_agent::{Tool, ToolResult};
use serde_json::{json, Value};
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportSource {
    ChatGPT,
    Claude,
    Generic,
}

impl ExportSource {
    pub fn label(&self) -> &'static str {
        match self {
            ExportSource::ChatGPT => "chatgpt",
            ExportSource::Claude => "claude",
            ExportSource::Generic => "export",
        }
    }
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct IngestReport {
    pub source: String,
    pub conversations: usize,
    pub facts_loaded: usize,
    pub skipped: usize,
}

/// Skip pastes larger than this (code dumps, transcripts) — they pollute keyword recall.
const MAX_FACT_CHARS: usize = 2000;
/// Hard safety cap per import so a huge export can't unbounded-grow archival memory.
const MAX_FACTS: usize = 5000;

/// Best-effort format detection from the parsed JSON root.
pub fn detect_source(root: &Value) -> ExportSource {
    let first = root.as_array().and_then(|a| a.first());
    if let Some(obj) = first {
        if obj.get("mapping").is_some() {
            return ExportSource::ChatGPT;
        }
        if obj.get("chat_messages").is_some() {
            return ExportSource::Claude;
        }
    }
    ExportSource::Generic
}

/// Normalize + cap + sanitize one message and COLLECT it into `out` (does not write yet). The
/// canonical Rust sanitizer (when provided) scrubs PII/secrets HERE — only the messages we keep are
/// processed (small strings → fast + no catastrophic backtracking, unlike sanitizing the whole
/// multi-MB export upfront). One shared Sanitizer per import → consistent placeholders. Collected
/// facts are written in one batched pass (embeddings + file) at the end of the import — see
/// `ingest_value` — instead of one embed round-trip + file open per message.
fn prep_fact(
    report: &mut IngestReport, source_label: &str, role: &str, raw: &str,
    san: Option<&ginexus_sanitize::Sanitizer>, out: &mut Vec<String>,
) {
    let text = raw.trim();
    if text.is_empty() || out.len() >= MAX_FACTS {
        report.skipped += 1;
        return;
    }
    if text.chars().count() > MAX_FACT_CHARS {
        report.skipped += 1;
        return;
    }
    let who = if role == "assistant" { "assistant" } else { "you" };
    let clean = match san {
        Some(s) => s.sanitize_text(text),
        None => text.to_string(),
    };
    out.push(format!("[{source_label} · {who}] {clean}"));
}

/// Join ChatGPT `content.parts` (strings) into one text blob.
fn chatgpt_parts(message: &Value) -> String {
    message
        .get("content")
        .and_then(|c| c.get("parts"))
        .and_then(|p| p.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|p| p.as_str())
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

/// Ingest a parsed export. `include_assistant=false` keeps only the user's own words (the
/// strongest "about me" signal); true also loads assistant replies. Always Origin::Untrusted.
pub fn ingest_value(store: &MemoryStore, root: &Value, include_assistant: bool, sanitize: bool) -> IngestReport {
    let source = detect_source(root);
    let label = source.label();
    let mut report = IngestReport { source: label.to_string(), ..Default::default() };
    // One shared sanitizer for the whole import → consistent placeholders, scrub only kept messages.
    let san = if sanitize { Some(ginexus_sanitize::Sanitizer::new()) } else { None };
    // Collect kept facts, then write them all in one batched embed + file pass (see `append_facts`).
    let mut facts: Vec<String> = Vec::new();
    let convs = match root.as_array() {
        Some(a) => a,
        None => return report,
    };

    for conv in convs {
        report.conversations += 1;
        match source {
            ExportSource::ChatGPT => {
                // mapping: { node_id: { message: { author.role, content.parts } } }
                if let Some(map) = conv.get("mapping").and_then(|m| m.as_object()) {
                    for node in map.values() {
                        let msg = match node.get("message") {
                            Some(m) if !m.is_null() => m,
                            _ => continue,
                        };
                        let role = msg
                            .get("author")
                            .and_then(|a| a.get("role"))
                            .and_then(|r| r.as_str())
                            .unwrap_or("");
                        if role != "user" && !(include_assistant && role == "assistant") {
                            continue;
                        }
                        let text = chatgpt_parts(msg);
                        prep_fact(&mut report, label, role, &text, san.as_ref(), &mut facts);
                    }
                }
            }
            ExportSource::Claude => {
                // chat_messages: [ { sender: "human"|"assistant", text } ]
                if let Some(msgs) = conv.get("chat_messages").and_then(|m| m.as_array()) {
                    for m in msgs {
                        let sender = m.get("sender").and_then(|s| s.as_str()).unwrap_or("");
                        let role = if sender == "human" { "user" } else { sender };
                        if role != "user" && !(include_assistant && role == "assistant") {
                            continue;
                        }
                        let text = m.get("text").and_then(|t| t.as_str()).unwrap_or("");
                        prep_fact(&mut report, label, role, text, san.as_ref(), &mut facts);
                    }
                }
            }
            ExportSource::Generic => {
                // a flat array of { role|sender, content|text } messages, OR a conversation with
                // a "messages" array of the same.
                let msgs: Vec<&Value> = if conv.get("messages").is_some() {
                    conv.get("messages").and_then(|m| m.as_array()).map(|a| a.iter().collect()).unwrap_or_default()
                } else {
                    vec![conv]
                };
                for m in msgs {
                    let role = m
                        .get("role")
                        .or_else(|| m.get("sender"))
                        .and_then(|r| r.as_str())
                        .unwrap_or("");
                    let role = if role == "human" { "user" } else { role };
                    if role != "user" && !(include_assistant && role == "assistant") {
                        continue;
                    }
                    let text = m
                        .get("content")
                        .or_else(|| m.get("text"))
                        .and_then(|t| t.as_str())
                        .unwrap_or("");
                    prep_fact(&mut report, label, role, text, san.as_ref(), &mut facts);
                }
            }
        }
    }
    // Single batched write: one (chunked) embedding pass + one file append for the whole import.
    report.facts_loaded = facts.len();
    store.append_facts(facts, Origin::Untrusted);
    report
}

/// Parse a JSON export string and ingest it. `sanitize` runs the canonical PII/secret scrub on each
/// kept message before it enters memory (the required pre-step; pass false only for clean input).
pub fn ingest_str(
    store: &MemoryStore, json: &str, include_assistant: bool, sanitize: bool,
) -> Result<IngestReport, String> {
    let root: Value = serde_json::from_str(json).map_err(|e| format!("bad export JSON: {e}"))?;
    Ok(ingest_value(store, &root, include_assistant, sanitize))
}

/// HITL-gated agent tool: "import my ChatGPT export at <path>". Bulk import of personal data is
/// irreversible-ish (grows quarantined memory), so it requires approval. Reads a file the core
/// can access — stage the export outside TCC-protected dirs, or use `POST /v1/ingest` with inline
/// `data` (the signed app reads the file under its own TCC and posts the bytes).
pub fn ingest_tool(store: Arc<MemoryStore>) -> Tool {
    Tool::new(
        "ingest_export",
        "Import a SANITIZED personal-data export (ChatGPT/Claude/generic chat JSON) from `path` \
         into long-term memory as quarantined (untrusted) data. Run the operator's sanitizer FIRST. \
         Set include_assistant=true to also import assistant replies (default: your messages only).",
        json!({"type": "object",
               "properties": {"path": {"type": "string"}, "include_assistant": {"type": "boolean"}},
               "required": ["path"]}),
        true, // HITL-gated
        Arc::new(move |a| {
            let path = a.get("path").and_then(|v| v.as_str()).unwrap_or("").trim();
            if path.is_empty() {
                return ToolResult::err("missing 'path'");
            }
            let include = a.get("include_assistant").and_then(|v| v.as_bool()).unwrap_or(false);
            let json = match std::fs::read_to_string(path) {
                Ok(s) => s,
                Err(e) => return ToolResult::err(format!("read {path}: {e}")),
            };
            match ingest_str(&store, &json, include, true) {
                Ok(r) => ToolResult::ok(format!(
                    "imported {} facts from {} export ({} conversations, {} skipped)",
                    r.facts_loaded, r.source, r.conversations, r.skipped
                )),
                Err(e) => ToolResult::err(e),
            }
        }),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static CTR: AtomicU64 = AtomicU64::new(0);
    fn tmp() -> PathBuf {
        let n = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let d = std::env::temp_dir().join(format!(
            "ginexus-ingest-{}-{}-{}",
            std::process::id(),
            n,
            CTR.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn chatgpt_export_user_only_quarantined() {
        let dir = tmp();
        let store = MemoryStore::open(dir.clone());
        let export = r#"[
          {"title":"t","mapping":{
            "n1":{"message":{"author":{"role":"user"},"content":{"content_type":"text","parts":["I live in Okinawa and prefer dark mode"]}}},
            "n2":{"message":{"author":{"role":"assistant"},"content":{"content_type":"text","parts":["Noted."]}}}
          }}
        ]"#;
        let rep = ingest_str(&store, export, false, false).unwrap();
        assert_eq!(rep.source, "chatgpt");
        assert_eq!(rep.facts_loaded, 1); // user only
        let hits = store.search("Okinawa dark mode", 5);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].origin, Origin::Untrusted); // imported = quarantined
        assert!(hits[0].text.contains("[chatgpt · you]"));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn claude_export_include_assistant() {
        let dir = tmp();
        let store = MemoryStore::open(dir.clone());
        let export = r#"[
          {"name":"c","chat_messages":[
            {"sender":"human","text":"My flagship project is GINEXUS"},
            {"sender":"assistant","text":"Great, tell me more"}
          ]}
        ]"#;
        let rep = ingest_str(&store, export, true, false).unwrap();
        assert_eq!(rep.source, "claude");
        assert_eq!(rep.facts_loaded, 2);
        assert!(store.search("flagship GINEXUS", 5)[0].text.contains("[claude · you]"));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn generic_messages_and_secret_scrub() {
        let dir = tmp();
        let store = MemoryStore::open(dir.clone());
        let export = r#"[
          {"messages":[
            {"role":"user","content":"contact me at dreb@example.com or key sk-ant-abcdefghijklmnopqrstuvwxyz0123"},
            {"role":"assistant","content":"ok"}
          ]}
        ]"#;
        let rep = ingest_str(&store, export, false, true).unwrap(); // sanitize on
        assert_eq!(rep.facts_loaded, 1);
        let hit = &store.search("contact me", 5)[0];
        assert!(hit.text.contains("[EMAIL_1]"));
        assert!(hit.text.contains("[API_KEY_1]"));
        assert!(!hit.text.contains("example.com") && !hit.text.contains("sk-ant-"));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn empty_and_oversize_are_skipped() {
        let dir = tmp();
        let store = MemoryStore::open(dir.clone());
        let big = "x".repeat(MAX_FACT_CHARS + 1);
        let export = format!(
            r#"[{{"messages":[{{"role":"user","content":""}},{{"role":"user","content":"{big}"}}]}}]"#
        );
        let rep = ingest_str(&store, &export, false, false).unwrap();
        assert_eq!(rep.facts_loaded, 0);
        assert_eq!(rep.skipped, 2);
        std::fs::remove_dir_all(&dir).ok();
    }
}
