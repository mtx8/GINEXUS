//! Generic MCP stdio SERVER — export any ToolRegistry to external MCP hosts (Claude Code,
//! Hermes, other agents) over newline-delimited JSON-RPC 2.0, protocol 2024-11-05.
//! This is the reusable half of the `--printful-mcp` pattern: the signed core binary runs a
//! subcommand (e.g. `--fab-mcp`) that serves a registry instead of the HTTP core.
//!
//! SAFETY: the HITL approval loop lives in the GINEXUS server, not here — so by default this
//! server only exposes a registry's NON-gated tools (`registry.readonly()` should be applied by
//! the caller when hard-gated physical actions must never be remotely reachable).

use self::io_util::write_msg;
use ginexus_agent::ToolRegistry;
use serde_json::{json, Value};
use std::io::{self, BufRead};

/// MCP tool definitions from a registry (OpenAI-style schema → MCP inputSchema).
fn tool_defs(registry: &ToolRegistry) -> Vec<Value> {
    registry
        .names()
        .iter()
        .filter_map(|n| registry.get(n))
        .map(|t| {
            let d = t.definition();
            json!({
                "name": d["function"]["name"],
                "description": d["function"]["description"],
                "inputSchema": d["function"]["parameters"],
            })
        })
        .collect()
}

/// Handle one JSON-RPC message; returns the response to write (None for notifications).
pub fn handle(msg: &Value, server_name: &str, registry: &ToolRegistry) -> Option<Value> {
    let method = msg.get("method").and_then(|m| m.as_str()).unwrap_or("");
    let id = msg.get("id").cloned();
    match method {
        "initialize" => Some(json!({"jsonrpc": "2.0", "id": id.unwrap_or(Value::Null), "result": {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": server_name, "version": env!("CARGO_PKG_VERSION")},
        }})),
        "notifications/initialized" => None,
        "tools/list" => Some(json!({"jsonrpc": "2.0", "id": id.unwrap_or(Value::Null),
                                    "result": {"tools": tool_defs(registry)}})),
        "tools/call" => {
            let params = msg.get("params").cloned().unwrap_or(json!({}));
            let name = params.get("name").and_then(|n| n.as_str()).unwrap_or("");
            let args = params.get("arguments").cloned().unwrap_or(json!({}));
            let id = id.unwrap_or(Value::Null);
            let Some(tool) = registry.get(name) else {
                return Some(json!({"jsonrpc": "2.0", "id": id, "result": {
                    "content": [{"type": "text", "text": format!("error: unknown tool '{name}'")}],
                    "isError": true}}));
            };
            let res = tool.run(args);
            Some(json!({"jsonrpc": "2.0", "id": id, "result": {
                "content": [{"type": "text", "text": res.output}],
                "isError": !res.ok}}))
        }
        _ => id.map(|id| json!({"jsonrpc": "2.0", "id": id,
                                "error": {"code": -32601, "message": "method not found"}})),
    }
}

/// Blocking stdio loop. Returns when stdin closes (the host exited).
pub fn serve(server_name: &str, registry: ToolRegistry) {
    let stdin = io::stdin();
    let mut out = io::stdout();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let Ok(msg) = serde_json::from_str::<Value>(&line) else { continue };
        if let Some(resp) = handle(&msg, server_name, &registry) {
            write_msg(&mut out, &resp);
        }
    }
}

/// Tiny shared writers (kept module-local to avoid a dep on the gateway's copy).
mod io_util {
    use serde_json::{json, Value};
    use std::io::Write;

    pub fn write_msg(out: &mut impl Write, msg: &Value) {
        let _ = writeln!(out, "{msg}");
        let _ = out.flush();
    }

    #[allow(dead_code)]
    pub fn respond(out: &mut impl Write, id: Value, result: Value) {
        write_msg(out, &json!({"jsonrpc": "2.0", "id": id, "result": result}));
    }

    #[allow(dead_code)]
    pub fn respond_err(out: &mut impl Write, id: Value, code: i64, message: &str) {
        write_msg(out, &json!({"jsonrpc": "2.0", "id": id,
                               "error": {"code": code, "message": message}}));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ginexus_agent::{Tool, ToolResult};
    use std::sync::Arc;

    fn registry() -> ToolRegistry {
        let mut reg = ToolRegistry::new();
        reg.register(Tool::new(
            "echo",
            "echo text back",
            json!({"type": "object", "properties": {"text": {"type": "string"}}}),
            false,
            Arc::new(|a: Value| {
                ToolResult::ok(a.get("text").and_then(|v| v.as_str()).unwrap_or("").to_string())
            }),
        ));
        reg
    }

    #[test]
    fn initialize_list_call() {
        let reg = registry();
        let init = handle(&json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}),
                          "test", &reg).unwrap();
        assert_eq!(init["result"]["protocolVersion"], "2024-11-05");
        assert_eq!(init["result"]["serverInfo"]["name"], "test");

        assert!(handle(&json!({"jsonrpc":"2.0","method":"notifications/initialized"}), "test", &reg)
            .is_none());

        let list = handle(&json!({"jsonrpc":"2.0","id":2,"method":"tools/list"}), "test", &reg)
            .unwrap();
        let tools = list["result"]["tools"].as_array().unwrap();
        assert_eq!(tools.len(), 1);
        assert_eq!(tools[0]["name"], "echo");
        assert_eq!(tools[0]["inputSchema"]["type"], "object");

        let call = handle(
            &json!({"jsonrpc":"2.0","id":3,"method":"tools/call",
                    "params":{"name":"echo","arguments":{"text":"hi mcp"}}}),
            "test", &reg,
        )
        .unwrap();
        assert_eq!(call["result"]["content"][0]["text"], "hi mcp");
        assert_eq!(call["result"]["isError"], false);

        let bad = handle(
            &json!({"jsonrpc":"2.0","id":4,"method":"tools/call",
                    "params":{"name":"nope","arguments":{}}}),
            "test", &reg,
        )
        .unwrap();
        assert_eq!(bad["result"]["isError"], true);

        let unknown = handle(&json!({"jsonrpc":"2.0","id":5,"method":"bogus"}), "test", &reg)
            .unwrap();
        assert_eq!(unknown["error"]["code"], -32601);
    }
}
