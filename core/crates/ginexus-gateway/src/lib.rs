//! Model router + HTTP client (Rust core). Port of `router.py` + `gateway.py`.
//!
//! Resolves a LOGICAL model name (fast/bulk/embed) to a concrete OpenAI-compatible endpoint
//! and calls it over HTTP (reqwest). `BoundModel` implements the agent crate's `ModelCall`
//! trait so the agent loop drives a real model. Inference itself lives in the model server
//! (Ollama / MLX); the Rust core only orchestrates.

use async_trait::async_trait;
use ginexus_agent::{AssistantTurn, ModelCall, ToolCall};
use serde_json::{json, Value};
use std::collections::HashMap;

pub mod web;

#[derive(Clone, Debug)]
pub struct Endpoint {
    pub model: String,
    pub api_base: String,
    pub api_key: String,
}

/// Task shape → logical model name (Tier 0/1/2 policy over logical names).
pub fn route(task: &str, difficulty: &str, latency_sensitive: bool) -> &'static str {
    if task == "embed" {
        return "embed";
    }
    if latency_sensitive || difficulty == "low" || task == "route" || task == "extract" {
        return "fast";
    }
    if difficulty == "hard" || task == "reason" || task == "code" {
        return "bulk";
    }
    "fast"
}

pub struct Gateway {
    models: HashMap<String, Endpoint>,
    client: reqwest::Client,
}

impl Gateway {
    pub fn new(models: HashMap<String, Endpoint>) -> Self {
        Self { models, client: reqwest::Client::new() }
    }

    /// Default local stack: "fast" → Ollama qwen3:1.7b (the SBPL profile pins egress to :11434).
    pub fn default_local() -> Self {
        let mut m = HashMap::new();
        m.insert(
            "fast".to_string(),
            Endpoint { model: "qwen3:1.7b".into(), api_base: "http://127.0.0.1:11434/v1".into(), api_key: "ollama".into() },
        );
        Self::new(m)
    }

    pub fn resolve(&self, name: &str) -> Endpoint {
        self.models.get(name).cloned().unwrap_or_else(|| Endpoint {
            model: name.to_string(),
            api_base: "http://127.0.0.1:11434/v1".into(),
            api_key: "ollama".into(),
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
        let mut body = json!({"model": ep.model, "messages": messages, "stream": false});
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
        assert_eq!(route("chat", "low", false), "fast");
        assert_eq!(route("chat", "normal", true), "fast");
        assert_eq!(route("reason", "normal", false), "bulk");
        assert_eq!(route("code", "normal", false), "bulk");
        assert_eq!(route("chat", "hard", false), "bulk");
        assert_eq!(route("chat", "normal", false), "fast");
    }

    #[test]
    fn resolve_known_and_unknown() {
        let gw = Gateway::default_local();
        assert_eq!(gw.resolve("fast").model, "qwen3:1.7b");
        // unknown logical name passes through as a literal model on the default endpoint
        assert_eq!(gw.resolve("llama3.2:1b").model, "llama3.2:1b");
    }
}
