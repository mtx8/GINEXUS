//! Model router + HTTP client (Rust core). Port of `router.py` + `gateway.py`.
//!
//! Resolves a LOGICAL model name (fast/smart/embed/code) to a concrete OpenAI-compatible
//! endpoint and calls it over HTTP (reqwest). `BoundModel` implements the agent crate's
//! `ModelCall` trait so the agent loop drives a real model. Inference itself lives in the model
//! server (Ollama / MLX); the Rust core only orchestrates.
//!
//! Model selection (SP1-tail) is auto OR manual:
//!   - "auto" (default) → `route()` policy maps task/difficulty → a tier (fast/smart/...).
//!   - a registered tier key ("fast"/"smart"/…) → that endpoint.
//!   - any other string → passthrough literal model on the default (Ollama) endpoint.
//! The roster is data-driven: load from JSON via `GINEXUS_MODELS_CONFIG`, else `default_local()`.

use async_trait::async_trait;
use ginexus_agent::{AssistantTurn, ModelCall, ToolCall};
use serde_json::{json, Value};
use std::collections::HashMap;

pub mod web;
pub mod media;

const OLLAMA_BASE: &str = "http://127.0.0.1:11434/v1";

/// The OpenAI-compatible Ollama base. Defaults to local loopback; the app can override it for ALL
/// tiers (and, via ollama_root, model management) by setting `GINEXUS_OLLAMA_BASE` at boot — the
/// "env injected at boot + respawn" path the Settings screen uses. Empty/unset → the default.
fn ollama_base() -> String {
    std::env::var("GINEXUS_OLLAMA_BASE").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| OLLAMA_BASE.to_string())
}

#[derive(Clone, Debug)]
pub struct Endpoint {
    pub model: String,
    pub api_base: String,
    pub api_key: String,
    /// Human label for the UI selector (defaults to the model id).
    pub label: String,
}

/// Task shape → logical tier (Tier 0/1/2 policy over roster keys).
/// Quality-first default: chat/reason/agent → the strong model ("smart"); only trivial or
/// explicitly latency-sensitive work drops to "fast".
pub fn route(task: &str, difficulty: &str, latency_sensitive: bool) -> &'static str {
    if task == "vision" {
        return "vlm";
    }
    if task == "embed" {
        return "embed";
    }
    if task == "code" {
        return "code";
    }
    if latency_sensitive || difficulty == "low" || task == "route" || task == "extract" {
        return "fast";
    }
    "smart"
}

/// True if any message carries an image part (OpenAI multimodal content array with an `image_url`).
/// Used to force the vision tier so an image request can never silently route to a text-only model.
pub fn has_image(messages: &[Value]) -> bool {
    messages.iter().any(|m| {
        m.get("content").and_then(|c| c.as_array()).is_some_and(|parts| {
            parts.iter().any(|p| p.get("type").and_then(|t| t.as_str()) == Some("image_url"))
        })
    })
}

pub struct Gateway {
    models: HashMap<String, Endpoint>,
    client: reqwest::Client,
}

impl Gateway {
    pub fn new(models: HashMap<String, Endpoint>) -> Self {
        Self { models, client: reqwest::Client::new() }
    }

    /// Default local stack: "fast" → Ollama qwen3:1.7b (quick), "smart" → Qwen3-30B-A3B
    /// (production chat/agent). The SBPL/egress profile pins traffic to Ollama at :11434.
    pub fn default_local() -> Self {
        let base = ollama_base();
        let mut m = HashMap::new();
        m.insert(
            "fast".to_string(),
            Endpoint {
                model: "qwen3:1.7b".into(),
                api_base: base.clone(),
                api_key: "ollama".into(),
                label: "Fast · Qwen3 1.7B".into(),
            },
        );
        m.insert(
            "smart".to_string(),
            Endpoint {
                model: "qwen3:30b-a3b-instruct-2507-q4_K_M".into(),
                api_base: base.clone(),
                api_key: "ollama".into(),
                label: "Smart · Qwen3 30B-A3B".into(),
            },
        );
        m.insert(
            "embed".to_string(),
            Endpoint {
                model: "nomic-embed-text".into(),
                api_base: base.clone(),
                api_key: "ollama".into(),
                label: "Embed · nomic-embed-text".into(),
            },
        );
        // Vision tier (image understanding). Inert until the operator pulls a VLM — selected only
        // when a request carries an image; vision must FAIL LOUD, never downgrade to a text model.
        m.insert(
            "vlm".to_string(),
            Endpoint {
                model: "qwen3-vl:30b-a3b-instruct".into(),
                api_base: base.clone(),
                api_key: "ollama".into(),
                label: "Vision · Qwen3-VL 30B-A3B".into(),
            },
        );
        Self::new(m)
    }

    /// Load a roster from JSON:
    /// `{"models": {"fast": {"model":"…","api_base":"…","api_key":"…","label":"…"}, …}}`
    /// Missing fields default to the local Ollama endpoint. An empty roster is an error.
    pub fn from_config_str(s: &str) -> Result<Self, String> {
        let v: Value = serde_json::from_str(s).map_err(|e| format!("bad models config: {e}"))?;
        let mut m = HashMap::new();
        if let Some(obj) = v.get("models").and_then(|x| x.as_object()) {
            for (k, ep) in obj {
                let model = ep.get("model").and_then(|x| x.as_str()).unwrap_or(k).to_string();
                let api_base = ep
                    .get("api_base")
                    .and_then(|x| x.as_str())
                    .map(|s| s.to_string())
                    .unwrap_or_else(ollama_base);
                let api_key =
                    ep.get("api_key").and_then(|x| x.as_str()).unwrap_or("ollama").to_string();
                let label = ep.get("label").and_then(|x| x.as_str()).unwrap_or(&model).to_string();
                m.insert(k.clone(), Endpoint { model, api_base, api_key, label });
            }
        }
        if m.is_empty() {
            return Err("models config has no entries".into());
        }
        Ok(Self::new(m))
    }

    pub fn from_config_file(path: &std::path::Path) -> Result<Self, String> {
        let s = std::fs::read_to_string(path)
            .map_err(|e| format!("read models config {}: {e}", path.display()))?;
        Self::from_config_str(&s)
    }

    pub fn has(&self, name: &str) -> bool {
        self.models.contains_key(name)
    }

    /// Roster (key, endpoint) sorted by key — feeds `GET /v1/models` and the app's picker.
    pub fn roster(&self) -> Vec<(String, Endpoint)> {
        let mut v: Vec<(String, Endpoint)> =
            self.models.iter().map(|(k, e)| (k.clone(), e.clone())).collect();
        v.sort_by(|a, b| a.0.cmp(&b.0));
        v
    }

    /// Resolve the concrete tier to use for a request.
    /// `requested`: None/""/"auto" → policy route (falls back to "fast" if the routed tier
    /// isn't in the roster, e.g. the 30B isn't pulled yet); a registered key → itself; any
    /// other string → passthrough literal on the default endpoint.
    pub fn select(
        &self, requested: Option<&str>, task: &str, difficulty: &str, latency_sensitive: bool,
    ) -> String {
        match requested {
            Some(r) if !r.is_empty() && r != "auto" => r.to_string(),
            _ => {
                let tier = route(task, difficulty, latency_sensitive);
                if self.has(tier) {
                    tier.to_string()
                } else if tier == "vlm" {
                    // Vision must fail LOUD: if no VLM is pulled, return the literal vlm model so the
                    // request errors cleanly rather than silently routing an image to a blind text model.
                    "vlm".to_string()
                } else if self.has("fast") {
                    "fast".to_string()
                } else {
                    tier.to_string()
                }
            }
        }
    }

    /// Ollama's NATIVE API root (strip the OpenAI-compat `/v1` off the default endpoint), e.g.
    /// http://127.0.0.1:11434 — used for model management (/api/tags, /api/version, /api/pull).
    pub fn ollama_root(&self) -> String {
        let base = self.resolve("smart").api_base; // typically http://127.0.0.1:11434/v1
        base.trim_end_matches("/v1").trim_end_matches('/').to_string()
    }
    /// Shared async HTTP client (Arc inside reqwest) — lets the server stream /api/pull itself.
    pub fn http_client(&self) -> reqwest::Client {
        self.client.clone()
    }
    /// GET a JSON document from Ollama's native API (e.g. "/api/tags", "/api/version").
    pub async fn ollama_get(&self, path: &str) -> Result<Value, String> {
        let url = format!("{}{}", self.ollama_root(), path);
        let resp = self.client.get(url).send().await.map_err(|e| format!("ollama unreachable: {e}"))?;
        if !resp.status().is_success() {
            return Err(format!("ollama HTTP {}", resp.status()));
        }
        resp.json().await.map_err(|e| format!("ollama parse: {e}"))
    }

    pub fn resolve(&self, name: &str) -> Endpoint {
        self.models.get(name).cloned().unwrap_or_else(|| Endpoint {
            model: name.to_string(),
            // Honor the GINEXUS_OLLAMA_BASE override for passthrough literals (a picker-added
            // installed model) and for ollama_root when no "smart" tier exists — so tiers and model
            // management always point at the same host.
            api_base: ollama_base(),
            api_key: "ollama".into(),
            label: name.to_string(),
        })
    }

    /// Non-streaming chat → assembled content string.
    pub async fn chat(&self, model: &str, messages: &[Value]) -> Result<String, String> {
        let turn = self.complete_with_tools(model, messages, &[]).await?;
        Ok(turn.content.unwrap_or_default())
    }

    /// Completion that may return tool calls — drives the agent loop.
    pub async fn complete_with_tools(
        &self, model: &str, messages: &[Value], tools: &[Value],
    ) -> Result<AssistantTurn, String> {
        let ep = self.resolve(model);
        // temperature 0 → deterministic tool-args (so an approve→re-invoke reproduces the call).
        let mut body = json!({"model": ep.model, "messages": messages, "stream": false, "temperature": 0});
        if !tools.is_empty() {
            body["tools"] = json!(tools);
        }
        let resp = self
            .client
            .post(format!("{}/chat/completions", ep.api_base))
            .bearer_auth(&ep.api_key)
            .json(&body)
            .send()
            .await
            .map_err(|e| format!("request failed: {e}"))?;
        if !resp.status().is_success() {
            return Err(format!("model server HTTP {}", resp.status()));
        }
        let v: Value = resp.json().await.map_err(|e| format!("bad response: {e}"))?;
        let msg = &v["choices"][0]["message"];
        let content = msg.get("content").and_then(|c| c.as_str()).map(|s| s.to_string());
        let mut tool_calls = Vec::new();
        if let Some(tcs) = msg.get("tool_calls").and_then(|t| t.as_array()) {
            for tc in tcs {
                let name = tc["function"]["name"].as_str().unwrap_or("").to_string();
                let raw = &tc["function"]["arguments"];
                let arguments = match raw {
                    Value::String(s) => serde_json::from_str(s).unwrap_or(json!({})),
                    other => other.clone(),
                };
                let id = tc.get("id").and_then(|i| i.as_str()).unwrap_or("").to_string();
                tool_calls.push(ToolCall { id, name, arguments });
            }
        }
        Ok(AssistantTurn { content, tool_calls })
    }

    /// Streaming completion: same as `complete_with_tools` but forwards each content delta to
    /// `on_token` AS IT ARRIVES (OpenAI-style SSE, `stream:true`), and still returns the assembled
    /// `AssistantTurn` (content + any tool calls) at the end. Tool-call deltas arrive fragmented
    /// (per `index`, with `arguments` concatenated across chunks), so we accumulate them and parse
    /// once complete. Content during a tool-calling turn (model "thinking") streams too — harmless.
    pub async fn complete_with_tools_streaming<F>(
        &self, model: &str, messages: &[Value], tools: &[Value], on_token: F,
    ) -> Result<AssistantTurn, String>
    where
        F: Fn(&str),
    {
        use futures_util::StreamExt;
        let ep = self.resolve(model);
        let mut body =
            json!({"model": ep.model, "messages": messages, "stream": true, "temperature": 0});
        if !tools.is_empty() {
            body["tools"] = json!(tools);
        }
        let resp = self
            .client
            .post(format!("{}/chat/completions", ep.api_base))
            .bearer_auth(&ep.api_key)
            .json(&body)
            .send()
            .await
            .map_err(|e| format!("request failed: {e}"))?;
        if !resp.status().is_success() {
            return Err(format!("model server HTTP {}", resp.status()));
        }

        let mut content = String::new();
        let mut emitted_len = 0usize; // bytes of displayable (think-stripped) content already forwarded
        // tool-call accumulators keyed by index: (id, name, arguments-so-far)
        let mut tcs: std::collections::BTreeMap<usize, (String, String, String)> = Default::default();
        let mut stream = resp.bytes_stream();
        let mut buf = String::new();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|e| format!("stream error: {e}"))?;
            buf.push_str(&String::from_utf8_lossy(&chunk));
            // Process complete SSE lines; keep any partial trailing line in `buf`.
            while let Some(nl) = buf.find('\n') {
                let line = buf[..nl].trim().to_string();
                buf.drain(..=nl);
                let data = match line.strip_prefix("data:") {
                    Some(d) => d.trim(),
                    None => continue,
                };
                if data.is_empty() || data == "[DONE]" {
                    continue;
                }
                let v: Value = match serde_json::from_str(data) {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                let delta = &v["choices"][0]["delta"];
                if let Some(tok) = delta.get("content").and_then(|c| c.as_str()) {
                    if !tok.is_empty() {
                        content.push_str(tok);
                        // Forward only the DISPLAYABLE suffix (a thinking model's <think>…</think>
                        // chain-of-thought is suppressed; instruct models stream from the start).
                        let vis = visible_content(&content);
                        if vis.len() > emitted_len {
                            on_token(&vis[emitted_len..]);
                            emitted_len = vis.len();
                        }
                    }
                }
                if let Some(arr) = delta.get("tool_calls").and_then(|t| t.as_array()) {
                    for tc in arr {
                        let idx = tc.get("index").and_then(|i| i.as_u64()).unwrap_or(0) as usize;
                        let e = tcs.entry(idx).or_default();
                        if let Some(id) = tc.get("id").and_then(|i| i.as_str()) {
                            if !id.is_empty() {
                                e.0 = id.to_string();
                            }
                        }
                        if let Some(n) = tc["function"].get("name").and_then(|n| n.as_str()) {
                            if !n.is_empty() {
                                e.1 = n.to_string();
                            }
                        }
                        if let Some(a) = tc["function"].get("arguments").and_then(|a| a.as_str()) {
                            e.2.push_str(a);
                        }
                    }
                }
            }
        }

        let tool_calls = tcs
            .into_values()
            .filter(|(_, name, _)| !name.is_empty())
            .map(|(id, name, args)| {
                let arguments = serde_json::from_str(&args).unwrap_or_else(|_| json!({}));
                ToolCall { id, name, arguments }
            })
            .collect();
        // Return the think-stripped, trimmed answer (matches what was streamed + clean history).
        let answer = visible_content(&content).trim();
        Ok(AssistantTurn {
            content: if answer.is_empty() { None } else { Some(answer.to_string()) },
            tool_calls,
        })
    }
}

/// The displayable portion of (possibly partial) streamed content: everything after a closing
/// `</think>` (a thinking model's chain-of-thought is hidden), `""` while still inside an unclosed
/// `<think>`, or the whole string when there are no think tags (instruct models stream from start).
fn visible_content(content: &str) -> &str {
    const CLOSE: &str = "</think>";
    if let Some(i) = content.rfind(CLOSE) {
        return &content[i + CLOSE.len()..];
    }
    if content.contains("<think>") {
        return "";
    }
    content
}

/// Build the shared blocking embed client once (connection pool + TLS config reused across calls).
/// Constructing a fresh client per embedding is what made bulk import O(N) client builds → slow.
fn embed_client() -> Result<reqwest::blocking::Client, String> {
    reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(120))
        .build()
        .map_err(|e| format!("embed client: {e}"))
}

/// Blocking embedding call (OpenAI-compatible `/embeddings`) → a dense vector. Used by the memory
/// store for semantic recall (single-query path); it runs inside the agent loop's `spawn_blocking`,
/// so blocking is fine. For bulk work use `embed_batch` — one round-trip for many texts.
pub fn embed_text(api_base: &str, api_key: &str, model: &str, text: &str) -> Result<Vec<f32>, String> {
    embed_batch_with(&embed_client()?, api_base, api_key, model, &[text])?
        .into_iter()
        .next()
        .ok_or_else(|| "no embedding in response".to_string())
}

/// Batched embeddings: ONE HTTP round-trip for many texts (OpenAI `/embeddings` array input).
/// Ollama runs the whole batch in a single model invocation, so embedding 64 texts costs ~the
/// same wall-clock as one — the core fix for bulk import (was N sequential calls + N client builds).
/// Returns vectors aligned to `texts` (sorted by the response `index`). Builds one client per call;
/// callers doing many batches should prefer `embed_batch_with` to reuse a single client.
pub fn embed_batch(api_base: &str, api_key: &str, model: &str, texts: &[&str]) -> Result<Vec<Vec<f32>>, String> {
    embed_batch_with(&embed_client()?, api_base, api_key, model, texts)
}

/// `embed_batch` against a caller-provided client — lets a bulk importer reuse one connection pool
/// across many chunks instead of rebuilding it each time.
pub fn embed_batch_with(
    client: &reqwest::blocking::Client, api_base: &str, api_key: &str, model: &str, texts: &[&str],
) -> Result<Vec<Vec<f32>>, String> {
    if texts.is_empty() {
        return Ok(Vec::new());
    }
    let v: Value = client
        .post(format!("{}/embeddings", api_base.trim_end_matches('/')))
        .bearer_auth(api_key)
        .json(&json!({"model": model, "input": texts}))
        .send()
        .and_then(|r| r.error_for_status())
        .map_err(|e| format!("embed request: {e}"))?
        .json()
        .map_err(|e| format!("embed parse: {e}"))?;
    let data = v["data"].as_array().ok_or("no data array in embeddings response")?;
    if data.len() != texts.len() {
        return Err(format!("embedding count mismatch: got {}, want {}", data.len(), texts.len()));
    }
    Ok(realign_embeddings(data, texts.len()))
}

/// Realign embedding `data` entries to the input order. OpenAI permits out-of-order responses, so we
/// honor the per-entry `index` — but ONLY when the indices form a valid permutation of `0..n`
/// (every index in range, no duplicates). If the server returns an out-of-range, duplicate, or
/// missing index, we fall back to the response's positional order (both Ollama and OpenAI emit in
/// input order) rather than letting `sort` silently MISALIGN embeddings — a misalignment would pair
/// each fact with the wrong vector and permanently poison semantic recall. Caller guarantees
/// `data.len() == n`.
fn realign_embeddings(data: &[Value], n: usize) -> Vec<Vec<f32>> {
    let mut items: Vec<(usize, Vec<f32>)> = data
        .iter()
        .enumerate()
        .map(|(i, d)| {
            let idx = d.get("index").and_then(|x| x.as_u64()).map(|v| v as usize).unwrap_or(i);
            let emb = d["embedding"]
                .as_array()
                .map(|a| a.iter().filter_map(|x| x.as_f64().map(|f| f as f32)).collect())
                .unwrap_or_default();
            (idx, emb)
        })
        .collect();
    // Valid permutation ⇔ exactly n entries, each index < n and seen at most once.
    let mut seen = vec![false; n];
    let is_perm = items.len() == n
        && items.iter().all(|(idx, _)| *idx < n && !std::mem::replace(&mut seen[*idx], true));
    if is_perm {
        items.sort_by_key(|(idx, _)| *idx);
    }
    items.into_iter().map(|(_, e)| e).collect()
}

/// Embed many texts reusing ONE client, one round-trip per `chunk` texts. Returns one
/// `Option<Vec<f32>>` per input — `None` where that chunk's request failed (so a transient embed
/// error degrades a few facts to keyword-only recall rather than failing the whole import). This is
/// the closure the memory store's batch embedder is backed by.
pub fn embed_many(
    api_base: &str, api_key: &str, model: &str, texts: &[&str], chunk: usize,
) -> Vec<Option<Vec<f32>>> {
    let chunk = chunk.max(1);
    let client = match embed_client() {
        Ok(c) => c,
        Err(_) => return vec![None; texts.len()],
    };
    let mut out: Vec<Option<Vec<f32>>> = Vec::with_capacity(texts.len());
    for c in texts.chunks(chunk) {
        match embed_batch_with(&client, api_base, api_key, model, c) {
            Ok(vecs) => out.extend(vecs.into_iter().map(Some)),
            Err(_) => out.extend(std::iter::repeat_with(|| None).take(c.len())),
        }
    }
    out
}

/// Binds a logical model name to the gateway so the agent loop can call it via `ModelCall`.
pub struct BoundModel<'a> {
    pub gateway: &'a Gateway,
    pub model: String,
}

#[async_trait]
impl ModelCall for BoundModel<'_> {
    async fn call(&self, messages: &[Value], tools: &[Value]) -> AssistantTurn {
        self.gateway
            .complete_with_tools(&self.model, messages, tools)
            .await
            .unwrap_or_else(|e| AssistantTurn { content: Some(format!("model error: {e}")), tool_calls: vec![] })
    }

    async fn call_streaming(
        &self, messages: &[Value], tools: &[Value], on_token: &(dyn Fn(String) + Send + Sync),
    ) -> AssistantTurn {
        self.gateway
            .complete_with_tools_streaming(&self.model, messages, tools, |t| on_token(t.to_string()))
            .await
            .unwrap_or_else(|e| AssistantTurn { content: Some(format!("model error: {e}")), tool_calls: vec![] })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn routing_policy() {
        assert_eq!(route("embed", "normal", false), "embed");
        assert_eq!(route("code", "normal", false), "code");
        assert_eq!(route("chat", "low", false), "fast");
        assert_eq!(route("chat", "normal", true), "fast");
        assert_eq!(route("route", "normal", false), "fast");
        // quality-first: chat/reason/agent default to the strong model.
        assert_eq!(route("chat", "normal", false), "smart");
        assert_eq!(route("reason", "normal", false), "smart");
        assert_eq!(route("chat", "hard", false), "smart");
    }

    #[test]
    fn resolve_known_and_unknown() {
        let gw = Gateway::default_local();
        assert_eq!(gw.resolve("fast").model, "qwen3:1.7b");
        assert_eq!(gw.resolve("smart").model, "qwen3:30b-a3b-instruct-2507-q4_K_M");
        // unknown logical name passes through as a literal model on the default endpoint
        assert_eq!(gw.resolve("llama3.2:1b").model, "llama3.2:1b");
    }

    #[test]
    fn select_auto_vs_manual() {
        let gw = Gateway::default_local();
        // explicit pick wins
        assert_eq!(gw.select(Some("fast"), "chat", "normal", false), "fast");
        assert_eq!(gw.select(Some("smart"), "chat", "normal", false), "smart");
        // auto routes chat → smart (registered)
        assert_eq!(gw.select(Some("auto"), "chat", "normal", false), "smart");
        assert_eq!(gw.select(None, "chat", "normal", false), "smart");
        // auto routes trivial → fast
        assert_eq!(gw.select(None, "chat", "normal", true), "fast");
        // passthrough literal
        assert_eq!(gw.select(Some("llama3.2:1b"), "chat", "normal", false), "llama3.2:1b");
    }

    #[test]
    fn auto_falls_back_to_fast_when_tier_absent() {
        // roster without "smart" (e.g. 30B not pulled): auto chat must not route to a missing tier.
        let mut m = HashMap::new();
        m.insert(
            "fast".to_string(),
            Endpoint { model: "qwen3:1.7b".into(), api_base: OLLAMA_BASE.into(), api_key: "ollama".into(), label: "Fast".into() },
        );
        let gw = Gateway::new(m);
        assert_eq!(gw.select(None, "chat", "normal", false), "fast");
    }

    #[test]
    fn vision_routing_and_detection() {
        // has_image: string content → false; content array with an image_url part → true.
        let text_only = vec![json!({"role": "user", "content": "hello"})];
        assert!(!has_image(&text_only));
        let with_image = vec![json!({"role": "user", "content": [
            {"type": "text", "text": "what is this?"},
            {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,AAAA"}}
        ]})];
        assert!(has_image(&with_image));

        // route(vision) → vlm; default_local has it.
        assert_eq!(route("vision", "normal", false), "vlm");
        let gw = Gateway::default_local();
        assert_eq!(gw.select(None, "vision", "normal", false), "vlm");
        // explicit override still wins over vision auto-routing.
        assert_eq!(gw.select(Some("smart"), "vision", "normal", false), "smart");
    }

    #[test]
    fn vision_fails_loud_when_vlm_absent() {
        // roster without a "vlm" tier: a vision request must NOT downgrade to "fast" — return the
        // literal "vlm" so Ollama errors cleanly instead of a blind text model hallucinating.
        let mut m = HashMap::new();
        m.insert(
            "fast".to_string(),
            Endpoint { model: "qwen3:1.7b".into(), api_base: OLLAMA_BASE.into(), api_key: "ollama".into(), label: "Fast".into() },
        );
        let gw = Gateway::new(m);
        assert_eq!(gw.select(None, "vision", "normal", false), "vlm");
    }

    // Encode each embedding as a 1-dim vector tagging its SOURCE position, so a realignment bug is
    // observable as a value out of place.
    fn datum(index: i64, tag: f32) -> Value {
        json!({"index": index, "embedding": [tag]})
    }

    #[test]
    fn realign_in_order_is_identity() {
        let data = vec![datum(0, 10.0), datum(1, 11.0), datum(2, 12.0)];
        let out = realign_embeddings(&data, 3);
        assert_eq!(out, vec![vec![10.0], vec![11.0], vec![12.0]]);
    }

    #[test]
    fn realign_valid_permutation_is_sorted_to_input_order() {
        // Server returned them shuffled but with correct indices → must be restored to input order.
        let data = vec![datum(2, 12.0), datum(0, 10.0), datum(1, 11.0)];
        let out = realign_embeddings(&data, 3);
        assert_eq!(out, vec![vec![10.0], vec![11.0], vec![12.0]]);
    }

    #[test]
    fn realign_duplicate_index_falls_back_to_response_order() {
        // [0,0,1] is NOT a permutation → trusting it would misalign. Keep response order instead.
        let data = vec![datum(0, 10.0), datum(0, 99.0), datum(1, 11.0)];
        let out = realign_embeddings(&data, 3);
        assert_eq!(out, vec![vec![10.0], vec![99.0], vec![11.0]]);
    }

    #[test]
    fn realign_out_of_range_index_falls_back_to_response_order() {
        // index 5 for n=3 → out of range → fall back, no panic, no misalignment.
        let data = vec![datum(0, 10.0), datum(1, 11.0), datum(5, 12.0)];
        let out = realign_embeddings(&data, 3);
        assert_eq!(out, vec![vec![10.0], vec![11.0], vec![12.0]]);
    }

    #[test]
    fn realign_missing_index_uses_response_order() {
        // No `index` field → enumerate fallback yields 0,1,2 (a valid perm) → identity.
        let data = vec![json!({"embedding": [10.0]}), json!({"embedding": [11.0]})];
        let out = realign_embeddings(&data, 2);
        assert_eq!(out, vec![vec![10.0], vec![11.0]]);
    }

    #[test]
    fn config_roster_loads() {
        let cfg = r#"{"models":{"smart":{"model":"qwen3:30b-a3b-instruct-2507-q4_K_M","label":"Smart"},
                                  "fast":{"model":"qwen3:1.7b"}}}"#;
        let gw = Gateway::from_config_str(cfg).unwrap();
        assert_eq!(gw.resolve("smart").model, "qwen3:30b-a3b-instruct-2507-q4_K_M");
        assert_eq!(gw.resolve("smart").label, "Smart");
        assert_eq!(gw.resolve("fast").api_base, OLLAMA_BASE); // defaulted
        let roster = gw.roster();
        assert_eq!(roster.len(), 2);
        assert_eq!(roster[0].0, "fast"); // sorted
        assert!(Gateway::from_config_str("{}").is_err()); // empty roster rejected
    }
}
