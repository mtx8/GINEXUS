//! Deterministic, no-LLM context compaction (Tier-1 pruning).
//!
//! Adapted from Hermes Agent's `context_compressor.py` deterministic tier. Keeps a conversation
//! within a local model's (small) context window WITHOUT spending a summarization model call:
//!
//! 1. **Dedup** identical tool results — keep the most recent verbatim, elide the earlier copies.
//! 2. **Truncate** oversized tool-call arguments *inside the parsed JSON*, so the payload stays
//!    valid and the model still sees the call shape.
//! 3. **Digest** stale tool results (all but the most recent N) down to a one-line summary.
//! 4. **Tail-cut** by token budget as a last resort — drop the oldest turns, but NEVER orphan a
//!    `tool` result from the assistant `tool_calls` that produced it, and always keep `system`
//!    messages.
//!
//! Why this matters more for GiNexus than for a cloud agent: local Ollama/MLX models run 8K–32K
//! windows, so a long agentic turn overflows fast. This runs every iteration before the model call;
//! below threshold it is a cheap no-op (it only walks the message vector).

use serde_json::{json, Value};
use std::collections::HashMap;

/// Rough token estimate: ~4 characters per token (an English heuristic). The core has no tokenizer;
/// this is only used to compare against budget THRESHOLDS, never billed. Slightly over-estimating is
/// safe — compaction triggers a touch early rather than too late.
pub fn estimate_tokens(s: &str) -> usize {
    (s.chars().count() + 3) / 4
}

/// Estimated tokens of a single chat message: content + every tool-call's name and arguments, plus a
/// small fixed structural overhead (role/JSON framing).
fn msg_tokens(m: &Value) -> usize {
    let mut t = 4; // structural overhead per message
    if let Some(c) = m.get("content").and_then(Value::as_str) {
        t += estimate_tokens(c);
    }
    if let Some(tcs) = m.get("tool_calls").and_then(Value::as_array) {
        for tc in tcs {
            if let Some(f) = tc.get("function") {
                if let Some(n) = f.get("name").and_then(Value::as_str) {
                    t += estimate_tokens(n);
                }
                if let Some(a) = f.get("arguments").and_then(Value::as_str) {
                    t += estimate_tokens(a);
                }
            }
        }
    }
    t
}

/// Estimated tokens of a whole message list.
pub fn estimate_messages_tokens(msgs: &[Value]) -> usize {
    msgs.iter().map(msg_tokens).sum()
}

/// Tuning for [`compact`]. Build with [`CompactionConfig::from_env`] in production.
#[derive(Clone, Copy, Debug)]
pub struct CompactionConfig {
    /// The model's full context window, in tokens.
    pub context_window: usize,
    /// Tokens reserved for the model's output (subtracted before computing the input budget).
    pub max_output: usize,
    /// The most-recent tool results kept verbatim (never digested).
    pub keep_recent_results: usize,
    /// Maximum length (chars) of a single string leaf inside a tool-call's arguments before it is
    /// truncated.
    pub arg_truncate_chars: usize,
}

impl Default for CompactionConfig {
    fn default() -> Self {
        Self {
            context_window: 32_768,
            max_output: 4_096,
            keep_recent_results: 3,
            arg_truncate_chars: 2_000,
        }
    }
}

impl CompactionConfig {
    /// Read overrides from the environment, falling back to [`Default`]:
    /// `GINEXUS_CTX_WINDOW`, `GINEXUS_MAX_OUTPUT`, `GINEXUS_KEEP_RESULTS`, `GINEXUS_ARG_TRUNCATE`.
    pub fn from_env() -> Self {
        let d = Self::default();
        let get = |k: &str, fallback: usize| {
            std::env::var(k).ok().and_then(|v| v.parse::<usize>().ok()).filter(|&n| n > 0).unwrap_or(fallback)
        };
        Self {
            context_window: get("GINEXUS_CTX_WINDOW", d.context_window),
            max_output: get("GINEXUS_MAX_OUTPUT", d.max_output),
            keep_recent_results: std::env::var("GINEXUS_KEEP_RESULTS")
                .ok()
                .and_then(|v| v.parse::<usize>().ok())
                .unwrap_or(d.keep_recent_results),
            arg_truncate_chars: get("GINEXUS_ARG_TRUNCATE", d.arg_truncate_chars),
        }
    }

    /// The effective INPUT token budget: reserve output room first, then take a fraction of what is
    /// left. Mirrors Hermes: 50% normally, but 85% for tiny windows (where 50% would be too tight to
    /// leave the agent any working room). Never below a 256-token floor.
    pub fn threshold_tokens(&self) -> usize {
        let avail = self.context_window.saturating_sub(self.max_output);
        let ratio = if avail < 8_192 { 0.85 } else { 0.50 };
        // 256-token floor for comfort, but never claim more budget than the window actually has — a
        // tiny/misconfigured window must still trigger compaction rather than treat 256 tokens as free.
        ((avail as f64 * ratio) as usize).max(256).min(avail.max(1))
    }
}

/// What [`compact`] did, for telemetry / the UI context meter.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CompactionStats {
    pub before_tokens: usize,
    pub after_tokens: usize,
    pub deduped: usize,
    pub digested: usize,
    pub args_truncated: usize,
    pub dropped: usize,
}

impl CompactionStats {
    /// True if compaction mutated the message list in any way.
    pub fn changed(&self) -> bool {
        self.deduped + self.digested + self.args_truncated + self.dropped > 0
    }
}

// ================================== implementation ==================================

/// Minimum content length (chars) below which a tool result is too small to be worth eliding or
/// digesting — leaving it avoids churn and keeps tiny status outputs intact.
const MIN_SHRINKABLE: usize = 120;

/// Compact `msgs` in place to fit within the config's input budget, returning what changed. No-op
/// (and cheap) when already under threshold. Steps escalate from cheapest/least-lossy (dedup) to
/// last-resort (tail-cut), short-circuiting as soon as the list fits.
pub fn compact(msgs: &mut Vec<Value>, cfg: &CompactionConfig) -> CompactionStats {
    let before = estimate_messages_tokens(msgs);
    let mut stats = CompactionStats { before_tokens: before, after_tokens: before, ..Default::default() };
    let threshold = cfg.threshold_tokens();
    if before <= threshold {
        return stats; // already fits — cheap no-op
    }

    stats.deduped = dedup_tool_results(msgs);
    if estimate_messages_tokens(msgs) > threshold {
        stats.args_truncated = truncate_tool_args(msgs, cfg.arg_truncate_chars);
    }
    if estimate_messages_tokens(msgs) > threshold {
        stats.digested = digest_stale_results(msgs, cfg.keep_recent_results);
    }
    if estimate_messages_tokens(msgs) > threshold {
        stats.dropped = tail_cut(msgs, threshold);
    }

    stats.after_tokens = estimate_messages_tokens(msgs);
    stats
}

/// Elide earlier copies of an identical (large) tool result, keeping the most-recent one verbatim.
/// Common when the model re-reads the same file or re-runs the same command.
fn dedup_tool_results(msgs: &mut [Value]) -> usize {
    let tool_idxs: Vec<(usize, String)> = msgs
        .iter()
        .enumerate()
        .filter(|(_, m)| m["role"] == "tool")
        .filter_map(|(i, m)| m["content"].as_str().map(|c| (i, c.to_string())))
        .filter(|(_, c)| c.len() >= MIN_SHRINKABLE)
        .collect();

    // Last index at which each distinct content appears.
    let mut last: HashMap<&str, usize> = HashMap::new();
    for (i, c) in &tool_idxs {
        last.insert(c.as_str(), *i);
    }

    let mut n = 0;
    for (i, c) in &tool_idxs {
        if last.get(c.as_str()) != Some(i) {
            msgs[*i]["content"] = json!("[identical earlier tool result elided to save context]");
            n += 1;
        }
    }
    n
}

/// Recursively truncate any string leaf longer than `cap` inside a JSON value, marking how much was
/// removed. Returns whether anything was truncated.
fn truncate_value(v: &mut Value, cap: usize) -> bool {
    match v {
        Value::String(s) if s.chars().count() > cap => {
            let kept: String = s.chars().take(cap).collect();
            let elided = s.chars().count() - cap;
            *s = format!("{kept}… [truncated {elided} chars]");
            true
        }
        Value::Array(a) => a.iter_mut().fold(false, |acc, x| truncate_value(x, cap) || acc),
        Value::Object(o) => o.values_mut().fold(false, |acc, x| truncate_value(x, cap) || acc),
        _ => false,
    }
}

/// Truncate oversized string fields inside each tool-call's `arguments` (a JSON-encoded string),
/// keeping the JSON valid so the model still sees the call's shape. Returns how many calls changed.
///
/// The LAST assistant `tool_calls` message is left intact: on an approval resume it holds the
/// PENDING tool call whose args the user is about to approve byte-for-byte — truncating it would make
/// the model re-emit mismatched args and the approved action would silently never execute.
fn truncate_tool_args(msgs: &mut [Value], cap: usize) -> usize {
    let pending_idx = msgs
        .iter()
        .rposition(|m| m["role"] == "assistant" && m["tool_calls"].as_array().is_some_and(|a| !a.is_empty()));
    let mut n = 0;
    for (i, m) in msgs.iter_mut().enumerate() {
        if m["role"] != "assistant" || Some(i) == pending_idx {
            continue;
        }
        let Some(tcs) = m.get_mut("tool_calls").and_then(Value::as_array_mut) else { continue };
        for tc in tcs {
            let Some(args_str) = tc["function"]["arguments"].as_str() else { continue };
            if args_str.chars().count() <= cap {
                continue;
            }
            match serde_json::from_str::<Value>(args_str) {
                Ok(mut parsed) => {
                    if truncate_value(&mut parsed, cap) {
                        tc["function"]["arguments"] = json!(parsed.to_string());
                        n += 1;
                    }
                }
                Err(_) => {
                    // Not parseable JSON — hard-truncate the raw string (still a valid string value).
                    let kept: String = args_str.chars().take(cap).collect();
                    let elided = args_str.chars().count() - cap;
                    tc["function"]["arguments"] = json!(format!("{kept}… [truncated {elided} chars]"));
                    n += 1;
                }
            }
        }
    }
    n
}

/// Replace stale tool results (all but the most-recent `keep_recent`) with a one-line digest:
/// the first line as a hint plus an elision note. Preserves `role`/`tool_call_id` so pairing holds.
fn digest_stale_results(msgs: &mut [Value], keep_recent: usize) -> usize {
    let tool_idxs: Vec<usize> = msgs
        .iter()
        .enumerate()
        .filter(|(_, m)| m["role"] == "tool")
        .map(|(i, _)| i)
        .collect();

    if tool_idxs.len() <= keep_recent {
        return 0;
    }
    let stale = &tool_idxs[..tool_idxs.len() - keep_recent];

    let mut n = 0;
    for &i in stale {
        let Some(content) = msgs[i]["content"].as_str() else { continue };
        if content.chars().count() < MIN_SHRINKABLE {
            continue; // already small (or an elision marker)
        }
        let lines = content.lines().count().max(1);
        let chars = content.chars().count();
        let first: String = content.lines().next().unwrap_or("").chars().take(80).collect();
        msgs[i]["content"] = json!(format!("{first} … [{lines} lines, {chars} chars elided]"));
        n += 1;
    }
    n
}

/// Last resort: drop the oldest non-system messages until the list fits `threshold`. Always keeps
/// every `system` message AND the most-recent `user` message (the active request — otherwise a long
/// agentic turn would discard the instruction while keeping low-value tool output). Never starts the
/// retained window on an orphan `tool` result — if the cut would land mid tool_call/result pair, it
/// extends backward to include the owning assistant. Orphan-safety relies on the loop's invariant
/// that an assistant's tool results are appended immediately after it (assistant precedes its tools).
fn tail_cut(msgs: &mut Vec<Value>, threshold: usize) -> usize {
    let n = msgs.len();
    let sys: Vec<usize> = (0..n).filter(|&i| msgs[i]["role"] == "system").collect();
    let nonsys: Vec<usize> = (0..n).filter(|&i| msgs[i]["role"] != "system").collect();
    if nonsys.is_empty() {
        return 0;
    }
    // Pin the latest user message so the request itself is never the casualty of a tail-cut.
    let pinned_user: Option<usize> = (0..n).rev().find(|&i| msgs[i]["role"] == "user");

    let pinned_tokens: usize = sys.iter().map(|&i| msg_tokens(&msgs[i])).sum::<usize>()
        + pinned_user.filter(|u| !sys.contains(u)).map_or(0, |u| msg_tokens(&msgs[u]));
    let budget = threshold.saturating_sub(pinned_tokens);

    // Walk the non-system messages from the end, keeping a suffix that fits the budget. Always keep
    // at least the most recent non-system message.
    let mut acc = 0usize;
    let mut start = nonsys.len() - 1;
    for k in (0..nonsys.len()).rev() {
        let t = msg_tokens(&msgs[nonsys[k]]);
        if k != nonsys.len() - 1 && acc + t > budget {
            break;
        }
        acc += t;
        start = k;
    }

    // Don't begin the retained window on an orphan tool result — extend backward to its assistant.
    while start > 0 && msgs[nonsys[start]]["role"] == "tool" {
        start -= 1;
    }

    let keep: std::collections::HashSet<usize> = sys
        .into_iter()
        .chain(pinned_user)
        .chain(nonsys[start..].iter().copied())
        .collect();
    let dropped = n - keep.len();
    if dropped == 0 {
        return 0;
    }

    let mut idx = 0usize;
    msgs.retain(|_| {
        let k = keep.contains(&idx);
        idx += 1;
        k
    });
    dropped
}

#[cfg(test)]
mod tests {
    use super::*;

    // ---- helpers ----
    fn user(s: &str) -> Value {
        json!({"role": "user", "content": s})
    }
    fn system(s: &str) -> Value {
        json!({"role": "system", "content": s})
    }
    /// Assistant turn that calls `name` with raw JSON-string `args` under call id `id`.
    fn asst_call(id: &str, name: &str, args: &str) -> Value {
        json!({"role": "assistant", "content": "",
               "tool_calls": [{"id": id, "type": "function",
                               "function": {"name": name, "arguments": args}}]})
    }
    fn tool_result(id: &str, content: &str) -> Value {
        json!({"role": "tool", "tool_call_id": id, "content": content})
    }
    /// A small window that forces compaction for modest message sets (avail 150 → 85% → ~127 tok).
    fn tight() -> CompactionConfig {
        CompactionConfig { context_window: 200, max_output: 50, keep_recent_results: 1, arg_truncate_chars: 80 }
    }
    fn big_text(n: usize) -> String {
        "x".repeat(n)
    }
    /// Every `tool` message has a preceding assistant `tool_calls` carrying its id (no orphans).
    fn no_orphan_tool_results(msgs: &[Value]) -> bool {
        for (i, m) in msgs.iter().enumerate() {
            if m["role"] == "tool" {
                let id = m["tool_call_id"].as_str().unwrap_or("");
                let paired = msgs[..i].iter().any(|p| {
                    p["role"] == "assistant"
                        && p["tool_calls"].as_array().map_or(false, |tcs| {
                            tcs.iter().any(|tc| tc["id"].as_str() == Some(id))
                        })
                });
                if !paired {
                    return false;
                }
            }
        }
        true
    }

    #[test]
    fn estimate_tokens_is_roughly_quarter_of_chars() {
        assert_eq!(estimate_tokens(""), 0);
        assert_eq!(estimate_tokens("a"), 1);
        assert_eq!(estimate_tokens("abcd"), 1);
        assert_eq!(estimate_tokens("abcdefgh"), 2);
    }

    #[test]
    fn threshold_uses_half_for_large_windows_and_more_for_tiny() {
        let large = CompactionConfig { context_window: 32_768, max_output: 4_096, ..Default::default() };
        // avail 28672 * 0.5 = 14336
        assert_eq!(large.threshold_tokens(), 14_336);
        let tiny = CompactionConfig { context_window: 4_096, max_output: 1_024, ..Default::default() };
        // avail 3072 * 0.85 = 2611
        assert_eq!(tiny.threshold_tokens(), (3_072_f64 * 0.85) as usize);
    }

    #[test]
    fn under_threshold_is_a_noop() {
        let mut msgs = vec![system("be helpful"), user("hi"), asst_call("c1", "notes", "{}")];
        let before = msgs.clone();
        let cfg = CompactionConfig::default(); // huge budget
        let stats = compact(&mut msgs, &cfg);
        assert!(!stats.changed(), "should not change a small conversation");
        assert_eq!(msgs, before, "messages must be untouched below threshold");
    }

    // Each pruning STEP is unit-tested directly (deterministic, independent of the budget cascade);
    // the whole-cascade behaviour is covered by the `compact(...)` integration tests below.

    #[test]
    fn dedup_helper_elides_earlier_identical_results() {
        let dup = big_text(400);
        let mut msgs = vec![
            asst_call("a", "read", "{}"),
            tool_result("a", &dup),
            asst_call("b", "read", "{}"),
            tool_result("b", &dup),
        ];
        let n = dedup_tool_results(&mut msgs);
        assert_eq!(n, 1, "exactly one earlier duplicate elided");
        assert_ne!(msgs[1]["content"].as_str().unwrap(), dup, "earlier copy elided");
        assert_eq!(msgs[3]["content"].as_str().unwrap(), dup, "latest copy kept verbatim");
    }

    #[test]
    fn digest_helper_keeps_recent_and_formats_a_hint() {
        let r1 = format!("FIRST\n{}", big_text(400));
        let r2 = format!("SECOND\n{}", big_text(400));
        let r3 = format!("THIRD\n{}", big_text(400));
        let mut msgs = vec![tool_result("a", &r1), tool_result("b", &r2), tool_result("c", &r3)];
        let n = digest_stale_results(&mut msgs, 1); // keep the most recent 1 verbatim
        assert_eq!(n, 2, "all but the most recent digested");
        assert_eq!(msgs[2]["content"].as_str().unwrap(), r3, "newest result kept verbatim");
        let d = msgs[0]["content"].as_str().unwrap();
        assert!(d.contains("FIRST"), "digest keeps the first line as a hint");
        assert!(d.contains("chars elided"), "digest notes the elision");
        assert!(d.len() < r1.len(), "older result shrunk");
    }

    #[test]
    fn truncate_helper_shrinks_leaves_keeps_json_and_skips_pending() {
        let huge = big_text(500);
        let early = format!(r#"{{"path":"/x","body":"{}"}}"#, huge);
        let pending = format!(r#"{{"path":"/y","body":"{}"}}"#, huge);
        let mut msgs = vec![
            asst_call("a", "write_document", &early),
            tool_result("a", "ok"),
            asst_call("b", "write_document", &pending), // last assistant tool_calls = the pending one
        ];
        let n = truncate_tool_args(&mut msgs, 80);
        assert_eq!(n, 1, "only the non-pending call is truncated");
        let a = msgs[0]["tool_calls"][0]["function"]["arguments"].as_str().unwrap();
        let parsed: Value = serde_json::from_str(a).expect("arguments must stay valid JSON");
        assert_eq!(parsed["path"], "/x", "small fields preserved");
        assert!(parsed["body"].as_str().unwrap().len() < huge.len(), "huge field truncated");
        let b = msgs[2]["tool_calls"][0]["function"]["arguments"].as_str().unwrap();
        assert_eq!(b, pending, "the pending (last) tool call is left intact");
    }

    #[test]
    fn tail_cut_drops_oldest_keeps_system_and_never_orphans() {
        let mut msgs = vec![system("SYSTEM PROMPT")];
        // 8 distinct large turns — distinct content so dedup can't help; digest+truncate won't be
        // enough, forcing the tail-cut path.
        for i in 0..8 {
            let id = format!("c{i}");
            msgs.push(user(&format!("turn {i} {}", big_text(120))));
            msgs.push(asst_call(&id, "read", "{}"));
            msgs.push(tool_result(&id, &format!("UNIQUE{i}\n{}", big_text(300))));
        }
        let n_before = msgs.len();
        let stats = compact(&mut msgs, &tight());
        assert!(stats.dropped > 0, "tail-cut should drop oldest turns");
        assert!(msgs.len() < n_before);
        // System prompt survives.
        assert!(msgs.iter().any(|m| m["role"] == "system" && m["content"] == "SYSTEM PROMPT"));
        // The newest turn survives.
        assert!(msgs.iter().any(|m| m["content"].as_str().map_or(false, |c| c.contains("turn 7"))));
        // No tool result left without its assistant call.
        assert!(no_orphan_tool_results(&msgs));
        // Result fits the budget.
        assert!(estimate_messages_tokens(&msgs) <= tight().threshold_tokens());
    }

    #[test]
    fn tail_cut_preserves_the_user_request() {
        // The user's instruction is the OLDEST non-system message in a long agentic turn — it must
        // survive even when the budget forces dropping the early middle of the conversation.
        let mut msgs = vec![system("SYSTEM"), user("THE-ORIGINAL-REQUEST please do the thing")];
        for i in 0..10 {
            let id = format!("c{i}");
            msgs.push(asst_call(&id, "read", "{}"));
            msgs.push(tool_result(&id, &format!("UNIQUE{i}\n{}", big_text(400))));
        }
        let stats = compact(&mut msgs, &tight());
        assert!(stats.dropped > 0, "long turn should force a tail-cut");
        assert!(
            msgs.iter().any(|m| m["role"] == "user"
                && m["content"].as_str().map_or(false, |c| c.contains("THE-ORIGINAL-REQUEST"))),
            "the user's request must be pinned, not dropped"
        );
        assert!(no_orphan_tool_results(&msgs));
    }

    #[test]
    fn does_not_truncate_a_pending_tool_call_argument() {
        // On an approval resume, the pending tool call (last assistant tool_calls message) sits in the
        // transcript with its FULL args. Truncating it would make the model re-emit mismatched args and
        // the user-approved action would silently never run — so its args must be left intact.
        let pending_args = format!(r#"{{"path":"/x","body":"{}"}}"#, big_text(1200));
        let mut msgs = vec![user("write the big doc")];
        // Bulk earlier turns to push the transcript over budget so compaction engages.
        for i in 0..4 {
            let id = format!("c{i}");
            msgs.push(asst_call(&id, "read", "{}"));
            msgs.push(tool_result(&id, &format!("U{i}\n{}", big_text(400))));
        }
        msgs.push(asst_call("pending", "write_document", &pending_args)); // the pending call, last
        let before_args = pending_args.clone();
        let stats = compact(&mut msgs, &tight());
        assert!(stats.changed(), "transcript should have been compacted");
        let last_asst = msgs.iter().rev().find(|m| m["role"] == "assistant").unwrap();
        let got = last_asst["tool_calls"][0]["function"]["arguments"].as_str().unwrap();
        assert_eq!(got, before_args, "pending tool-call args must NOT be truncated");
    }

    #[test]
    fn compaction_is_monotonic_and_records_token_counts() {
        let mut msgs = vec![system("s")];
        for i in 0..6 {
            let id = format!("c{i}");
            msgs.push(asst_call(&id, "read", "{}"));
            msgs.push(tool_result(&id, &format!("U{i}\n{}", big_text(300))));
        }
        let stats = compact(&mut msgs, &tight());
        assert_eq!(stats.after_tokens, estimate_messages_tokens(&msgs));
        assert!(stats.after_tokens <= stats.before_tokens, "compaction never grows the context");
        assert!(stats.changed());
    }
}
