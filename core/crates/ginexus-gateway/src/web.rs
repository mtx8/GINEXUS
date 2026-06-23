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
// Discover sources for research. Keyless + privacy-respecting: queries DuckDuckGo's HTML endpoint
// (only the query string leaves the machine — never the user's data), parses the result links, and
// hands back {title, url}. The agent then web_fetch's a result (which re-applies the SSRF guard).
// PSS: read-only, https-only, results on private/loopback hosts are dropped, output is capped.

/// Percent-decode (for DuckDuckGo's `uddg` redirect param). Bad escapes pass through unchanged.
fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'%' if i + 2 < b.len() => {
                let hi = (b[i + 1] as char).to_digit(16);
                let lo = (b[i + 2] as char).to_digit(16);
                if let (Some(h), Some(l)) = (hi, lo) {
                    out.push((h * 16 + l) as u8);
                    i += 3;
                } else {
                    out.push(b[i]);
                    i += 1;
                }
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).to_string()
}

/// Strip HTML tags and collapse whitespace (for result titles/snippets).
fn strip_tags(s: &str) -> String {
    let mut out = String::new();
    let mut in_tag = false;
    for c in s.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

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

/// Parse DuckDuckGo HTML into (title, url) results. Pulled out so it's testable without a network.
fn parse_ddg_results(body: &str, max: usize) -> Vec<(String, String)> {
    let mut results: Vec<(String, String)> = Vec::new();
    for (idx, _) in body.match_indices("uddg=") {
        let after = &body[idx + 5..];
        let end = after.find(['&', '"']).unwrap_or(after.len());
        let url = percent_decode(&after[..end]);
        if !(url.starts_with("http://") || url.starts_with("https://")) {
            continue;
        }
        match host_of(&url) {
            Some(h) if is_blocked_host(&h) => continue, // never surface a private/loopback host
            None => continue,
            _ => {}
        }
        // Title: the anchor text right after the href closes (`">` … `</a>`).
        let title = after
            .find("\">")
            .and_then(|gt| {
                let rest = &after[gt + 2..];
                rest.find("</a>").map(|c| strip_tags(&rest[..c]))
            })
            .unwrap_or_default();
        if results.iter().any(|(_, u)| u == &url) {
            continue; // dedup
        }
        results.push((title, url));
        if results.len() >= max {
            break;
        }
    }
    results
}

pub fn web_search_tool() -> Tool {
    Tool::new(
        "web_search",
        "Search the web (privacy-respecting, keyless, no tracking) and get back the top results as \
         {title, url}. Use this to DISCOVER current sources for a question, then call web_fetch on a \
         result's url to read it. Only your search query leaves the machine — never the user's private \
         data. `query` is required; `max_results` (default 5, max 10) caps the list.",
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
            let url = format!("https://html.duckduckgo.com/html/?q={}", q_encode(query));
            let client = match reqwest::blocking::Client::builder().timeout(Duration::from_secs(15)).build() {
                Ok(c) => c,
                Err(e) => return ToolResult::err(format!("client error: {e}")),
            };
            let body = match client
                .get(&url)
                .header("User-Agent", "Mozilla/5.0 (compatible; GINEXUS/0.1; +local-agent)")
                .send()
                .and_then(|r| r.error_for_status())
                .and_then(|r| r.text())
            {
                Ok(b) => b,
                Err(e) => return ToolResult::err(format!("search failed: {e}")),
            };
            let results = parse_ddg_results(&body, max);
            if results.is_empty() {
                return ToolResult::ok(json!({"results": [], "note": "no results"}).to_string());
            }
            let items: Vec<_> = results.iter().map(|(t, u)| json!({"title": t, "url": u})).collect();
            ToolResult::ok(json!({"results": items}).to_string())
        }),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percent_decode_and_strip_tags() {
        assert_eq!(percent_decode("https%3A%2F%2Fexample.com%2Fa+b"), "https://example.com/a b");
        assert_eq!(percent_decode("plain"), "plain");
        assert_eq!(strip_tags("<b>Hello</b>   <i>world</i>"), "Hello world");
        assert_eq!(q_encode("rust lang"), "rust+lang");
    }

    #[test]
    fn parses_ddg_html_and_drops_private_hosts() {
        // Two real-looking result anchors + one pointing at a private host (must be dropped).
        let html = r#"
          <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fdoc&rut=x">Example <b>Doc</b></a>
          <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Frust-lang.org%2F&rut=y">Rust Lang</a>
          <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=http%3A%2F%2F127.0.0.1%2Fx&rut=z">Loopback</a>
        "#;
        let r = parse_ddg_results(html, 10);
        assert_eq!(r.len(), 2, "private/loopback host must be dropped");
        assert_eq!(r[0].0, "Example Doc");
        assert_eq!(r[0].1, "https://example.com/doc");
        assert_eq!(r[1].1, "https://rust-lang.org/");
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
