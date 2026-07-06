//! SDCP V3 client — blocking transport over the sans-io codec. Design: SHORT-LIVED, per-call
//! WebSocket connections serialized by a per-printer mutex. Elegoo firmware caps concurrent
//! connections (~4) and idles sockets out (Centauri: 60 s), so transient connect→request→
//! response→close keeps us far from both limits and never holds stale state. A persistent
//! status-push actor is a documented R2 upgrade.

use super::codec::{self, DiscoveryReply};
use crate::driver::{
    CameraSource, Capabilities, FileRef, PrinterDriver, PrinterStatus,
};
use md5::{Digest, Md5};
use serde_json::Value;
use std::io::Read;
use std::net::{TcpStream, ToSocketAddrs, UdpSocket};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tungstenite::{Message, WebSocket};

static REQ_COUNTER: AtomicU64 = AtomicU64::new(1);

fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

/// Process-unique hex id (no uuid dep): time + pid + counter.
fn fresh_id(tag: &str) -> String {
    format!("{tag}{:x}{:x}{:x}", now_ms(), std::process::id(),
            REQ_COUNTER.fetch_add(1, Ordering::Relaxed))
}

/// Broadcast `M99999` and collect JSON replies until the timeout. Broadcast does not cross
/// subnets/VLANs — `probe()` (unicast) is the fallback for printers on another segment, and
/// manual IP entry is a first-class path in the UI (macOS Local Network privacy can silently
/// suppress broadcast replies if the permission was denied).
pub fn discover(timeout: Duration) -> Result<Vec<DiscoveryReply>, String> {
    let sock = UdpSocket::bind(("0.0.0.0", 0)).map_err(|e| format!("udp bind: {e}"))?;
    sock.set_broadcast(true).map_err(|e| format!("udp broadcast: {e}"))?;
    sock.send_to(codec::DISCOVERY_MAGIC.as_bytes(), ("255.255.255.255", codec::DISCOVERY_PORT))
        .map_err(|e| format!("udp send: {e}"))?;
    collect_replies(&sock, timeout)
}

/// Unicast the discovery magic at one host (works across routed segments where broadcast can't).
pub fn probe(host: &str, timeout: Duration) -> Result<Vec<DiscoveryReply>, String> {
    let sock = UdpSocket::bind(("0.0.0.0", 0)).map_err(|e| format!("udp bind: {e}"))?;
    sock.send_to(codec::DISCOVERY_MAGIC.as_bytes(), (host, codec::DISCOVERY_PORT))
        .map_err(|e| format!("udp send: {e}"))?;
    collect_replies(&sock, timeout)
}

fn collect_replies(sock: &UdpSocket, timeout: Duration) -> Result<Vec<DiscoveryReply>, String> {
    sock.set_read_timeout(Some(Duration::from_millis(250))).ok();
    let deadline = Instant::now() + timeout;
    let mut out: Vec<DiscoveryReply> = Vec::new();
    let mut buf = [0u8; 8192];
    while Instant::now() < deadline {
        match sock.recv_from(&mut buf) {
            Ok((n, _from)) => {
                if let Some(r) = codec::parse_discovery_reply(&buf[..n]) {
                    // Key printers by MainboardID, not IP.
                    if !out.iter().any(|o| o.data.mainboard_id == r.data.mainboard_id) {
                        out.push(r);
                    }
                }
            }
            Err(_) => continue, // read timeout tick — keep polling until the deadline
        }
    }
    Ok(out)
}

/// One SDCP printer (modern Elegoo resin fleet + Centauri dialect).
pub struct SdcpPrinter {
    host: String,
    mainboard_id: String,
    /// Serializes all transient connections — never more than ONE socket to a printer at a time.
    lock: Mutex<()>,
    /// Some Centauri variants answer on port 80 instead of 3030 — try both.
    ws_ports: Vec<u16>,
}

impl SdcpPrinter {
    pub fn new(host: impl Into<String>, mainboard_id: impl Into<String>) -> Self {
        Self {
            host: host.into(),
            mainboard_id: mainboard_id.into(),
            lock: Mutex::new(()),
            ws_ports: vec![codec::CONTROL_PORT, 80],
        }
    }

    /// Test-only: pin the WS port (the mock printer binds an ephemeral port).
    pub fn with_ports(mut self, ports: Vec<u16>) -> Self {
        self.ws_ports = ports;
        self
    }

    fn connect_ws(&self) -> Result<WebSocket<TcpStream>, String> {
        let mut last = String::from("no ports tried");
        for port in &self.ws_ports {
            // Bounded connect (tungstenite::connect has no timeout — an offline printer
            // would otherwise hang callers for the OS default ~75 s).
            let addr = match format!("{}:{}", self.host, port).to_socket_addrs() {
                Ok(mut a) => match a.next() {
                    Some(a) => a,
                    None => {
                        last = format!("{}:{}: no address", self.host, port);
                        continue;
                    }
                },
                Err(e) => {
                    last = format!("{}:{}: {e}", self.host, port);
                    continue;
                }
            };
            let stream = match TcpStream::connect_timeout(&addr, Duration::from_secs(3)) {
                Ok(s) => s,
                Err(e) => {
                    last = format!("{addr}: {e}");
                    continue;
                }
            };
            stream.set_read_timeout(Some(Duration::from_secs(6))).ok();
            let url = format!("ws://{}:{}/websocket", self.host, port);
            match tungstenite::client(url.as_str(), stream) {
                Ok((ws, _resp)) => return Ok(ws),
                Err(e) => last = format!("{url}: {e}"),
            }
        }
        Err(format!("cannot reach printer WebSocket ({last})"))
    }

    /// connect → send one request → wait for its response (and optionally the next status
    /// frame) → close. Returns (response, Option<status frame>).
    fn call(&self, cmd: i64, data: Value, want_status: bool) -> Result<(Value, Option<Value>), String> {
        let _g = self.lock.lock().map_err(|_| "printer lock poisoned".to_string())?;
        let mut ws = self.connect_ws()?;
        let request_id = fresh_id("r");
        let frame = codec::request_frame(
            &self.mainboard_id, &fresh_id("c"), &request_id, cmd, data, now_ms(),
        );
        ws.send(Message::Text(frame.to_string()))
            .map_err(|e| format!("ws send: {e}"))?;

        let deadline = Instant::now() + Duration::from_secs(8);
        let mut response: Option<Value> = None;
        let mut status: Option<Value> = None;
        while Instant::now() < deadline {
            let msg = match ws.read() {
                Ok(m) => m,
                Err(tungstenite::Error::Io(e))
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        || e.kind() == std::io::ErrorKind::TimedOut =>
                {
                    if response.is_some() && !want_status {
                        break;
                    }
                    continue;
                }
                Err(e) => return Err(format!("ws read: {e}")),
            };
            let text = match msg {
                Message::Text(t) => t,
                Message::Ping(p) => {
                    let _ = ws.send(Message::Pong(p));
                    continue;
                }
                Message::Close(_) => break,
                _ => continue,
            };
            if text == "pong" {
                continue;
            }
            let Ok(v) = serde_json::from_str::<Value>(&text) else { continue };
            match codec::topic_of(&v) {
                codec::Topic::Response
                    if codec::response_request_id(&v) == Some(request_id.as_str()) =>
                {
                    response = Some(v);
                    if !want_status || status.is_some() {
                        break;
                    }
                }
                codec::Topic::Status if want_status => {
                    status = Some(v);
                    if response.is_some() {
                        break;
                    }
                }
                _ => {}
            }
        }
        let _ = ws.close(None);
        let resp = response.ok_or_else(|| "printer did not answer the request".to_string())?;
        if let Some(ack) = codec::response_ack(&resp) {
            if ack != 0 {
                return Err(format!("printer refused the command (ack {ack})"));
            }
        }
        Ok((resp, status))
    }

    /// Chunked multipart upload per spec: ≤1 MB chunks, whole-file MD5 in `S-File-MD5`,
    /// constant Uuid across chunks, Offset/TotalSize per chunk.
    fn upload_file(&self, local_path: &Path) -> Result<FileRef, String> {
        let _g = self.lock.lock().map_err(|_| "printer lock poisoned".to_string())?;
        let name = local_path
            .file_name()
            .and_then(|n| n.to_str())
            .ok_or_else(|| "invalid file name".to_string())?
            .to_string();
        if !name.is_ascii() || name.contains(' ') {
            // Non-ASCII / spaced names choke some firmwares — refuse early with a clear message.
            return Err("printer filenames must be ASCII without spaces — rename the file".into());
        }
        let mut f = std::fs::File::open(local_path).map_err(|e| format!("open: {e}"))?;
        let total = f.metadata().map_err(|e| format!("stat: {e}"))?.len();
        if total == 0 {
            return Err("refusing to upload an empty file".into());
        }

        // Streaming MD5 pass.
        let mut hasher = Md5::new();
        let mut buf = vec![0u8; codec::UPLOAD_CHUNK];
        loop {
            let n = f.read(&mut buf).map_err(|e| format!("read: {e}"))?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
        }
        let md5 = hex::encode(hasher.finalize());

        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(60))
            .build()
            .map_err(|e| format!("http client: {e}"))?;
        let url = format!("http://{}:{}/uploadFile/upload", self.host, codec::CONTROL_PORT);
        let uuid = fresh_id("u");

        let mut f = std::fs::File::open(local_path).map_err(|e| format!("reopen: {e}"))?;
        let mut offset: u64 = 0;
        loop {
            let n = f.read(&mut buf).map_err(|e| format!("read: {e}"))?;
            if n == 0 {
                break;
            }
            let chunk = buf[..n].to_vec();
            let form = reqwest::blocking::multipart::Form::new()
                .text("Offset", offset.to_string())
                .text("Uuid", uuid.clone())
                .text("TotalSize", total.to_string())
                .text("Check", "1")
                .part(
                    "File",
                    reqwest::blocking::multipart::Part::bytes(chunk)
                        .file_name(name.clone()),
                );
            let resp = client
                .post(&url)
                .header("S-File-MD5", &md5)
                .header("Check", "1")
                .multipart(form)
                .send()
                .map_err(|e| format!("upload: {e}"))?;
            let status = resp.status();
            let body = resp.text().unwrap_or_default();
            if !status.is_success() {
                return Err(format!("upload chunk at offset {offset} failed: HTTP {status} — {body}"));
            }
            // The printer ALSO reports application errors in a 2xx body (SDCP upload codes: -1
            // offset error, -2 offset mismatch, -3 file open failed, -4 unknown). A status-only
            // check would report a corrupt/rejected upload as success, and the human would then
            // approve a print of a file the printer never accepted. Parse and enforce the body.
            if let Some(err) = upload_body_error(&body) {
                return Err(format!("printer rejected upload at offset {offset}: {err}"));
            }
            offset += n as u64;
        }
        Ok(FileRef::new("local", name))
    }
}

/// Inspect an SDCP upload response body for an application-level failure. Returns Some(reason)
/// when the printer signals rejection, None when the chunk was accepted (or the body is an
/// unrecognized-but-non-failing shape — we don't reject on unknown firmware output).
fn upload_body_error(body: &str) -> Option<String> {
    let v: Value = serde_json::from_str(body.trim()).ok()?;
    // Numeric ack/code fields: negative or non-"success" values are failures.
    for key in ["code", "Code", "ack", "Ack"] {
        if let Some(n) = v.get(key).and_then(|x| x.as_i64()) {
            if n < 0 {
                return Some(match n {
                    -1 => "offset error".into(),
                    -2 => "offset mismatch".into(),
                    -3 => "file open failed".into(),
                    _ => format!("error code {n}"),
                });
            }
        }
        // String codes: "000000" is the CBD-Tech success sentinel.
        if let Some(s) = v.get(key).and_then(|x| x.as_str()) {
            if !s.is_empty() && s != "000000" && s != "0" && !s.eq_ignore_ascii_case("success") {
                return Some(format!("code {s}"));
            }
        }
    }
    if v.get("success").and_then(|x| x.as_bool()) == Some(false) {
        return Some("printer reported success=false".into());
    }
    None
}

impl PrinterDriver for SdcpPrinter {
    fn kind(&self) -> &'static str {
        "sdcp"
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities { upload: true, start: true, pause: true, resume: true, cancel: true, camera: true }
    }

    fn status(&self) -> Result<PrinterStatus, String> {
        // cmd 0 acks, then the printer pushes a status-topic frame with the actual snapshot.
        match self.call(codec::CMD_STATUS, serde_json::json!({}), true) {
            Ok((_resp, Some(status_frame))) => codec::parse_status_frame(&status_frame)
                .ok_or_else(|| "unparseable status frame".to_string()),
            Ok((_resp, None)) => Err("printer acked but sent no status frame".into()),
            Err(e) if e.contains("cannot reach") => Ok(PrinterStatus::offline()),
            Err(e) => Err(e),
        }
    }

    fn upload(&self, local_path: &Path) -> Result<FileRef, String> {
        self.upload_file(local_path)
    }

    fn start(&self, file: &FileRef) -> Result<(), String> {
        let data = codec::start_print_data(&file.storage, &file.name);
        self.call(codec::CMD_START_PRINT, data, false).map(|_| ())
    }

    fn pause(&self) -> Result<(), String> {
        self.call(codec::CMD_PAUSE_PRINT, serde_json::json!({}), false).map(|_| ())
    }

    fn resume(&self) -> Result<(), String> {
        self.call(codec::CMD_RESUME_PRINT, serde_json::json!({}), false).map(|_| ())
    }

    fn cancel(&self) -> Result<(), String> {
        self.call(codec::CMD_STOP_PRINT, serde_json::json!({}), false).map(|_| ())
    }

    fn camera(&self) -> Result<CameraSource, String> {
        let (resp, _) = self.call(codec::CMD_CAMERA, serde_json::json!({"Enable": 1}), false)?;
        match codec::camera_video_url(&resp) {
            Some(url) if url.starts_with("rtsp") => Ok(CameraSource::RtspUrl { url }),
            Some(url) => Ok(CameraSource::MjpegUrl { url }),
            None => Ok(CameraSource::None),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::driver::PrinterState;
    use serde_json::json;
    use std::net::TcpListener;

    /// In-process mock SDCP printer: accepts ONE WebSocket connection per accept loop turn,
    /// answers status/start/pause per the V3 spec shapes (misspellings intact).
    fn spawn_mock_printer(mainboard_id: &'static str) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let mut ws = match tungstenite::accept(stream) {
                    Ok(w) => w,
                    Err(_) => continue,
                };
                // Serve one request per connection (matches the client's transient model).
                while let Ok(msg) = ws.read() {
                    let text = match msg {
                        Message::Text(t) => t,
                        Message::Close(_) => break,
                        _ => continue,
                    };
                    let Ok(v) = serde_json::from_str::<Value>(&text) else { continue };
                    let cmd = v["Data"]["Cmd"].as_i64().unwrap_or(-1);
                    let rid = v["Data"]["RequestID"].as_str().unwrap_or("").to_string();
                    let resp = json!({
                        "Id": "mock", "Topic": format!("sdcp/response/{mainboard_id}"),
                        "Data": {"Cmd": cmd, "RequestID": rid, "MainboardID": mainboard_id,
                                 "Data": {"Ack": 0}, "TimeStamp": 1}
                    });
                    let _ = ws.send(Message::Text(resp.to_string()));
                    if cmd == codec::CMD_STATUS {
                        let status = json!({
                            "Id": "mock", "Topic": format!("sdcp/status/{mainboard_id}"),
                            "Data": {"MainboardID": mainboard_id, "Status": {
                                "CurrentStatus": [1], "RelaseFilmState": 1,
                                "PrintInfo": {"Status": 3, "CurrentLayer": 50, "TotalLayer": 100,
                                              "CurrentTicks": 1000, "TotalTicks": 2000,
                                              "Filename": "/local/part.goo", "ErrorNumber": 0}
                            }}
                        });
                        let _ = ws.send(Message::Text(status.to_string()));
                    }
                }
            }
        });
        port
    }

    #[test]
    fn status_start_pause_against_mock() {
        let port = spawn_mock_printer("mb-test");
        let p = SdcpPrinter::new("127.0.0.1", "mb-test").with_ports(vec![port]);

        let s = p.status().expect("status");
        assert_eq!(s.state, PrinterState::Printing);
        assert_eq!(s.current_layer, Some(50));
        assert_eq!(s.total_layers, Some(100));
        assert!((s.progress.unwrap() - 0.5).abs() < 1e-9);

        p.start(&FileRef::new("local", "part.goo")).expect("start acked");
        p.pause().expect("pause acked");
        p.cancel().expect("cancel acked");
    }

    #[test]
    fn offline_printer_reports_offline_status() {
        // Nothing listens on this port.
        let p = SdcpPrinter::new("127.0.0.1", "mb-x").with_ports(vec![1]);
        let s = p.status().expect("offline maps to a status, not an error");
        assert_eq!(s.state, PrinterState::Offline);
        // But state-changing commands must surface the failure loudly.
        assert!(p.pause().is_err());
    }

    #[test]
    fn upload_body_error_detection() {
        // Documented SDCP failure codes are caught.
        assert!(upload_body_error(r#"{"code": -2}"#).is_some());
        assert!(upload_body_error(r#"{"Ack": -1}"#).is_some());
        assert!(upload_body_error(r#"{"code": "100001"}"#).is_some());
        assert!(upload_body_error(r#"{"success": false}"#).is_some());
        // Success shapes and unknown/empty bodies are accepted (don't over-reject firmware).
        assert!(upload_body_error(r#"{"code": "000000"}"#).is_none());
        assert!(upload_body_error(r#"{"ack": 0}"#).is_none());
        assert!(upload_body_error("").is_none());
        assert!(upload_body_error("OK").is_none());
    }

    #[test]
    fn upload_rejects_hostile_names() {
        let p = SdcpPrinter::new("127.0.0.1", "mb-x");
        let dir = std::env::temp_dir();
        let bad = dir.join("has space.goo");
        std::fs::write(&bad, b"x").unwrap();
        let err = p.upload(&bad).unwrap_err();
        assert!(err.contains("ASCII"), "got: {err}");
        let _ = std::fs::remove_file(&bad);
    }
}
