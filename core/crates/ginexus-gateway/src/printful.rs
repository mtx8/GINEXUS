//! Printful MCP server — a self-contained, professional stdio MCP server wrapping the Printful API.
//!
//! Run as `ginexus-server --printful-mcp` (reuses the signed core binary; no extra binary to notarize).
//! Speaks newline-delimited JSON-RPC 2.0 (protocol 2024-11-05): `initialize` → `tools/list` →
//! `tools/call`, returning `{content:[{type:"text",text}]}` — exactly what `ginexus-mcp` (the host)
//! expects. Auth via the `PRINTFUL_TOKEN` env var (the app injects it from the Keychain). PSS: talks
//! ONLY to https://api.printful.com, never reads the filesystem or runs anything, output is capped, and
//! order writes (create/confirm) are clearly flagged so the GINEXUS host keeps them HITL-gated.

use serde_json::{json, Value};
use std::io::{self, BufRead, Write};
use std::time::Duration;

const API_BASE: &str = "https://api.printful.com";
const MAX_BODY: usize = 12_000; // cap API responses so a big catalog can't flood the model's context

/// Tool catalog advertised to the host. Read tools are safe; the two order-write tools are marked in
/// their descriptions (the host treats every MCP tool as default-deny + HITL regardless).
fn tool_defs() -> Value {
    json!([
        {
            "name": "store_info",
            "description": "Get the connected Printful store(s): id, name, type, and currency.",
            "inputSchema": {"type": "object", "properties": {}}
        },
        {
            "name": "list_store_products",
            "description": "List the sync products in your Printful store (your own catalog). \
                            Optional `offset` (default 0) and `limit` (1-100, default 20) for paging.",
            "inputSchema": {"type": "object", "properties": {
                "offset": {"type": "integer", "minimum": 0},
                "limit": {"type": "integer", "minimum": 1, "maximum": 100}}}
        },
        {
            "name": "get_store_product",
            "description": "Get one sync product and all its variants (sizes/colors, prices, files) by \
                            its sync-product `id`.",
            "inputSchema": {"type": "object", "properties": {"id": {"type": "integer"}}, "required": ["id"]}
        },
        {
            "name": "search_catalog",
            "description": "Browse Printful's blank-product CATALOG (t-shirts, mugs, posters, …) to pick \
                            a product to design on. Optional `category_id` to filter; returns id, type, \
                            brand, model, and available techniques.",
            "inputSchema": {"type": "object", "properties": {"category_id": {"type": "integer"}}}
        },
        {
            "name": "get_catalog_variant",
            "description": "Get a catalog variant (a specific size/color of a blank product) by `id` — \
                            price, color, size, and the catalog product it belongs to.",
            "inputSchema": {"type": "object", "properties": {"id": {"type": "integer"}}, "required": ["id"]}
        },
        {
            "name": "list_orders",
            "description": "List Printful orders. Optional `status` (draft|pending|failed|canceled|\
                            onhold|inprocess|partial|fulfilled), `offset` (default 0), `limit` (1-100, \
                            default 20).",
            "inputSchema": {"type": "object", "properties": {
                "status": {"type": "string"},
                "offset": {"type": "integer", "minimum": 0},
                "limit": {"type": "integer", "minimum": 1, "maximum": 100}}}
        },
        {
            "name": "get_order",
            "description": "Get a single Printful order (items, recipient, costs, shipping, status) by `id`.",
            "inputSchema": {"type": "object", "properties": {"id": {"type": "integer"}}, "required": ["id"]}
        },
        {
            "name": "estimate_shipping",
            "description": "Estimate shipping rates for a recipient + items WITHOUT creating an order. \
                            `recipient` = {address1, city, country_code, zip, state_code?}; `items` = \
                            array of {variant_id, quantity}.",
            "inputSchema": {"type": "object", "properties": {
                "recipient": {"type": "object"},
                "items": {"type": "array", "items": {"type": "object"}}},
                "required": ["recipient", "items"]}
        },
        {
            "name": "create_draft_order",
            "description": "Create a DRAFT Printful order (NOT charged or fulfilled until confirmed). \
                            `recipient` = {name, address1, city, state_code, country_code, zip}; `items` \
                            = array of {sync_variant_id|variant_id, quantity, files?:[{url}]}. WRITE \
                            action — requires the user's approval.",
            "inputSchema": {"type": "object", "properties": {
                "recipient": {"type": "object"},
                "items": {"type": "array", "items": {"type": "object"}},
                "external_id": {"type": "string"}},
                "required": ["recipient", "items"]}
        },
        {
            "name": "confirm_order",
            "description": "Confirm a draft Printful order by `id` for fulfillment. This CHARGES your \
                            account and starts production — irreversible. WRITE action — requires the \
                            user's explicit approval.",
            "inputSchema": {"type": "object", "properties": {"id": {"type": "integer"}}, "required": ["id"]}
        }
    ])
}

/// HTTP verbs we use against the Printful API.
enum Verb {
    Get,
    Post,
}

/// Call the Printful API with bearer auth and return the (truncated) response body. The bearer token
/// comes from the env (injected from the Keychain) — never logged, never on disk here.
fn api(verb: Verb, path: &str, body: Option<Value>) -> Result<String, String> {
    let token = std::env::var("PRINTFUL_TOKEN")
        .ok()
        .filter(|t| !t.trim().is_empty())
        .ok_or("PRINTFUL_TOKEN is not set — connect Printful in Settings → Connections first")?;
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(25))
        .build()
        .map_err(|e| format!("client error: {e}"))?;
    let url = format!("{API_BASE}{path}");
    let mut req = match verb {
        Verb::Get => client.get(&url),
        Verb::Post => client.post(&url),
    }
    .bearer_auth(token.trim())
    .header("User-Agent", "GINEXUS-Printful-MCP/1.0");
    if let Some(b) = body {
        req = req.json(&b);
    }
    let resp = req.send().map_err(|e| format!("request failed: {e}"))?;
    let status = resp.status();
    let mut text = resp.text().unwrap_or_default();
    if text.len() > MAX_BODY {
        text.truncate(MAX_BODY);
        text.push_str("…[truncated]");
    }
    if status.is_success() {
        Ok(text)
    } else {
        // Surface Printful's own error message (it returns JSON {code,result,error:{message}}).
        Err(format!("Printful API {status}: {text}"))
    }
}

fn paging(args: &Value, default_limit: i64) -> String {
    let offset = args.get("offset").and_then(|v| v.as_i64()).unwrap_or(0).max(0);
    let limit = args.get("limit").and_then(|v| v.as_i64()).unwrap_or(default_limit).clamp(1, 100);
    format!("offset={offset}&limit={limit}")
}

/// Dispatch a `tools/call`. Returns the text payload (the API JSON) or an error string.
fn call_tool(name: &str, args: &Value) -> Result<String, String> {
    match name {
        "store_info" => api(Verb::Get, "/stores", None),
        "list_store_products" => api(Verb::Get, &format!("/store/products?{}", paging(args, 20)), None),
        "get_store_product" => {
            let id = args.get("id").and_then(|v| v.as_i64()).ok_or("`id` (integer) is required")?;
            api(Verb::Get, &format!("/store/products/{id}"), None)
        }
        "search_catalog" => {
            let path = match args.get("category_id").and_then(|v| v.as_i64()) {
                Some(c) => format!("/products?category_id={c}"),
                None => "/products".to_string(),
            };
            api(Verb::Get, &path, None)
        }
        "get_catalog_variant" => {
            let id = args.get("id").and_then(|v| v.as_i64()).ok_or("`id` (integer) is required")?;
            api(Verb::Get, &format!("/products/variant/{id}"), None)
        }
        "list_orders" => {
            let mut q = paging(args, 20);
            if let Some(s) = args.get("status").and_then(|v| v.as_str()).filter(|s| !s.is_empty()) {
                q.push_str(&format!("&status={s}"));
            }
            api(Verb::Get, &format!("/orders?{q}"), None)
        }
        "get_order" => {
            let id = args.get("id").and_then(|v| v.as_i64()).ok_or("`id` (integer) is required")?;
            api(Verb::Get, &format!("/orders/{id}"), None)
        }
        "estimate_shipping" => {
            let body = json!({
                "recipient": args.get("recipient").cloned().unwrap_or(json!({})),
                "items": args.get("items").cloned().unwrap_or(json!([]))
            });
            api(Verb::Post, "/shipping/rates", Some(body))
        }
        "create_draft_order" => {
            // confirm=false → stays a draft until confirm_order. The host gates this behind approval.
            let mut order = json!({
                "recipient": args.get("recipient").cloned().unwrap_or(json!({})),
                "items": args.get("items").cloned().unwrap_or(json!([]))
            });
            if let Some(ext) = args.get("external_id").and_then(|v| v.as_str()) {
                order["external_id"] = json!(ext);
            }
            api(Verb::Post, "/orders?confirm=false", Some(order))
        }
        "confirm_order" => {
            let id = args.get("id").and_then(|v| v.as_i64()).ok_or("`id` (integer) is required")?;
            api(Verb::Post, &format!("/orders/{id}/confirm"), None)
        }
        other => Err(format!("unknown tool '{other}'")),
    }
}

fn write_msg(out: &mut impl Write, msg: &Value) {
    let _ = writeln!(out, "{msg}");
    let _ = out.flush();
}

fn respond(out: &mut impl Write, id: Value, result: Value) {
    write_msg(out, &json!({"jsonrpc": "2.0", "id": id, "result": result}));
}

fn respond_err(out: &mut impl Write, id: Value, code: i64, message: &str) {
    write_msg(out, &json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}));
}

/// The blocking JSON-RPC-over-stdio event loop. Returns when stdin closes (the host exited).
pub fn run_stdio() {
    let stdin = io::stdin();
    let mut out = io::stdout();
    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break,
        };
        if line.trim().is_empty() {
            continue;
        }
        let msg: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => continue, // ignore malformed lines rather than crash the server
        };
        let method = msg.get("method").and_then(|m| m.as_str()).unwrap_or("");
        let id = msg.get("id").cloned();
        match method {
            "initialize" => respond(
                &mut out,
                id.unwrap_or(Value::Null),
                json!({"protocolVersion": "2024-11-05",
                       "capabilities": {"tools": {}},
                       "serverInfo": {"name": "printful", "version": "1.0.0"}}),
            ),
            // Notifications carry no id and get no response.
            "notifications/initialized" => {}
            "tools/list" => respond(&mut out, id.unwrap_or(Value::Null), json!({"tools": tool_defs()})),
            "tools/call" => {
                let params = msg.get("params").cloned().unwrap_or(json!({}));
                let name = params.get("name").and_then(|n| n.as_str()).unwrap_or("");
                let args = params.get("arguments").cloned().unwrap_or(json!({}));
                let id = id.unwrap_or(Value::Null);
                match call_tool(name, &args) {
                    Ok(text) => respond(&mut out, id, json!({"content": [{"type": "text", "text": text}]})),
                    Err(e) => respond(
                        &mut out,
                        id,
                        json!({"content": [{"type": "text", "text": format!("error: {e}")}], "isError": true}),
                    ),
                }
            }
            _ => {
                if let Some(id) = id {
                    respond_err(&mut out, id, -32601, "method not found");
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn advertises_the_full_tool_set() {
        let defs = tool_defs();
        let names: Vec<&str> =
            defs.as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap()).collect();
        for expected in [
            "store_info", "list_store_products", "get_store_product", "search_catalog",
            "get_catalog_variant", "list_orders", "get_order", "estimate_shipping",
            "create_draft_order", "confirm_order",
        ] {
            assert!(names.contains(&expected), "missing tool {expected}");
        }
        // Every tool advertises an object inputSchema (host requirement).
        for t in defs.as_array().unwrap() {
            assert_eq!(t["inputSchema"]["type"], "object");
        }
    }

    #[test]
    fn paging_clamps_and_defaults() {
        assert_eq!(paging(&json!({}), 20), "offset=0&limit=20");
        assert_eq!(paging(&json!({"offset": 5, "limit": 50}), 20), "offset=5&limit=50");
        assert_eq!(paging(&json!({"limit": 999}), 20), "offset=0&limit=100"); // clamped
        assert_eq!(paging(&json!({"offset": -3}), 20), "offset=0&limit=20"); // floored
    }

    // One test owns PRINTFUL_TOKEN end-to-end — separate tests would race on the shared env var.
    #[test]
    fn token_gate_then_dispatch() {
        // No token → a clean "connect first" error from any tool.
        std::env::remove_var("PRINTFUL_TOKEN");
        let err = call_tool("store_info", &json!({})).unwrap_err();
        assert!(err.contains("PRINTFUL_TOKEN"), "got: {err}");
        // With a token set, dispatch is reached → unknown tool is reported as such.
        std::env::set_var("PRINTFUL_TOKEN", "x");
        let err = call_tool("nope", &json!({})).unwrap_err();
        assert!(err.contains("unknown tool"));
        std::env::remove_var("PRINTFUL_TOKEN");
    }
}
