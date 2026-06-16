//! App-bridge tools (SP5). The Rust core advertises these OS tool *schemas* to the model, but
//! EXECUTION happens in the signed Swift app over a private UDS "app host" — so Calendar /
//! Shortcuts / system calls are TCC-attributed to the notarized app, never the core (the project's
//! hard rule). Registered only when the app injects `GINEXUS_APP_HOST_SOCK` + token; a headless
//! core (no app) simply omits them.
//!
//! Wire protocol (newline-delimited JSON over UDS, single request/response, connection-per-call):
//!   →  {"token","tool","args"}\n      ←  {"ok":bool,"output":string}\n
//! Irreversible tools (calendar_create, shortcuts_run) are HITL-gated by the core's approval flow
//! before they ever reach the app host.

use crate::{Tool, ToolResult};
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::time::Duration;

/// One blocking request to the app host (runs inside the agent loop's spawn_blocking).
fn call_app_host(sock: &str, token: &str, tool: &str, args: &Value) -> Result<String, String> {
    let mut stream =
        UnixStream::connect(sock).map_err(|e| format!("app host unreachable ({tool}): {e}"))?;
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));
    let _ = stream.set_read_timeout(Some(Duration::from_secs(30)));
    let req = json!({"token": token, "tool": tool, "args": args}).to_string();
    stream.write_all(req.as_bytes()).and_then(|_| stream.write_all(b"\n")).map_err(|e| format!("write: {e}"))?;
    let _ = stream.flush();

    let mut buf: Vec<u8> = Vec::new();
    let mut tmp = [0u8; 4096];
    loop {
        match stream.read(&mut tmp) {
            Ok(0) => break,
            Ok(n) => {
                buf.extend_from_slice(&tmp[..n]);
                if buf.contains(&b'\n') || buf.len() > 1_000_000 {
                    break;
                }
            }
            Err(e) => return Err(format!("read: {e}")),
        }
    }
    let line = String::from_utf8_lossy(&buf);
    let v: Value =
        serde_json::from_str(line.trim()).map_err(|e| format!("bad app host reply: {e}"))?;
    let output = v.get("output").and_then(|o| o.as_str()).unwrap_or("").to_string();
    if v.get("ok").and_then(|o| o.as_bool()).unwrap_or(false) {
        Ok(output)
    } else {
        Err(if output.is_empty() { "app tool failed".into() } else { output })
    }
}

fn bridge_tool(
    sock: Arc<String>, token: Arc<String>, name: &'static str, desc: &str, schema: Value,
    irreversible: bool,
) -> Tool {
    Tool::new(
        name,
        desc,
        schema,
        irreversible,
        Arc::new(move |a| match call_app_host(&sock, &token, name, &a) {
            Ok(out) => ToolResult::ok(out),
            Err(e) => ToolResult::err(e),
        }),
    )
}

/// The OS tools executed by the app host. `sock`/`token` come from the app via env.
pub fn app_tools(sock: String, token: String) -> Vec<Tool> {
    let sock = Arc::new(sock);
    let token = Arc::new(token);
    vec![
        bridge_tool(
            sock.clone(),
            token.clone(),
            "system_status",
            "Get this Mac's status: macOS version, battery %, light/dark appearance, and uptime.",
            json!({"type": "object", "properties": {}}),
            false,
        ),
        bridge_tool(
            sock.clone(),
            token.clone(),
            "calendar_list",
            "List the user's upcoming calendar events. `days` = how many days ahead to include \
             (default 1 = today).",
            json!({"type": "object", "properties": {"days": {"type": "integer"}}}),
            false,
        ),
        bridge_tool(
            sock.clone(),
            token.clone(),
            "calendar_create",
            "Create a calendar event. `title` and `start` (ISO-8601) required; optional `end` \
             (ISO-8601) and `notes`.",
            json!({"type": "object",
                   "properties": {"title": {"type": "string"}, "start": {"type": "string"},
                                  "end": {"type": "string"}, "notes": {"type": "string"}},
                   "required": ["title", "start"]}),
            true, // HITL-gated: writes to the user's calendar
        ),
        bridge_tool(
            sock.clone(),
            token.clone(),
            "shortcuts_list",
            "List the names of the user's installed macOS Shortcuts.",
            json!({"type": "object", "properties": {}}),
            false,
        ),
        bridge_tool(
            sock,
            token,
            "shortcuts_run",
            "Run a macOS Shortcut by exact name. Optional `input` text is passed to the shortcut.",
            json!({"type": "object",
                   "properties": {"name": {"type": "string"}, "input": {"type": "string"}},
                   "required": ["name"]}),
            true, // HITL-gated: a shortcut can do anything
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;

    // A mock app host: accepts one connection, echoes a canned ok/output. Proves the core side of
    // the bridge (connect → request line → response line) WITHOUT the Swift app / any TCC.
    #[test]
    fn bridge_roundtrips_to_a_mock_host() {
        let dir = std::env::temp_dir().join(format!("gx-apphost-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let sock = dir.join("host.sock");
        let _ = std::fs::remove_file(&sock);
        let listener = UnixListener::bind(&sock).unwrap();
        let sock_path = sock.to_string_lossy().to_string();

        let handle = std::thread::spawn(move || {
            let (mut conn, _) = listener.accept().unwrap();
            let mut buf = Vec::new();
            let mut tmp = [0u8; 1024];
            loop {
                let n = conn.read(&mut tmp).unwrap();
                buf.extend_from_slice(&tmp[..n]);
                if buf.contains(&b'\n') {
                    break;
                }
            }
            let req: Value = serde_json::from_str(String::from_utf8_lossy(&buf).trim()).unwrap();
            assert_eq!(req["tool"], "system_status");
            assert_eq!(req["token"], "tok123");
            conn.write_all(b"{\"ok\":true,\"output\":\"macOS 26.5; battery 88%; dark; up 3h\"}\n").unwrap();
        });

        let tools = app_tools(sock_path, "tok123".into());
        let sys = tools.iter().find(|t| t.name == "system_status").unwrap();
        assert!(!sys.irreversible);
        let r = sys.run(json!({}));
        assert!(r.ok);
        assert!(r.output.contains("battery 88%"));
        handle.join().unwrap();

        // calendar_create / shortcuts_run advertise as irreversible (HITL-gated)
        assert!(tools.iter().find(|t| t.name == "calendar_create").unwrap().irreversible);
        assert!(tools.iter().find(|t| t.name == "shortcuts_run").unwrap().irreversible);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn unreachable_host_errors_cleanly() {
        let tools = app_tools("/nonexistent/app.sock".into(), "t".into());
        let sys = tools.iter().find(|t| t.name == "system_status").unwrap();
        let r = sys.run(json!({}));
        assert!(!r.ok);
        assert!(r.output.contains("unreachable"));
    }
}
