//! web_fetch tool (SP4) — read-only HTTP(S) fetch with an SSRF guard. Lives in the gateway
//! crate (which has reqwest). Read-only → the agent runs it autonomously (no HITL). When the
//! core is sandboxed with egress pinning, this either moves app-side or the egress is allow-listed.

use ginexus_agent::{Tool, ToolResult};
use serde_json::json;
use std::sync::Arc;
use std::time::Duration;

fn host_of(url: &str) -> Option<String> {
    let rest = url.strip_prefix("http://").or_else(|| url.strip_prefix("https://"))?;
    let host_port = rest.split('/').next().unwrap_or("");
    let host = host_port.rsplit('@').next().unwrap_or(host_port); // strip userinfo
    let host = host.split(':').next().unwrap_or(host); // strip port
    Some(host.to_ascii_lowercase())
}

/// Block loopback / private / link-local hosts (basic SSRF guard; a hardened impl also resolves
/// DNS and checks the resolved IPs).
fn is_blocked_host(host: &str) -> bool {
    host == "localhost"
        || host == "0.0.0.0"
        || host == "::1"
        || host.ends_with(".local")
        || host.starts_with("127.")
        || host.starts_with("10.")
        || host.starts_with("192.168.")
        || host.starts_with("169.254.")
        || (host.starts_with("172.")
            && host
                .split('.')
                .nth(1)
                .and_then(|o| o.parse::<u8>().ok())
                .map(|o| (16..=31).contains(&o))
                .unwrap_or(false))
}

pub fn web_fetch_tool() -> Tool {
    Tool::new(
        "web_fetch",
        "Fetch the text content at an http(s) URL (read-only). Returns a truncated excerpt for research.",
        json!({"type": "object", "properties": {"url": {"type": "string"}}, "required": ["url"]}),
        false, // read-only → autonomous
        Arc::new(|args| {
            let url = args.get("url").and_then(|v| v.as_str()).unwrap_or("").trim().to_string();
            if !(url.starts_with("http://") || url.starts_with("https://")) {
                return ToolResult::err("only http/https URLs are allowed");
            }
            match host_of(&url) {
                Some(h) if is_blocked_host(&h) => {
                    return ToolResult::err("refusing to fetch a private/loopback host (SSRF guard)")
                }
                None => return ToolResult::err("could not parse host"),
                _ => {}
            }
            let client = match reqwest::blocking::Client::builder()
                .timeout(Duration::from_secs(15))
                .build()
            {
                Ok(c) => c,
                Err(e) => return ToolResult::err(format!("client error: {e}")),
            };
            match client
                .get(&url)
                .header("User-Agent", "GINEXUS/0.1")
                .send()
                .and_then(|r| r.error_for_status())
                .and_then(|r| r.text())
            {
                Ok(mut body) => {
                    if body.len() > 4000 {
                        body.truncate(4000);
                        body.push_str("…[truncated]");
                    }
                    ToolResult::ok(body)
                }
                Err(e) => ToolResult::err(format!("fetch failed: {e}")),
            }
        }),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ssrf_guard_blocks_private() {
        for h in ["localhost", "127.0.0.1", "10.0.0.5", "192.168.1.1", "172.16.0.1", "169.254.1.1", "0.0.0.0"] {
            assert!(is_blocked_host(h), "{h} should be blocked");
        }
        for h in ["example.com", "8.8.8.8", "huggingface.co", "172.15.0.1", "172.32.0.1"] {
            assert!(!is_blocked_host(h), "{h} should be allowed");
        }
    }

    #[test]
    fn host_parse() {
        assert_eq!(host_of("https://example.com/path?q=1").unwrap(), "example.com");
        assert_eq!(host_of("http://user@10.0.0.1:8080/x").unwrap(), "10.0.0.1");
    }

    #[test]
    fn rejects_non_http_and_private_without_network() {
        let t = web_fetch_tool();
        assert!(!t.run(json!({"url": "file:///etc/passwd"})).ok);
        assert!(!t.run(json!({"url": "http://127.0.0.1:11434/"})).ok); // SSRF guard, no network call
        assert!(!t.run(json!({"url": "not-a-url"})).ok);
    }
}
