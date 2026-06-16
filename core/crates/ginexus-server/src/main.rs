//! GINEXUS core server (Rust). UDS-only + per-launch bearer token, fail-closed on missing
//! HMAC keys. Minimal HTTP/1.1 (the Swift UDSClient uses Connection: close). Routes:
//!   GET  /healthz
//!   GET  /v1/models                    → {default, models:[{id,model,label}]} (selector roster)
//!   POST /v1/chat        {model?, difficulty?, latency_sensitive?, messages}  → SSE
//!   POST /v1/agent       {model?, difficulty?, messages, grants?}             → JSON (HITL loop)
//!   POST /v1/ingest      {data|path, include_assistant?}  → import export → quarantined memory
//!   POST /v1/schedule    {prompt, every_secs?}  → create an unattended scheduled task (heartbeat)
//!   GET  /v1/schedule    → list schedules + last results
//!   POST /v1/schedule/remove {id}  → remove a schedule
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
use ginexus_memory::MemoryStore;
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{UnixListener, UnixStream};

mod scheduler;

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
    memory: Arc<MemoryStore>,
    schedules: scheduler::ScheduleStore,
}

/// Prepend the core-memory system preamble (if any) so the model always has persistent context.
fn with_memory(memory: &MemoryStore, mut messages: Vec<Value>) -> Vec<Value> {
    let pre = memory.system_preamble();
    if !pre.is_empty() {
        messages.insert(0, json!({"role": "system", "content": pre}));
    }
    messages
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
    let memory = Arc::new(MemoryStore::open(sd.join("memory")));
    let mut registry = ginexus_agent::tools::notes_registry(sd.join("notes"));
    registry.register(ginexus_gateway::web::web_fetch_tool()); // SP4: read-only web research
    // SP6: local image generation — registered only when the app launched the media sidecar and
    // injected its base URL. Generation is autonomous (writes only into the media dir).
    if let Ok(base) = std::env::var("GINEXUS_MEDIA_BASE") {
        if !base.is_empty() {
            registry.register(ginexus_gateway::media::image_generate_tool(base));
            let _ = std::fs::create_dir_all(sd.join("media"));
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(sd.join("media"), std::fs::Permissions::from_mode(0o700));
            }
            eprintln!("registered image_generate tool (media sidecar)");
        }
    }
    for t in ginexus_memory::memory_tools(memory.clone()) { // SP3: remember/recall/set/get memory
        registry.register(t);
    }
    registry.register(ginexus_memory::ingest::ingest_tool(memory.clone())); // SP3: import exports (HITL)
    registry.register(ginexus_agent::tools::terminal_tool(   // SP4: HITL-gated safe terminal
        sd.join("workspace"),
        ["ls", "cat", "echo", "date", "pwd", "head", "tail", "wc", "uname"]
            .iter().map(|s| s.to_string()).collect(),
    ));
    // MCP host: import an external MCP server's tools (default-deny / HITL-gated) when configured.
    if let Ok(cmd) = std::env::var("GINEXUS_MCP_CMD") {
        let parts: Vec<String> = cmd.split_whitespace().map(String::from).collect();
        if let Some((prog, rest)) = parts.split_first() {
            match ginexus_mcp::McpClient::spawn(prog, rest) {
                Ok(client) => {
                    let client = Arc::new(Mutex::new(client));
                    match ginexus_mcp::import_mcp_tools(client, &mut registry, "mcp.") {
                        Ok(n) => eprintln!("imported {n} MCP tools from '{cmd}'"),
                        Err(e) => eprintln!("MCP import failed: {e}"),
                    }
                }
                Err(e) => eprintln!("MCP spawn failed for '{cmd}': {e}"),
            }
        }
    }
    // SP-Skills: hot-loadable modular skills (the core runs with zero skills installed). Loads
    // command tools + MCP-server skills from the skills dir; drop a folder in, restart, gain tools.
    let skills_dir = std::env::var("GINEXUS_SKILLS_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| sd.join("skills"));
    let _ = std::fs::create_dir_all(&skills_dir);
    let skills_work = sd.join("skills-workspace");
    let _ = std::fs::create_dir_all(&skills_work);
    // Executables allowed to run UNATTENDED: the core-vouched defaults + operator additions (never
    // a skill manifest). Everything else is HITL regardless of what the manifest declares.
    let mut auto_allow = ginexus_skills::default_auto_allow();
    if let Ok(extra) = std::env::var("GINEXUS_SKILLS_AUTO_ALLOW") {
        auto_allow.extend(extra.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()));
    }
    let loaded = ginexus_skills::load_skills(&skills_dir, &skills_work, &auto_allow);
    for t in loaded.command_tools {
        // Don't let a skill shadow a trusted built-in tool name.
        if registry.get(&t.name).is_some() {
            eprintln!("skill tool '{}' shadows a built-in — skipped", t.name);
        } else {
            registry.register(t);
        }
    }
    for sk in &loaded.mcp_skills {
        if let Some((prog, rest)) = sk.run.split_first() {
            match ginexus_mcp::McpClient::spawn(prog, rest) {
                Ok(client) => {
                    let client = Arc::new(Mutex::new(client));
                    match ginexus_mcp::import_mcp_tools(client, &mut registry, &format!("{}.", sk.name)) {
                        Ok(n) => eprintln!("skill '{}': imported {n} MCP tools", sk.name),
                        Err(e) => eprintln!("skill '{}' MCP import failed: {e}", sk.name),
                    }
                }
                Err(e) => eprintln!("skill '{}' MCP spawn failed: {e}", sk.name),
            }
        }
    }
    if !loaded.summary.is_empty() {
        eprintln!("loaded skills [{}]: {}", skills_dir.display(), loaded.summary.join(", "));
    }

    // SP5: OS-bridge tools (Calendar/Shortcuts/system) — registered ONLY when the signed app
    // injects its tool-host socket + token. Execution runs in the app (TCC attribution); the core
    // advertises schemas and forwards calls. A headless core (no app) omits them.
    if let (Ok(sock), Ok(tok)) =
        (std::env::var("GINEXUS_APP_HOST_SOCK"), std::env::var("GINEXUS_APP_HOST_TOKEN"))
    {
        if !sock.is_empty() && !tok.is_empty() {
            for t in ginexus_agent::app_tools::app_tools(sock, tok) {
                registry.register(t);
            }
            eprintln!("registered OS-bridge tools (app host)");
        }
    }

    // Model roster: data-driven from GINEXUS_MODELS_CONFIG (JSON), else the built-in local stack
    // (fast=Qwen3-1.7B, smart=Qwen3-30B-A3B). Selection (auto/manual) happens per request.
    let gateway = match std::env::var("GINEXUS_MODELS_CONFIG") {
        Ok(p) if !p.is_empty() => match Gateway::from_config_file(std::path::Path::new(&p)) {
            Ok(g) => {
                eprintln!("models: loaded roster from {p}");
                g
            }
            Err(e) => {
                eprintln!("models: config load failed ({e}); using default_local");
                Gateway::default_local()
            }
        },
        _ => Gateway::default_local(),
    };

    // Semantic memory: install an embedder backed by the gateway's "embed" tier so recall matches
    // by MEANING (cosine over vectors), falling back to keyword if the embed model is unavailable.
    {
        let ep = gateway.resolve("embed");
        let (base, key, model) = (ep.api_base.clone(), ep.api_key.clone(), ep.model.clone());
        memory.set_embedder(std::sync::Arc::new(move |t: &str| {
            ginexus_gateway::embed_text(&base, &key, &model, t).ok()
        }));
    }

    let state = Arc::new(AppState {
        token,
        boot_id,
        gateway,
        registry,
        hitl: HitlPolicy::new(),
        audit,
        approvals,
        killswitch: Mutex::new(KillSwitch::new(Some(sd.join("run/killswitch.state")))),
        memory,
        schedules: scheduler::ScheduleStore::open(sd.join("run/schedules.json")),
    });

    // Heartbeat: run due scheduled tasks unattended (read-only tools, kill-switch-respecting).
    {
        let st = state.clone();
        tokio::spawn(async move { heartbeat(st).await });
    }

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
        ("POST", "/v1/schedule") => {
            // Create an unattended scheduled task. First run fires on the next heartbeat tick.
            let prompt = body.get("prompt").and_then(|p| p.as_str()).unwrap_or("").to_string();
            let every = body.get("every_secs").and_then(|e| e.as_i64()).unwrap_or(3600);
            match state.schedules.add(prompt, every, now_ms(), rand_hex(6)) {
                Ok(s) => {
                    let _ = state.audit.record("schedule_add", json!({"id": s.id, "every_secs": s.every_secs}));
                    json_ok(&mut stream, json!({"id": s.id, "prompt": s.prompt,
                                                "every_secs": s.every_secs, "next_run_ms": s.next_run_ms})).await;
                }
                Err(e) => err(&mut stream, 400, "Bad Request", &e).await,
            }
        }
        ("GET", "/v1/schedule") => {
            let items: Vec<Value> = state
                .schedules
                .list()
                .into_iter()
                .map(|s| json!({"id": s.id, "prompt": s.prompt, "every_secs": s.every_secs,
                                "runs": s.runs, "last_run_ms": s.last_run_ms, "next_run_ms": s.next_run_ms,
                                "last_result": s.last_result}))
                .collect();
            json_ok(&mut stream, json!({"schedules": items})).await;
        }
        ("POST", "/v1/schedule/remove") => {
            let id = body.get("id").and_then(|i| i.as_str()).unwrap_or("");
            json_ok(&mut stream, json!({"removed": state.schedules.remove(id)})).await;
        }
        ("GET", "/v1/models") => {
            // Roster for the app's model picker. "auto" is the implicit policy-routed default.
            let models: Vec<Value> = state
                .gateway
                .roster()
                .into_iter()
                .map(|(k, e)| json!({"id": k, "model": e.model, "label": e.label}))
                .collect();
            json_ok(&mut stream, json!({"default": "auto", "models": models})).await;
        }
        ("POST", "/v1/chat") => {
            let blocked = state.killswitch.lock().unwrap().guard().err();
            if let Some(e) = blocked {
                err(&mut stream, 503, "Service Unavailable", &e.to_string()).await;
                return Ok(());
            }
            // Auto/manual model selection: model absent/"auto" → policy route; else explicit tier.
            let requested = body.get("model").and_then(|m| m.as_str());
            let difficulty = body.get("difficulty").and_then(|d| d.as_str()).unwrap_or("normal");
            let latency = body.get("latency_sensitive").and_then(|l| l.as_bool()).unwrap_or(false);
            let model = state.gateway.select(requested, "chat", difficulty, latency);
            let messages = with_memory(&state.memory,
                body.get("messages").and_then(|m| m.as_array()).cloned().unwrap_or_default());
            match state.gateway.chat(&model, &messages).await {
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
            // Agent work defaults to the strong model (task "reason"); explicit pick still wins.
            let requested = body.get("model").and_then(|m| m.as_str());
            let difficulty = body.get("difficulty").and_then(|d| d.as_str()).unwrap_or("normal");
            let model = state.gateway.select(requested, "reason", difficulty, false);
            let messages = with_memory(&state.memory,
                body.get("messages").and_then(|m| m.as_array()).cloned().unwrap_or_default());
            let grants = parse_grants(&body);
            let bound = BoundModel { gateway: &state.gateway, model };
            let agent = AgentLoop { model: &bound, registry: &state.registry, hitl: &state.hitl, max_iters: 6, depth: 0 };
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
        ("POST", "/v1/ingest") => {
            // Import a sanitized personal-data export into quarantined memory. The signed app
            // reads the file under its own TCC and posts the bytes as `data`; `path` is for
            // non-TCC/CLI use. Always loaded Origin::Untrusted (data, never instructions).
            let include = body.get("include_assistant").and_then(|b| b.as_bool()).unwrap_or(false);
            let json = if let Some(d) = body.get("data").and_then(|d| d.as_str()) {
                d.to_string()
            } else if let Some(p) = body.get("path").and_then(|p| p.as_str()) {
                match std::fs::read_to_string(p) {
                    Ok(s) => s,
                    Err(e) => {
                        err(&mut stream, 400, "Bad Request", &format!("read {p}: {e}")).await;
                        return Ok(());
                    }
                }
            } else {
                err(&mut stream, 400, "Bad Request", "provide 'data' (export JSON) or 'path'").await;
                return Ok(());
            };
            match ginexus_memory::ingest::ingest_str(&state.memory, &json, include) {
                Ok(rep) => {
                    let _ = state.audit.record(
                        "ingest",
                        json!({"source": rep.source, "facts": rep.facts_loaded, "skipped": rep.skipped}),
                    );
                    json_ok(&mut stream, json!({"source": rep.source, "conversations": rep.conversations,
                                                "facts_loaded": rep.facts_loaded, "skipped": rep.skipped})).await;
                }
                Err(e) => err(&mut stream, 400, "Bad Request", &e).await,
            }
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

/// Background heartbeat: every tick, run any due scheduled tasks unattended. Scheduled tasks get
/// the READ-ONLY toolset (no irreversible/HITL actions without a human) + can delegate to workers,
/// respect the kill switch, and persist their last result.
async fn heartbeat(state: Arc<AppState>) {
    let tick = std::time::Duration::from_secs(10);
    loop {
        tokio::time::sleep(tick).await;
        let blocked = state.killswitch.lock().unwrap().guard().is_err();
        if blocked {
            continue;
        }
        for (id, prompt) in state.schedules.take_due(now_ms()) {
            let readonly = state.registry.readonly();
            let model = state.gateway.select(None, "reason", "normal", false);
            let bound = BoundModel { gateway: &state.gateway, model };
            let agent =
                AgentLoop { model: &bound, registry: &readonly, hitl: &state.hitl, max_iters: 6, depth: 0 };
            let msgs = with_memory(&state.memory, vec![json!({"role": "user", "content": prompt})]);
            let res = agent.run(msgs, &[], None, now_ms()).await;
            let _ = state.audit.record(
                "schedule_run",
                json!({"id": id, "status": format!("{:?}", res.status), "out_len": res.answer.len()}),
            );
            state.schedules.record_result(&id, now_ms(), &res.answer);
        }
    }
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
