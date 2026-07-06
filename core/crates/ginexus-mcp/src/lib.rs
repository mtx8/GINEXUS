//! GINEXUS MCP host (Rust core). A minimal MCP client over the stdio transport (newline-
//! delimited JSON-RPC 2.0): spawn an MCP server, `initialize`, `tools/list`, `tools/call`.
//! Discovered tools are imported into the agent's registry — DEFAULT-DENY: every imported
//! tool is HITL-gated (we don't know an external tool's side effects), per the OpenClaw lesson.
//! Calls are blocking (run on the agent loop's spawn_blocking pool).

pub mod server;

use ginexus_agent::{Tool, ToolRegistry, ToolResult};
use serde_json::{json, Value};
use std::io::{self, BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::{Arc, Mutex};

pub struct McpClient {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    next_id: i64,
}

impl McpClient {
    /// Spawn an MCP server (program + args) and perform the initialize handshake.
    pub fn spawn(program: &str, args: &[String]) -> io::Result<Self> {
        let mut child = Command::new(program)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let stdin = child.stdin.take().expect("stdin");
        let stdout = BufReader::new(child.stdout.take().expect("stdout"));
        let mut c = Self { child, stdin, stdout, next_id: 0 };
        c.initialize()?;
        Ok(c)
    }

    fn request(&mut self, method: &str, params: Value) -> io::Result<Value> {
        self.next_id += 1;
        let id = self.next_id;
        let req = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        writeln!(self.stdin, "{req}")?;
        self.stdin.flush()?;
        loop {
            let mut line = String::new();
            if self.stdout.read_line(&mut line)? == 0 {
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "mcp server closed"));
            }
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            if let Ok(v) = serde_json::from_str::<Value>(line) {
                if v.get("id").and_then(|i| i.as_i64()) == Some(id) {
                    return Ok(v);
                }
                // otherwise a notification / unrelated message → skip
            }
        }
    }

    fn notify(&mut self, method: &str, params: Value) -> io::Result<()> {
        let n = json!({"jsonrpc": "2.0", "method": method, "params": params});
        writeln!(self.stdin, "{n}")?;
        self.stdin.flush()
    }

    fn initialize(&mut self) -> io::Result<()> {
        self.request(
            "initialize",
            json!({"protocolVersion": "2024-11-05", "capabilities": {},
                   "clientInfo": {"name": "ginexus", "version": "0.1"}}),
        )?;
        self.notify("notifications/initialized", json!({}))?;
        Ok(())
    }

    pub fn list_tools(&mut self) -> io::Result<Vec<Value>> {
        let resp = self.request("tools/list", json!({}))?;
        Ok(resp
            .get("result")
            .and_then(|r| r.get("tools"))
            .and_then(|t| t.as_array())
            .cloned()
            .unwrap_or_default())
    }

    pub fn call_tool(&mut self, name: &str, arguments: Value) -> io::Result<String> {
        let resp = self.request("tools/call", json!({"name": name, "arguments": arguments}))?;
        if let Some(e) = resp.get("error") {
            return Ok(format!("error: {e}"));
        }
        let mut out = String::new();
        if let Some(items) = resp.get("result").and_then(|r| r.get("content")).and_then(|c| c.as_array()) {
            for it in items {
                if let Some(t) = it.get("text").and_then(|t| t.as_str()) {
                    out.push_str(t);
                }
            }
        }
        Ok(out)
    }
}

impl Drop for McpClient {
    fn drop(&mut self) {
        let _ = self.child.kill();
    }
}

/// Import an MCP server's tools into the registry, each prefixed (e.g. "mcp.fs.") and HITL-gated.
/// Returns the number of tools imported.
pub fn import_mcp_tools(
    client: Arc<Mutex<McpClient>>, registry: &mut ToolRegistry, prefix: &str,
) -> io::Result<usize> {
    let tools = client.lock().unwrap().list_tools()?;
    let mut count = 0;
    for t in tools {
        let remote = match t.get("name").and_then(|n| n.as_str()) {
            Some(n) => n.to_string(),
            None => continue,
        };
        let desc = t.get("description").and_then(|d| d.as_str()).unwrap_or("").to_string();
        let schema = t.get("inputSchema").cloned().unwrap_or_else(|| json!({"type": "object"}));
        let local_name = format!("{prefix}{remote}");
        let c = client.clone();
        let rname = remote.clone();
        registry.register(Tool::new(
            local_name,
            format!("[MCP] {desc}"),
            schema,
            true, // default-deny: imported MCP tools require approval on every call
            Arc::new(move |args: Value| match c.lock().unwrap().call_tool(&rname, args) {
                Ok(s) => ToolResult::ok(s),
                Err(e) => ToolResult::err(format!("mcp call failed: {e}")),
            }),
        ));
        count += 1;
    }
    Ok(count)
}

#[cfg(test)]
mod tests {
    use super::*;

    const MOCK: &str = r#"
import sys, json
def send(o):
    sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    msg = json.loads(line); m = msg.get("method"); i = msg.get("id")
    if m == "initialize":
        send({"jsonrpc":"2.0","id":i,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"mock","version":"0"}}})
    elif m == "notifications/initialized":
        pass
    elif m == "tools/list":
        send({"jsonrpc":"2.0","id":i,"result":{"tools":[{"name":"echo","description":"echo text","inputSchema":{"type":"object","properties":{"text":{"type":"string"}}}}]}})
    elif m == "tools/call":
        args = msg["params"].get("arguments", {})
        send({"jsonrpc":"2.0","id":i,"result":{"content":[{"type":"text","text":args.get("text","")}]}})
    elif i is not None:
        send({"jsonrpc":"2.0","id":i,"error":{"code":-32601,"message":"method not found"}})
"#;

    fn mock_server_path() -> std::path::PathBuf {
        use std::time::{SystemTime, UNIX_EPOCH};
        let n = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let p = std::env::temp_dir().join(format!("ginexus-mock-mcp-{}-{}.py", std::process::id(), n));
        std::fs::write(&p, MOCK).unwrap();
        p
    }

    #[test]
    fn handshake_list_and_call() {
        let path = mock_server_path();
        let mut c = McpClient::spawn("python3", &[path.to_string_lossy().to_string()]).unwrap();
        let tools = c.list_tools().unwrap();
        assert_eq!(tools.len(), 1);
        assert_eq!(tools[0]["name"], "echo");
        let out = c.call_tool("echo", json!({"text": "hello mcp"})).unwrap();
        assert_eq!(out, "hello mcp");
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn imports_tools_hitl_gated() {
        let path = mock_server_path();
        let client = Arc::new(Mutex::new(
            McpClient::spawn("python3", &[path.to_string_lossy().to_string()]).unwrap(),
        ));
        let mut reg = ToolRegistry::new();
        let n = import_mcp_tools(client, &mut reg, "mcp.test.").unwrap();
        assert_eq!(n, 1);
        let tool = reg.get("mcp.test.echo").expect("imported tool");
        assert!(tool.irreversible, "imported MCP tools must be HITL-gated (default-deny)");
        let res = tool.run(json!({"text": "via registry"}));
        assert!(res.ok && res.output == "via registry");
        std::fs::remove_file(&path).ok();
    }
}
