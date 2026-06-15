//! GINEXUS core server (Rust). UDS-only + per-launch bearer token, fail-closed on missing
//! HMAC keys. Minimal HTTP/1.1 (the Swift UDSClient uses Connection: close). Routes:
//!   GET  /healthz
//!   POST /v1/chat                      {model?, messages}            → SSE
//!   POST /v1/agent                     {model?, messages, grants?}   → JSON (HITL-gated loop)
//!   GET  /v1/admin/killswitch          → {engaged, tier, boot_id}
//!   POST /v1/admin/killswitch/engage   {tier, reason}
//!   POST /v1/admin/killswitch/reset    {token, nonce, expiry_ms, boot_id, reason}  (approval-gated)

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use ginexus_agent::{AgentLoop, AgentStatus, ApprovalGrant, ToolRegistry};
use ginexus_gateway::{BoundModel, Gateway};
use ginexus_security::approval::ApprovalVerifier;
use ginexus_security::audit::AuditLog;
use ginexus_security::hitl::HitlPolicy;
use ginexus_security::killswitch::{KillSwitch, Tier};
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{UnixListener, UnixStream};

const VERSION: &str = env!("CARGO_PKG_VERSION");

struct AppState {
    token: String,
    boot_id: String,
    gateway: Gateway,
    registry: ToolRegistry,
    hitl: HitlPolicy,
    audit: AuditLog,
    approvals: ApprovalVerifier,
    killswitch: Mutex<KillSwitch>,
}

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

fn rand_hex(n: usize) -> String {
    // 16 bytes of OS entropy → hex; no extra crate.
    let mut buf = vec![0u8; n];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        use std::io::Read;
        let _ = f.read_exact(&mut buf);
    }
    hex::encode(buf)
}

fn key_from_env(name: &str) -> Option<Vec<u8>> {
    let h = std::env::var(name).ok()?;
    let k = hex::decode(h).ok()?;
    if k.len() >= 32 {
        Some(k)
    } else {
        None
    }
}

fn state_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(home).join("Library/Application Support/GINEXUS")
}

#[tokio::main]
async fn main() {
    let mut args = std::env::args().skip(1);
    let mut uds = state_dir().join("run/ginexus.sock");
    while let Some(a) = args.next() {
        if a == "--uds" {
            if let Some(p) = args.next() {
                uds = PathBuf::from(p);
            }
        }
    }

    // FAIL CLOSED: the core refuses to serve without its HMAC keys (no forgeable audit, no
    // unauthenticated reset). The signed launcher injects these like the bearer token.
    let token = match std::env::var("GINEXUS_TOKEN") {
        Ok(t) if !t.is_empty() => t,
        _ => {
            eprintln!("FATAL: GINEXUS_TOKEN not set");
            std::process::exit(78);
        }
    };
    let (audit_key, approval_key) = match (key_from_env("GINEXUS_AUDIT_KEY"), key_from_env("GINEXUS_APPROVAL_KEY")) {
        (Some(a), Some(b)) => (a, b),
        _ => {
            eprintln!("FATAL: GINEXUS_AUDIT_KEY and GINEXUS_APPROVAL_KEY (>=256-bit hex) must be injected");
            std::process::exit(78);
        }
    };

    let boot_id = rand_hex(8);
    let sd = state_dir();
    let _ = std::fs::create_dir_all(sd.join("run"));
    let audit = AuditLog::new(sd.join("audit/audit.jsonl"), audit_key);
    // verify-on-boot: a prior anchor must still be an ancestor of the live chain.
    if let Some(prior) = audit.read_anchor(&sd.join("audit")) {
        if !audit.verify(None) || !audit.contains_hash(&prior) {
            eprintln!("FATAL: audit integrity check failed (rollback/tamper)");
            std::process::exit(70);
        }
    }
    let _ = audit.write_anchor(&sd.join("audit"));
    let _ = audit.record("server_start", json!({"engine": "rust", "boot_id": boot_id}));

    let approvals = ApprovalVerifier::new(approval_key, boot_id.clone()).expect("approval key");
    let mut registry = ginexus_agent::tools::notes_registry(sd.join("notes"));
    registry.register(ginexus_gateway::web::web_fetch_tool()); // SP4: read-only web research
    let state = Arc::new(AppState {
        token,
        boot_id,
        gateway: Gateway::default_local(),
        registry,
        hitl: HitlPolicy::new(),
        audit,
        approvals,
        killswitch: Mutex::new(KillSwitch::new(Some(sd.join("run/killswitch.state")))),
    });

    // 0600 UDS, no TCP. Create/bind/chmod before listen — never world-accessible.
    if uds.exists() {
        let _ = std::fs::remove_file(&uds);
    }
    if let Some(parent) = uds.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let listener = UnixListener::bind(&uds).expect("bind uds");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&uds, std::fs::Permissions::from_mode(0o600));
    }
    eprintln!("ginexus-server (rust) listening on {} (boot {})", uds.display(), state.boot_id);

    loop {
        match listener.accept().await {
            Ok((stream, _)) => {
                let st = state.clone();
                tokio::spawn(async move {
                    let _ = handle_conn(stream, st).await;
                });
            }
            Err(e) => eprintln!("accept error: {e}"),
        }
    }
}

struct Request {
    method: String,
    path: String,
    bearer: Option<String>,
    body: Vec<u8>,
}

async fn read_request(stream: &mut UnixStream) -> Option<Request> {
    let mut buf: Vec<u8> = Vec::new();
    let mut tmp = [0u8; 8192];
    let header_end = loop {
        if let Some(pos) = find(&buf, b"\r\n\r\n") {
            break pos + 4;
        }
        let n = stream.read(&mut tmp).await.ok()?;
        if n == 0 {
            return None;
        }
        buf.extend_from_slice(&tmp[..n]);
        if buf.len() > 8 * 1024 * 1024 {
            return None; // header too large
        }
    };
    let head = String::from_utf8_lossy(&buf[..header_end]).to_string();
    let mut lines = head.split("\r\n");
    let req_line = lines.next()?;
    let mut parts = req_line.split_whitespace();
    let method = parts.next()?.to_string();
    let path = parts.next()?.to_string();
    let mut content_length = 0usize;
    let mut bearer = None;
    for line in lines {
        if let Some((k, v)) = line.split_once(':') {
            let k = k.trim().to_ascii_lowercase();
            let v = v.trim();
            if k == "content-length" {
                content_length = v.parse().unwrap_or(0);
            } else if k == "authorization" {
                if let Some(t) = v.strip_prefix("Bearer ") {
                    bearer = Some(t.trim().to_string());
                }
            }
        }
    }
    let mut body = buf[header_end..].to_vec();
    while body.len() < content_length {
        let n = stream.read(&mut tmp).await.ok()?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&tmp[..n]);
    }
    body.truncate(content_length);
    Some(Request { method, path, bearer, body })
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

async fn write_response(stream: &mut UnixStream, code: u16, reason: &str, content_type: &str, body: &str) {
    let resp = format!(
        "HTTP/1.1 {code} {reason}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.as_bytes().len()
    );
    let _ = stream.write_all(resp.as_bytes()).await;
    let _ = stream.flush().await;
    let _ = stream.shutdown().await;
}

async fn json_ok(stream: &mut UnixStream, v: Value) {
    write_response(stream, 200, "OK", "application/json", &v.to_string()).await;
}
async fn err(stream: &mut UnixStream, code: u16, reason: &str, detail: &str) {
    write_response(stream, code, reason, "application/json", &json!({"detail": detail}).to_string()).await;
}

async fn handle_conn(mut stream: UnixStream, state: Arc<AppState>) -> std::io::Result<()> {
    let req = match read_request(&mut stream).await {
        Some(r) => r,
        None => return Ok(()),
    };
    let body: Value = serde_json::from_slice(&req.body).unwrap_or(json!({}));

    // /healthz is unauthenticated; everything else requires the bearer token.
    if !(req.method == "GET" && req.path == "/healthz") {
        let ok = req.bearer.as_deref().map(|t| ct_eq(t, &state.token)).unwrap_or(false);
        if !ok {
            err(&mut stream, 401, "Unauthorized", "unauthorized").await;
            return Ok(());
        }
    }

    match (req.method.as_str(), req.path.as_str()) {
        ("GET", "/healthz") => {
            json_ok(&mut stream, json!({"status": "ready", "engine": "rust", "version": VERSION})).await;
        }
        ("POST", "/v1/chat") => {
            let blocked = state.killswitch.lock().unwrap().guard().err();
            if let Some(e) = blocked {
                err(&mut stream, 503, "Service Unavailable", &e.to_string()).await;
                return Ok(());
            }
            let model = body.get("model").and_then(|m| m.as_str()).unwrap_or("fast");
            let messages = body.get("messages").and_then(|m| m.as_array()).cloned().unwrap_or_default();
            match state.gateway.chat(model, &messages).await {
                Ok(content) => {
                    let _ = state.audit.record("chat", json!({"model": model, "out_len": content.len()}));
                    let sse = format!("data: {}\n\ndata: [DONE]\n\n", content.replace('\n', " "));
                    write_response(&mut stream, 200, "OK", "text/event-stream", &sse).await;
                }
                Err(e) => err(&mut stream, 502, "Bad Gateway", &e).await,
            }
        }
        ("POST", "/v1/agent") => {
            let blocked = state.killswitch.lock().unwrap().guard().err();
            if let Some(e) = blocked {
                err(&mut stream, 503, "Service Unavailable", &e.to_string()).await;
                return Ok(());
            }
            let model = body.get("model").and_then(|m| m.as_str()).unwrap_or("fast").to_string();
            let messages = body.get("messages").and_then(|m| m.as_array()).cloned().unwrap_or_default();
            let grants = parse_grants(&body);
            let bound = BoundModel { gateway: &state.gateway, model };
            let agent = AgentLoop { model: &bound, registry: &state.registry, hitl: &state.hitl, max_iters: 6 };
            let res = agent.run(messages, &grants, Some(&state.approvals), now_ms()).await;
            let status = match res.status {
                AgentStatus::Final => "final",
                AgentStatus::PendingApproval => "pending_approval",
                AgentStatus::MaxIters => "max_iters",
            };
            let _ = state.audit.record("agent", json!({"status": status}));
            json_ok(&mut stream, json!({"status": status, "answer": res.answer, "pending": res.pending,
                                        "trace": res.trace.iter().map(|(n, ok)| json!([n, ok])).collect::<Vec<_>>()})).await;
        }
        ("GET", "/v1/admin/killswitch") => {
            let (engaged, tier) = {
                let ks = state.killswitch.lock().unwrap();
                (ks.engaged(), ks.tier().map(|t| t.as_str()))
            };
            json_ok(&mut stream, json!({"engaged": engaged, "tier": tier, "boot_id": state.boot_id})).await;
        }
        ("POST", "/v1/admin/killswitch/engage") => {
            let tier = body.get("tier").and_then(|t| t.as_str()).and_then(Tier::parse);
            let reason = body.get("reason").and_then(|r| r.as_str()).unwrap_or("");
            match tier {
                Some(t) => {
                    let eff = state.killswitch.lock().unwrap().engage(t, reason);
                    let _ = state.audit.record("kill_switch", json!({"tier": eff.as_str(), "reason": reason}));
                    json_ok(&mut stream, json!({"engaged": true, "tier": eff.as_str()})).await;
                }
                None => err(&mut stream, 400, "Bad Request", "unknown tier").await,
            }
        }
        ("POST", "/v1/admin/killswitch/reset") => {
            let nonce = body.get("nonce").and_then(|n| n.as_str()).unwrap_or("");
            let token = body.get("token").and_then(|t| t.as_str()).unwrap_or("");
            let expiry_ms = body.get("expiry_ms").and_then(|e| e.as_i64()).unwrap_or(0);
            let boot_id = body.get("boot_id").and_then(|b| b.as_str()).unwrap_or("");
            let reason = body.get("reason").and_then(|r| r.as_str()).unwrap_or("");
            match state.approvals.verify(token, "killswitch.reset", &json!({}), "killswitch", nonce, expiry_ms, boot_id, now_ms()) {
                Ok(()) => {
                    let (engaged, tier) = {
                        let mut ks = state.killswitch.lock().unwrap();
                        let _ = ks.reset(true);
                        (ks.engaged(), ks.tier().map(|t| t.as_str()))
                    };
                    let _ = state.audit.record("kill_switch", json!({"state": "reset", "reason": reason}));
                    json_ok(&mut stream, json!({"engaged": engaged, "tier": tier})).await;
                }
                Err(e) => err(&mut stream, 403, "Forbidden", &format!("approval rejected: {e}")).await,
            }
        }
        _ => err(&mut stream, 404, "Not Found", "no such route").await,
    }
    Ok(())
}

fn parse_grants(body: &Value) -> Vec<ApprovalGrant> {
    body.get("grants")
        .and_then(|g| g.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|g| {
                    Some(ApprovalGrant {
                        action: g.get("action")?.as_str()?.to_string(),
                        args: g.get("args")?.clone(),
                        target: g.get("target")?.as_str()?.to_string(),
                        token: g.get("token")?.as_str()?.to_string(),
                        nonce: g.get("nonce")?.as_str()?.to_string(),
                        expiry_ms: g.get("expiry_ms")?.as_i64()?,
                        boot_id: g.get("boot_id")?.as_str()?.to_string(),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Constant-time string compare for the bearer token.
fn ct_eq(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}
