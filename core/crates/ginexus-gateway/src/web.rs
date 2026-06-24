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

// ── web_search (SP-Research) ────────────────────────────────────────────────────────────────────
// Discover sources for research. Privacy-respecting: only the query leaves the machine, never the
// user's data. Two providers, tried in order:
//   1. Brave Search API (full, live web results) when BRAVE_SEARCH_API_KEY is set — the real thing.
//   2. DuckDuckGo Instant Answer API (keyless, JSON) as a fallback — definitions + related topics.
// (DuckDuckGo's HTML scraping endpoint now bot-blocks non-browser requests, so it is NOT used.)
// The agent then web_fetch's a result url (re-applying the SSRF guard). PSS: read-only, https-only,
// results on private/loopback hosts are dropped, output capped, no API key required to function.

/// Encode a query for a URL (`application/x-www-form-urlencoded` style; space → '+').
fn q_encode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            b' ' => "+".to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

/// Keep a result only if its URL is http(s) and not a private/loopback host.
fn usable_result_url(url: &str) -> bool {
    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return false;
    }
    matches!(host_of(url), Some(h) if !is_blocked_host(&h))
}

/// Parse a Brave Search API JSON response into {title, url, snippet} results.
fn parse_brave(body: &str, max: usize) -> Vec<(String, String, String)> {
    let v: serde_json::Value = match serde_json::from_str(body) {
        Ok(v) => v,
        Err(_) => return vec![],
    };
    let mut out = Vec::new();
    if let Some(arr) = v.get("web").and_then(|w| w.get("results")).and_then(|r| r.as_array()) {
        for r in arr {
            let url = r.get("url").and_then(|u| u.as_str()).unwrap_or("").to_string();
            if !usable_result_url(&url) {
                continue;
            }
            let title = r.get("title").and_then(|t| t.as_str()).unwrap_or("").to_string();
            let snippet = r.get("description").and_then(|d| d.as_str()).unwrap_or("").to_string();
            out.push((title, url, snippet));
            if out.len() >= max {
                break;
            }
        }
    }
    out
}

/// Parse a DuckDuckGo Instant Answer JSON response into {title, url, snippet} results — the abstract
/// (if any) plus flattened RelatedTopics (which may nest under `Topics`).
fn parse_ddg_ia(body: &str, max: usize) -> Vec<(String, String, String)> {
    let v: serde_json::Value = match serde_json::from_str(body) {
        Ok(v) => v,
        Err(_) => return vec![],
    };
    let mut out: Vec<(String, String, String)> = Vec::new();
    let push = |title: String, url: String, snippet: String, out: &mut Vec<(String, String, String)>| {
        if usable_result_url(&url) && !out.iter().any(|(_, u, _)| u == &url) {
            out.push((title, url, snippet));
        }
    };
    // The headline abstract, when present.
    let abstract_url = v.get("AbstractURL").and_then(|u| u.as_str()).unwrap_or("");
    if !abstract_url.is_empty() {
        let heading = v.get("Heading").and_then(|h| h.as_str()).unwrap_or("").to_string();
        let text = v.get("AbstractText").and_then(|t| t.as_str()).unwrap_or("").to_string();
        push(heading, abstract_url.to_string(), text, &mut out);
    }
    // Related topics (each item has FirstURL + Text; some are groups with a nested `Topics` array).
    fn walk(node: &serde_json::Value, out: &mut Vec<(String, String, String)>, max: usize) {
        if let Some(arr) = node.as_array() {
            for item in arr {
                if out.len() >= max {
                    return;
                }
                if let Some(topics) = item.get("Topics") {
                    walk(topics, out, max);
                } else if let (Some(url), Some(text)) = (
                    item.get("FirstURL").and_then(|u| u.as_str()),
                    item.get("Text").and_then(|t| t.as_str()),
                ) {
                    if usable_result_url(url) && !out.iter().any(|(_, u, _)| u == url) {
                        out.push((text.to_string(), url.to_string(), text.to_string()));
                    }
                }
            }
        }
    }
    if let Some(rt) = v.get("RelatedTopics") {
        walk(rt, &mut out, max);
    }
    out.truncate(max);
    out
}

fn search_client() -> Result<reqwest::blocking::Client, String> {
    reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(15))
        .build()
        .map_err(|e| format!("client error: {e}"))
}

pub fn web_search_tool() -> Tool {
    Tool::new(
        "web_search",
        "Search the web for CURRENT information and get back the top results as {title, url, snippet}. \
         Use this to discover live sources (news, prices, docs, recent events), then call web_fetch on a \
         result's url to read it in full. Only your search query leaves the machine — never the user's \
         private data. `query` is required; `max_results` (default 5, max 10) caps the list. With a Brave \
         Search API key configured these are full live web results; without one, results are keyless \
         instant-answers (definitions + related topics) and may be limited.",
        json!({"type": "object",
               "properties": {"query": {"type": "string"},
                              "max_results": {"type": "integer", "minimum": 1, "maximum": 10}},
               "required": ["query"]}),
        false, // read-only → autonomous
        Arc::new(|args| {
            let query = args.get("query").and_then(|v| v.as_str()).unwrap_or("").trim();
            if query.is_empty() {
                return ToolResult::err("empty query");
            }
            let max = args
                .get("max_results")
                .and_then(|v| v.as_u64())
                .map(|n| n.clamp(1, 10) as usize)
                .unwrap_or(5);
            let client = match search_client() {
                Ok(c) => c,
                Err(e) => return ToolResult::err(e),
            };

            // 1 — Brave Search API (full live web results) when a key is configured.
            if let Ok(key) = std::env::var("BRAVE_SEARCH_API_KEY") {
                if !key.trim().is_empty() {
                    let url = format!(
                        "https://api.search.brave.com/res/v1/web/search?q={}&count={max}",
                        q_encode(query)
                    );
                    match client
                        .get(&url)
                        .header("Accept", "application/json")
                        .header("X-Subscription-Token", key.trim())
                        .send()
                        .and_then(|r| r.error_for_status())
                        .and_then(|r| r.text())
                    {
                        Ok(body) => {
                            let items = parse_brave(&body, max);
                            if !items.is_empty() {
                                let arr: Vec<_> = items
                                    .iter()
                                    .map(|(t, u, s)| json!({"title": t, "url": u, "snippet": s}))
                                    .collect();
                                return ToolResult::ok(
                                    json!({"provider": "brave", "results": arr}).to_string(),
                                );
                            }
                        }
                        Err(e) => return ToolResult::err(format!("brave search failed: {e}")),
                    }
                }
            }

            // 2 — Keyless fallback: DuckDuckGo Instant Answer API (definitions + related topics).
            let url = format!(
                "https://api.duckduckgo.com/?q={}&format=json&no_html=1&no_redirect=1&t=ginexus",
                q_encode(query)
            );
            let body = match client
                .get(&url)
                .header("User-Agent", "GINEXUS/0.1 (local research agent)")
                .send()
                .and_then(|r| r.error_for_status())
                .and_then(|r| r.text())
            {
                Ok(b) => b,
                Err(e) => return ToolResult::err(format!("search failed: {e}")),
            };
            let items = parse_ddg_ia(&body, max);
            if items.is_empty() {
                return ToolResult::ok(
                    json!({"provider": "duckduckgo", "results": [],
                           "note": "No keyless results for this query. For full live web search (news, \
                                    prices, recent events), add a Brave Search API key in Settings → \
                                    Connections."})
                    .to_string(),
                );
            }
            let arr: Vec<_> =
                items.iter().map(|(t, u, s)| json!({"title": t, "url": u, "snippet": s})).collect();
            ToolResult::ok(
                json!({"provider": "duckduckgo", "results": arr,
                       "note": "Keyless instant-answer results. For full live web search, add a Brave \
                                Search API key in Settings → Connections."})
                .to_string(),
            )
        }),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn q_encode_basic() {
        assert_eq!(q_encode("rust lang"), "rust+lang");
        assert_eq!(q_encode("a&b=c"), "a%26b%3Dc");
    }

    #[test]
    fn parses_brave_and_drops_private_hosts() {
        let body = r#"{"web":{"results":[
            {"title":"Example","url":"https://example.com/doc","description":"an example"},
            {"title":"Loopback","url":"http://127.0.0.1/x","description":"nope"},
            {"title":"Rust","url":"https://rust-lang.org/","description":"the language"}
        ]}}"#;
        let r = parse_brave(body, 10);
        assert_eq!(r.len(), 2, "private/loopback host must be dropped");
        assert_eq!(r[0].0, "Example");
        assert_eq!(r[0].1, "https://example.com/doc");
        assert_eq!(r[1].1, "https://rust-lang.org/");
    }

    #[test]
    fn parses_ddg_instant_answer_abstract_and_related() {
        let body = r#"{
            "Heading":"Apple Inc.",
            "AbstractText":"American tech company.",
            "AbstractURL":"https://en.wikipedia.org/wiki/Apple_Inc.",
            "RelatedTopics":[
                {"FirstURL":"https://example.com/a","Text":"Topic A"},
                {"Topics":[{"FirstURL":"https://example.com/b","Text":"Topic B"}]},
                {"FirstURL":"http://10.0.0.1/x","Text":"private"}
            ]
        }"#;
        let r = parse_ddg_ia(body, 10);
        // abstract + Topic A + nested Topic B; private host dropped.
        assert_eq!(r.len(), 3);
        assert_eq!(r[0].1, "https://en.wikipedia.org/wiki/Apple_Inc.");
        assert_eq!(r[1].1, "https://example.com/a");
        assert_eq!(r[2].1, "https://example.com/b");
    }

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
