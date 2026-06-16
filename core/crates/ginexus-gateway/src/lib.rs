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

const OLLAMA_BASE: &str = "http://127.0.0.1:11434/v1";

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
        let mut m = HashMap::new();
        m.insert(
            "fast".to_string(),
            Endpoint {
                model: "qwen3:1.7b".into(),
                api_base: OLLAMA_BASE.into(),
                api_key: "ollama".into(),
                label: "Fast · Qwen3 1.7B".into(),
            },
        );
        m.insert(
            "smart".to_string(),
            Endpoint {
                model: "qwen3:30b-a3b-instruct-2507-q4_K_M".into(),
                api_base: OLLAMA_BASE.into(),
                api_key: "ollama".into(),
                label: "Smart · Qwen3 30B-A3B".into(),
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
                let api_base =
                    ep.get("api_base").and_then(|x| x.as_str()).unwrap_or(OLLAMA_BASE).to_string();
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
                } else if self.has("fast") {
                    "fast".to_string()
                } else {
                    tier.to_string()
                }
            }
        }
    }

    pub fn resolve(&self, name: &str) -> Endpoint {
        self.models.get(name).cloned().unwrap_or_else(|| Endpoint {
            model: name.to_string(),
            api_base: OLLAMA_BASE.into(),
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
