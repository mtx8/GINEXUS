//! SDCP V3.0.0 wire codec — sans-io. Message envelopes, command payloads, and status parsing
//! for the CBD-Tech / Elegoo Smart Device Control Protocol
//! (github.com/cbd-tech/SDCP-Smart-Device-Control-Protocol-V3.0.0, MIT).
//! Misspelled field names in the spec are LOAD-BEARING and preserved verbatim via serde renames
//! ("CurrenCoord", "RelaseFilmState"). Every enum keeps an Unknown catch-all because command and
//! status codes diverge per model (resin sub-status 0–10 vs Centauri dialect up to 20).

use crate::driver::{PrinterState, PrinterStatus};
use serde::Deserialize;
use serde_json::{json, Value};

/// UDP discovery: the client broadcasts this ASCII string to port 3000.
pub const DISCOVERY_MAGIC: &str = "M99999";
pub const DISCOVERY_PORT: u16 = 3000;
/// WebSocket control + HTTP upload port.
pub const CONTROL_PORT: u16 = 3030;
/// Upload chunk cap from the spec (1 MB).
pub const UPLOAD_CHUNK: usize = 1024 * 1024;

// Command codes (V3.0.0 spec §command list).
pub const CMD_STATUS: i64 = 0;
pub const CMD_ATTRIBUTES: i64 = 1;
pub const CMD_START_PRINT: i64 = 128;
pub const CMD_PAUSE_PRINT: i64 = 129;
pub const CMD_STOP_PRINT: i64 = 130;
pub const CMD_RESUME_PRINT: i64 = 131;
pub const CMD_FILE_LIST: i64 = 258;
pub const CMD_CAMERA: i64 = 386;

/// A printer's reply to the UDP discovery broadcast.
#[derive(Debug, Clone, Deserialize)]
pub struct DiscoveryReply {
    #[serde(default, rename = "Id")]
    pub id: String,
    #[serde(rename = "Data")]
    pub data: DiscoveryData,
}

#[derive(Debug, Clone, Deserialize)]
pub struct DiscoveryData {
    #[serde(default, rename = "Name")]
    pub name: String,
    #[serde(default, rename = "MachineName")]
    pub machine_name: String,
    #[serde(default, rename = "BrandName")]
    pub brand_name: String,
    #[serde(default, rename = "MainboardIP")]
    pub mainboard_ip: String,
    #[serde(default, rename = "MainboardID")]
    pub mainboard_id: String,
    #[serde(default, rename = "ProtocolVersion")]
    pub protocol_version: String,
    #[serde(default, rename = "FirmwareVersion")]
    pub firmware_version: String,
}

pub fn parse_discovery_reply(payload: &[u8]) -> Option<DiscoveryReply> {
    serde_json::from_slice(payload).ok()
}

/// Build a request frame for the WebSocket channel. `from` 0 = PC LAN client.
pub fn request_frame(
    mainboard_id: &str, connection_id: &str, request_id: &str, cmd: i64, data: Value,
    timestamp_ms: i64,
) -> Value {
    json!({
        "Id": connection_id,
        "Data": {
            "Cmd": cmd,
            "Data": data,
            "RequestID": request_id,
            "MainboardID": mainboard_id,
            "TimeStamp": timestamp_ms,
            "From": 0,
        },
        "Topic": format!("sdcp/request/{mainboard_id}"),
    })
}

/// Which topic family a received frame belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Topic {
    Response,
    Status,
    Attributes,
    Error,
    Notice,
    Other,
}

pub fn topic_of(frame: &Value) -> Topic {
    let t = frame.get("Topic").and_then(|v| v.as_str()).unwrap_or("");
    if t.starts_with("sdcp/response/") {
        Topic::Response
    } else if t.starts_with("sdcp/status/") {
        Topic::Status
    } else if t.starts_with("sdcp/attributes/") {
        Topic::Attributes
    } else if t.starts_with("sdcp/error/") {
        Topic::Error
    } else if t.starts_with("sdcp/notice/") {
        Topic::Notice
    } else {
        Topic::Other
    }
}

/// RequestID of a response frame (correlates to the request we sent).
pub fn response_request_id(frame: &Value) -> Option<&str> {
    frame.get("Data")?.get("RequestID")?.as_str()
}

/// Ack code of a response frame: `Data.Data.Ack` (0 = OK).
pub fn response_ack(frame: &Value) -> Option<i64> {
    frame.get("Data")?.get("Data")?.get("Ack")?.as_i64()
}

/// SDCP machine status codes (`Status.CurrentStatus` / print sub-status).
/// Resin V3: 0 Idle, 1 Homing, 2 Dropping, 3 Exposuring, 4 Lifting, 5 Pausing, 6 Paused,
/// 7 Stopping, 8 Stopped, 9 Complete, 10 File Checking. Centauri extends to 20 — anything
/// unmapped lands on Busy/Unknown rather than a wrong strong claim.
fn map_print_status(code: i64) -> PrinterState {
    match code {
        0 => PrinterState::Idle,
        1 | 2 | 3 | 4 | 10 => PrinterState::Printing,
        5 | 6 => PrinterState::Paused,
        7 => PrinterState::Stopping,
        8 => PrinterState::Idle, // stopped → back to idle for scheduling purposes
        9 => PrinterState::Complete,
        11..=20 => PrinterState::Printing, // Centauri dialect extensions (13 printing, 20 resuming…)
        _ => PrinterState::Unknown,
    }
}

/// Parse a `sdcp/status/…` frame into the normalized status. The payload shape is
/// `Data.Status{ CurrentStatus:[..]|int, PrintInfo{ Status, CurrentLayer, TotalLayer,
/// CurrentTicks, TotalTicks, Filename, ErrorNumber } }` — fields vary per model, so everything
/// is read defensively.
pub fn parse_status_frame(frame: &Value) -> Option<PrinterStatus> {
    let status = frame.get("Data")?.get("Status")?;
    let print_info = status.get("PrintInfo");

    // Machine-level status: array (multiple concurrent states) or scalar depending on firmware.
    let machine_codes: Vec<i64> = match status.get("CurrentStatus") {
        Some(Value::Array(a)) => a.iter().filter_map(|v| v.as_i64()).collect(),
        Some(Value::Number(n)) => n.as_i64().into_iter().collect(),
        _ => Vec::new(),
    };

    let print_code = print_info.and_then(|p| p.get("Status")).and_then(|v| v.as_i64());

    // Machine-level state (machine: 0 idle, 1 printing, 2 file transfer, 3 exposure test,
    // 4 devices testing).
    let machine_state = if machine_codes.contains(&1) {
        Some(PrinterState::Printing)
    } else if machine_codes.contains(&2) || machine_codes.contains(&3) || machine_codes.contains(&4)
    {
        Some(PrinterState::Busy)
    } else if !machine_codes.is_empty() {
        Some(PrinterState::Idle)
    } else {
        None
    };
    let sub_state = print_code.map(map_print_status);

    // Take the MORE-ACTIVE of the two: a busy machine (file transfer / exposure test) must never
    // read as Idle just because PrintInfo.Status is 0 — that would let the start-gate think an
    // occupied printer is free. Sub-status wins only when it is itself active.
    let state = match (sub_state, machine_state) {
        (Some(PrinterState::Idle) | Some(PrinterState::Unknown) | None, Some(m))
            if m != PrinterState::Idle =>
        {
            m
        }
        (Some(s), _) => s,
        (None, Some(m)) => m,
        (None, None) => PrinterState::Unknown,
    };

    let current_layer =
        print_info.and_then(|p| p.get("CurrentLayer")).and_then(|v| v.as_u64()).map(|v| v as u32);
    let total_layers =
        print_info.and_then(|p| p.get("TotalLayer")).and_then(|v| v.as_u64()).map(|v| v as u32);
    let (current_ticks, total_ticks) = (
        print_info.and_then(|p| p.get("CurrentTicks")).and_then(|v| v.as_u64()),
        print_info.and_then(|p| p.get("TotalTicks")).and_then(|v| v.as_u64()),
    );
    // Ticks are milliseconds of print time.
    let time_left_secs = match (current_ticks, total_ticks) {
        (Some(c), Some(t)) if t >= c => Some((t - c) / 1000),
        _ => None,
    };
    let progress = match (current_layer, total_layers) {
        (Some(c), Some(t)) if t > 0 => Some(f64::from(c) / f64::from(t)),
        _ => None,
    };
    let job_name = print_info
        .and_then(|p| p.get("Filename"))
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string());

    let elapsed_secs = current_ticks.map(|c| c / 1000);
    let error_number =
        print_info.and_then(|p| p.get("ErrorNumber")).and_then(|v| v.as_i64()).unwrap_or(0);
    let state = if error_number != 0 { PrinterState::Error } else { state };
    let detail =
        (error_number != 0).then(|| format!("printer error code {error_number}"));

    // Granular resin telemetry — real fields from the status payload (misspellings load-bearing).
    let mut extra = Vec::new();
    if let Some(rf) = status.get("RelaseFilmState").and_then(|v| v.as_i64()) {
        extra.push(crate::driver::Telemetry::new(
            "RELEASE FILM",
            if rf == 1 { "OK".to_string() } else { format!("state {rf}") },
        ));
    }
    if let Some(uv) = status.get("TempOfUVLED").and_then(|v| v.as_f64()) {
        extra.push(crate::driver::Telemetry::new("UV LED", format!("{uv:.0} °C")));
    }
    if let Some(box_temp) = status.get("TempOfBox").and_then(|v| v.as_f64()) {
        extra.push(crate::driver::Telemetry::new("CHAMBER", format!("{box_temp:.0} °C")));
    }
    if let Some(z) = print_info.and_then(|p| p.get("CurrenCoord")).and_then(|v| v.as_str()) {
        extra.push(crate::driver::Telemetry::new("Z COORD", z.to_string()));
    }
    if let Some(sw) = print_info.and_then(|p| p.get("PrintSpeedPct")).and_then(|v| v.as_i64()) {
        extra.push(crate::driver::Telemetry::new("SPEED", format!("{sw}%")));
    }

    Some(PrinterStatus {
        state,
        progress,
        current_layer,
        total_layers,
        time_left_secs,
        elapsed_secs,
        job_name,
        detail,
        extra,
    })
}

/// Payload for start-print. V3 firmwares require the storage prefix on the filename
/// (e.g. `/local/part.goo`) — a bare name fails on Saturn 4 Ultra.
pub fn start_print_data(storage: &str, filename: &str) -> Value {
    let full = if filename.starts_with('/') {
        filename.to_string()
    } else {
        format!("/{}/{}", storage.trim_matches('/'), filename)
    };
    json!({"Filename": full, "StartLayer": 0})
}

/// Extract the camera VideoUrl from a cmd-386 response, normalizing a missing scheme
/// (firmwares sometimes omit `rtsp://`).
pub fn camera_video_url(frame: &Value) -> Option<String> {
    let url = frame.get("Data")?.get("Data")?.get("VideoUrl")?.as_str()?.trim().to_string();
    if url.is_empty() {
        return None;
    }
    if url.contains("://") {
        Some(url)
    } else {
        Some(format!("rtsp://{url}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn discovery_reply_parses() {
        let payload = r#"{"Id":"aa","Data":{"Name":"Saturn4Ultra","MachineName":"ELEGOO Saturn 4 Ultra",
            "BrandName":"ELEGOO","MainboardIP":"192.168.1.44","MainboardID":"abc123",
            "ProtocolVersion":"V3.0.0","FirmwareVersion":"V1.2.3"}}"#;
        let r = parse_discovery_reply(payload.as_bytes()).expect("parse");
        assert_eq!(r.data.mainboard_ip, "192.168.1.44");
        assert_eq!(r.data.mainboard_id, "abc123");
        assert_eq!(r.data.protocol_version, "V3.0.0");
    }

    #[test]
    fn request_frame_shape() {
        let f = request_frame("mb1", "conn1", "req1", CMD_START_PRINT,
                              start_print_data("local", "part.goo"), 1234);
        assert_eq!(f["Topic"], "sdcp/request/mb1");
        assert_eq!(f["Data"]["Cmd"], 128);
        assert_eq!(f["Data"]["RequestID"], "req1");
        assert_eq!(f["Data"]["Data"]["Filename"], "/local/part.goo");
        assert_eq!(f["Data"]["Data"]["StartLayer"], 0);
        assert_eq!(f["Data"]["From"], 0);
    }

    #[test]
    fn start_print_keeps_absolute_paths() {
        assert_eq!(start_print_data("local", "/usb/x.goo")["Filename"], "/usb/x.goo");
    }

    #[test]
    fn topics_route() {
        let f = json!({"Topic": "sdcp/status/mb1"});
        assert_eq!(topic_of(&f), Topic::Status);
        assert_eq!(topic_of(&json!({"Topic": "sdcp/response/mb1"})), Topic::Response);
        assert_eq!(topic_of(&json!({"Topic": "sdcp/error/mb1"})), Topic::Error);
        assert_eq!(topic_of(&json!({})), Topic::Other);
    }

    #[test]
    fn status_frame_printing() {
        // Golden message shaped after the official spec example (misspellings intact).
        let f = json!({
            "Id": "aa", "Topic": "sdcp/status/mb1",
            "Data": {"MainboardID": "mb1", "Status": {
                "CurrentStatus": [1],
                "RelaseFilmState": 1,
                "PrintInfo": {
                    "Status": 3, "CurrentLayer": 120, "TotalLayer": 600,
                    "CurrentTicks": 600000, "TotalTicks": 3600000,
                    "Filename": "/local/part.goo", "ErrorNumber": 0
                }
            }}
        });
        let s = parse_status_frame(&f).expect("status");
        assert_eq!(s.state, PrinterState::Printing);
        assert_eq!(s.current_layer, Some(120));
        assert_eq!(s.total_layers, Some(600));
        assert_eq!(s.time_left_secs, Some(3000));
        assert!((s.progress.unwrap() - 0.2).abs() < 1e-9);
        assert_eq!(s.job_name.as_deref(), Some("/local/part.goo"));
    }

    #[test]
    fn busy_machine_overrides_idle_substatus() {
        // File transfer in progress (machine [2]) but PrintInfo.Status=0 → must NOT read Idle,
        // else the start-gate would think an occupied printer is free.
        let f = json!({"Data": {"Status": {
            "CurrentStatus": [2],
            "PrintInfo": {"Status": 0}
        }}});
        assert_eq!(parse_status_frame(&f).unwrap().state, PrinterState::Busy);
        // Truly idle (machine [0], no active sub-status) still reads Idle.
        let idle = json!({"Data": {"Status": {"CurrentStatus": [0], "PrintInfo": {"Status": 0}}}});
        assert_eq!(parse_status_frame(&idle).unwrap().state, PrinterState::Idle);
    }

    #[test]
    fn status_frame_error_and_paused() {
        let err = json!({"Data": {"Status": {"CurrentStatus": [1],
            "PrintInfo": {"Status": 3, "ErrorNumber": 1}}}});
        assert_eq!(parse_status_frame(&err).unwrap().state, PrinterState::Error);
        let paused = json!({"Data": {"Status": {"PrintInfo": {"Status": 6}}}});
        assert_eq!(parse_status_frame(&paused).unwrap().state, PrinterState::Paused);
        let idle = json!({"Data": {"Status": {"CurrentStatus": [0]}}});
        assert_eq!(parse_status_frame(&idle).unwrap().state, PrinterState::Idle);
    }

    #[test]
    fn camera_url_normalizes_scheme() {
        let f = json!({"Data": {"Data": {"VideoUrl": "192.168.1.44:554/video", "Ack": 0}}});
        assert_eq!(camera_video_url(&f).unwrap(), "rtsp://192.168.1.44:554/video");
        let f2 = json!({"Data": {"Data": {"VideoUrl": "http://192.168.1.44:3031/video"}}});
        assert_eq!(camera_video_url(&f2).unwrap(), "http://192.168.1.44:3031/video");
    }

    #[test]
    fn response_correlation() {
        let f = json!({"Topic": "sdcp/response/mb1",
                       "Data": {"RequestID": "r42", "Data": {"Ack": 0}}});
        assert_eq!(response_request_id(&f), Some("r42"));
        assert_eq!(response_ack(&f), Some(0));
    }
}
