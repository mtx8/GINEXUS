//! image_generate tool (SP6) — local text-to-image via the media sidecar (mflux / Z-Image-Turbo
//! on Apple MLX). Inference stays OUT of Rust: this POSTs to the sidecar over loopback HTTP, like
//! the chat gateway calls Ollama. Generation is non-destructive (writes a NEW PNG into the
//! app-owned media dir; the SIDECAR owns filenames, the model never controls the path) → autonomous
//! (irreversible:false), like web_fetch. Registered only when GINEXUS_MEDIA_BASE is set.

use ginexus_agent::{Tool, ToolResult};
use serde_json::json;
use std::sync::Arc;
use std::time::Duration;

fn dims(size: &str) -> (u32, u32) {
    match size {
        "1280x720" => (1280, 720),
        "768x1344" => (768, 1344),
        _ => (1024, 1024),
    }
}

pub fn image_generate_tool(base: String) -> Tool {
    let base = Arc::new(base.trim_end_matches('/').to_string());
    Tool::new(
        "image_generate",
        "Generate an image locally from a text prompt (Z-Image-Turbo on Apple MLX) and save it to \
         the user's media folder. Use for any 'make/draw/generate an image of …' request. Returns \
         the saved PNG path — include that exact path in your reply so the app can show it.",
        json!({"type": "object",
               "properties": {
                   "prompt": {"type": "string"},
                   "size": {"type": "string", "enum": ["1024x1024", "1280x720", "768x1344"]},
                   "seed": {"type": "integer"}},
               "required": ["prompt"]}),
        false, // autonomous: non-destructive, writes only into the media dir
        Arc::new(move |args| {
            let prompt = args.get("prompt").and_then(|v| v.as_str()).unwrap_or("").trim().to_string();
            if prompt.is_empty() {
                return ToolResult::err("missing 'prompt'");
            }
            let (w, h) = dims(args.get("size").and_then(|v| v.as_str()).unwrap_or("1024x1024"));
            let mut body = json!({"prompt": prompt, "width": w, "height": h, "model": "z-image-turbo"});
            if let Some(seed) = args.get("seed").and_then(|v| v.as_i64()) {
                body["seed"] = json!(seed);
            }
            let client = match reqwest::blocking::Client::builder()
                .timeout(Duration::from_secs(180)) // generation (esp. first/cold) can take a while
                .build()
            {
                Ok(c) => c,
                Err(e) => return ToolResult::err(format!("client error: {e}")),
            };
            match client
                .post(format!("{}/generate", base))
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
                            ToolResult::ok(format!("Image saved to {path} ({ms} ms)."))
                        }
                    }
                    Err(e) => ToolResult::err(format!("bad sidecar reply: {e}")),
                },
                Err(e) => ToolResult::err(format!("image generation failed: {e}")),
            }
        }),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dims_map() {
        assert_eq!(dims("1024x1024"), (1024, 1024));
        assert_eq!(dims("1280x720"), (1280, 720));
        assert_eq!(dims("768x1344"), (768, 1344));
        assert_eq!(dims("weird"), (1024, 1024)); // default
    }

    #[test]
    fn missing_prompt_and_autonomy() {
        let t = image_generate_tool("http://127.0.0.1:9".into());
        assert!(!t.irreversible); // autonomous, no HITL
        assert!(!t.run(json!({})).ok); // missing prompt, no network call
    }
}
