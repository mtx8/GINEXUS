//! speak tool (SP-Voice) — local text-to-speech via the audio sidecar (Chatterbox Multilingual on
//! Apple MLX). Like image_generate, inference stays OUT of Rust: this POSTs to the sidecar over
//! loopback HTTP. Non-destructive (the sidecar writes a NEW WAV into the app-owned audio dir; the
//! model never controls the path) → autonomous (irreversible:false). The realtime conversational
//! loop does NOT use this — the Swift app streams /synthesize directly for low latency. This tool is
//! for the agent to proactively SPEAK a reply in a normal (typed) chat. Registered only when
//! GINEXUS_AUDIO_BASE is set.

use ginexus_agent::{Tool, ToolResult};
use serde_json::json;
use std::sync::Arc;
use std::time::Duration;

pub fn speak_tool(base: String) -> Tool {
    let base = Arc::new(base.trim_end_matches('/').to_string());
    let desc = "Speak a short reply ALOUD in GINEXUS's voice (local Chatterbox TTS on Apple MLX). Use \
        ONLY when the user explicitly asks you to say/read something aloud or to use voice. Keep it to \
        a sentence or two. The app plays the audio automatically — just confirm briefly (do NOT paste \
        the absolute file path or the computer username).";
    Tool::new(
        "speak",
        desc,
        json!({"type": "object",
               "properties": {
                   "text": {"type": "string", "description": "what to say aloud"},
                   "language_id": {"type": "string", "description": "BCP-ish lang code, e.g. en, ja, es (default en)"},
                   "voice_ref": {"type": "string", "description": "optional clone reference filename in the voices dir"}},
               "required": ["text"]}),
        false, // autonomous: non-destructive, writes only into the audio dir
        Arc::new(move |args| {
            let text = args.get("text").and_then(|v| v.as_str()).unwrap_or("").trim().to_string();
            if text.is_empty() {
                return ToolResult::err("missing 'text'");
            }
            let lang = args.get("language_id").and_then(|v| v.as_str()).unwrap_or("en");
            let mut body = json!({"text": text, "language_id": lang});
            if let Some(vr) = args.get("voice_ref").and_then(|v| v.as_str()) {
                if !vr.trim().is_empty() {
                    body["voice_ref"] = json!(vr.trim());
                }
            }
            let client = match reqwest::blocking::Client::builder()
                .timeout(Duration::from_secs(180)) // cold load + synth can take a while
                .build()
            {
                Ok(c) => c,
                Err(e) => return ToolResult::err(format!("client error: {e}")),
            };
            match client
                .post(format!("{}/speak", base))
                .json(&body)
                .send()
                .and_then(|r| r.error_for_status())
            {
                Ok(resp) => match resp.json::<serde_json::Value>() {
                    Ok(v) => {
                        let path = v.get("path").and_then(|p| p.as_str()).unwrap_or("");
                        if path.is_empty() {
                            ToolResult::err("sidecar returned no path")
                        } else {
                            let ms = v.get("ms").and_then(|m| m.as_i64()).unwrap_or(0);
                            ToolResult::ok(format!(
                                "Spoke aloud ({ms} ms): {}",
                                ginexus_agent::abbreviate_home(path)
                            ))
                        }
                    }
                    Err(e) => ToolResult::err(format!("bad sidecar reply: {e}")),
                },
                Err(e) => ToolResult::err(format!("speak failed: {e}")),
            }
        }),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_text_and_autonomy() {
        let t = speak_tool("http://127.0.0.1:9".into());
        assert!(!t.irreversible); // autonomous, no HITL
        assert!(!t.run(json!({})).ok); // missing text, no network call
    }
}
