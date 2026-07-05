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

/// Aspect-ratio presets — all dimensions divisible by 16 (MLX-friendly), ~1MP or less.
fn ratio_dims(ratio: &str) -> Option<(u32, u32)> {
    match ratio {
        "1:1" => Some((1024, 1024)),
        "16:9" => Some((1280, 720)),
        "9:16" => Some((720, 1280)),
        "4:3" => Some((1152, 864)),
        "3:4" => Some((864, 1152)),
        "3:2" => Some((1248, 832)),
        "2:3" => Some((832, 1248)),
        "21:9" => Some((1344, 576)),
        _ => None,
    }
}

pub fn image_generate_tool(base: String, app_host: Option<(String, String)>) -> Tool {
    let base = Arc::new(base.trim_end_matches('/').to_string());
    let host = Arc::new(app_host);
    let loc_note = if host.is_some() {
        " To also drop the PNG into a user folder, set `location` to downloads, desktop, or documents \
         — it is placed there for the user automatically."
    } else {
        ""
    };
    let desc = format!(
        "Generate a PICTURE/illustration locally from a text prompt (Z-Image-Turbo on Apple MLX). Use \
         ONLY when the user EXPLICITLY asks for an image, picture, illustration, photo, drawing, \
         artwork, or visual. Do NOT call this for a story, article, report, note, or document request \
         (including a PDF or Word file) — those need only `write_document`; never add an illustration \
         unless the user explicitly asked for one. The app displays the generated image automatically \
         — just tell the user it was created (do NOT paste the absolute file path or the computer \
         username in your reply).{loc_note}"
    );
    Tool::new(
        "image_generate",
        &desc,
        json!({"type": "object",
               "properties": {
                   "prompt": {"type": "string"},
                   "aspect_ratio": {"type": "string",
                       "enum": ["1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3", "21:9"],
                       "description": "picture shape — map the user's words to a ratio: square 1:1 (default), widescreen/landscape/banner 16:9, phone-vertical/story/portrait 9:16, classic photo 3:2 or 4:3 (portrait 2:3 / 3:4), ultrawide/cinematic 21:9"},
                   "size": {"type": "string", "enum": ["1024x1024", "1280x720", "768x1344"], "description": "legacy — prefer aspect_ratio"},
                   "seed": {"type": "integer"},
                   "location": {"type": "string", "enum": ["downloads", "desktop", "documents"], "description": "also save the PNG into this user folder"}},
               "required": ["prompt"]}),
        false, // autonomous: non-destructive, writes only into the media dir
        Arc::new(move |args| {
            let prompt = args.get("prompt").and_then(|v| v.as_str()).unwrap_or("").trim().to_string();
            if prompt.is_empty() {
                return ToolResult::err("missing 'prompt'");
            }
            let location = args.get("location").and_then(|v| v.as_str()).map(|s| s.trim().to_lowercase());
            let (w, h) = args
                .get("aspect_ratio")
                .and_then(|v| v.as_str())
                .and_then(ratio_dims)
                .unwrap_or_else(|| dims(args.get("size").and_then(|v| v.as_str()).unwrap_or("1024x1024")));
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
                            // Optionally place the PNG into a user folder via the signed app (TCC-correct).
                            if let (Some(loc), Some((sock, tok))) = (location.as_deref(), host.as_ref()) {
                                if matches!(loc, "downloads" | "desktop" | "documents") {
                                    let fname = std::path::Path::new(path)
                                        .file_name().and_then(|f| f.to_str()).unwrap_or("image.png");
                                    let req = json!({"src": path, "location": loc, "filename": fname});
                                    return match ginexus_agent::app_tools::call_app_host_ex(sock, tok, "save_to_folder", &req) {
                                        // Prefer the saved copy's path (the user's chosen folder); fall
                                        // back to the canonical media file so a card always appears.
                                        Ok((out, saved)) => ToolResult::ok(format!("Image generated ({ms} ms). {out}"))
                                            .with_artifact(saved.unwrap_or_else(|| path.to_string())),
                                        Err(e) => ToolResult::ok(format!(
                                            "Image generated ({ms} ms) but couldn't place it in {loc}: {e}"
                                        )).with_artifact(path),
                                    };
                                }
                            }
                            ToolResult::ok(format!("Image saved to {} ({ms} ms).", ginexus_agent::abbreviate_home(path)))
                                .with_artifact(path)
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
    fn ratio_dims_map() {
        assert_eq!(ratio_dims("1:1"), Some((1024, 1024)));
        assert_eq!(ratio_dims("16:9"), Some((1280, 720)));
        assert_eq!(ratio_dims("9:16"), Some((720, 1280)));
        assert_eq!(ratio_dims("21:9"), Some((1344, 576)));
        assert_eq!(ratio_dims("weird"), None); // falls back to size/default
        // every preset is 16-divisible (MLX-friendly)
        for r in ["1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3", "21:9"] {
            let (w, h) = ratio_dims(r).unwrap();
            assert_eq!(w % 16, 0, "{r} width");
            assert_eq!(h % 16, 0, "{r} height");
        }
    }

    #[test]
    fn missing_prompt_and_autonomy() {
        let t = image_generate_tool("http://127.0.0.1:9".into(), None);
        assert!(!t.irreversible); // autonomous, no HITL
        assert!(!t.run(json!({})).ok); // missing prompt, no network call
    }
}
