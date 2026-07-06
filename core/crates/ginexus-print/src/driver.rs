//! The unified printer driver layer. Every backend (SDCP resin/FDM, OctoPrint, Moonraker, mock)
//! maps its native vocabulary into ONE normalized state model so the agent, the job queue, and
//! the app UI never branch on printer brand. Drivers are BLOCKING by design — fab tools run on
//! the agent loop's spawn_blocking pool and the `--fab-mcp` server is a blocking stdio loop.
//! SDCP has zero authentication, so a driver must never assume it is the sole controller:
//! callers re-read status() immediately before any state-changing command.

use serde::{Deserialize, Serialize};
use std::path::Path;

/// Normalized printer state across all backends.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PrinterState {
    Offline,
    Idle,
    Busy,
    Printing,
    Paused,
    Stopping,
    Complete,
    Error,
    Unknown,
}

impl PrinterState {
    pub fn label(&self) -> &'static str {
        match self {
            PrinterState::Offline => "offline",
            PrinterState::Idle => "idle",
            PrinterState::Busy => "busy",
            PrinterState::Printing => "printing",
            PrinterState::Paused => "paused",
            PrinterState::Stopping => "stopping",
            PrinterState::Complete => "complete",
            PrinterState::Error => "error",
            PrinterState::Unknown => "unknown",
        }
    }
}

/// A labeled telemetry reading (e.g. "NOZZLE" → "210 °C"). Drivers fill `extra` with whatever
/// granular, REAL values they can read — no fabricated numbers (brand rule: real data or none).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Telemetry {
    pub label: String,
    pub value: String,
}

impl Telemetry {
    pub fn new(label: impl Into<String>, value: impl Into<String>) -> Self {
        Self { label: label.into(), value: value.into() }
    }
}

/// One normalized status snapshot.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrinterStatus {
    pub state: PrinterState,
    /// 0.0–1.0 when a job is active and the backend reports progress.
    pub progress: Option<f64>,
    pub current_layer: Option<u32>,
    pub total_layers: Option<u32>,
    pub time_left_secs: Option<u64>,
    /// Seconds elapsed on the current print, when reported.
    pub elapsed_secs: Option<u64>,
    /// Active job/file name if the backend reports one.
    pub job_name: Option<String>,
    /// Backend-specific detail worth surfacing verbatim (error text, notes).
    pub detail: Option<String>,
    /// Granular, driver-specific live readings (temps, Z-height, release-film state, fan, speed…).
    pub extra: Vec<Telemetry>,
}

impl PrinterStatus {
    pub fn offline() -> Self {
        Self {
            state: PrinterState::Offline,
            progress: None,
            current_layer: None,
            total_layers: None,
            time_left_secs: None,
            elapsed_secs: None,
            job_name: None,
            detail: None,
            extra: Vec::new(),
        }
    }

    /// A blank snapshot in a given state — the base every driver builds on.
    pub fn of(state: PrinterState) -> Self {
        Self { state, ..Self::offline() }
    }

    pub fn with_extra(mut self, label: impl Into<String>, value: impl Into<String>) -> Self {
        self.extra.push(Telemetry::new(label, value));
        self
    }
}

/// Where a file lives after upload — backends disagree on "location" semantics
/// (SDCP `/local/`, OctoPrint `local|sdcard`, Moonraker `gcodes` root).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileRef {
    pub storage: String,
    pub name: String,
}

impl FileRef {
    pub fn new(storage: impl Into<String>, name: impl Into<String>) -> Self {
        Self { storage: storage.into(), name: name.into() }
    }
}

/// Camera access is a DESCRIPTOR, never a stream — AVFoundation can render neither RTSP nor
/// multipart MJPEG, so the UI decides what to do with the URL (show, copy, hand to IINA/VLC).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum CameraSource {
    /// e.g. OctoPrint/Moonraker mjpg-streamer, SDCP Centauri MJPEG.
    MjpegUrl { url: String },
    /// SDCP resin models return an RTSP URL (nonstandard stream — warn the user).
    RtspUrl { url: String },
    /// Single-frame snapshot endpoint.
    SnapshotUrl { url: String },
    None,
}

/// What a backend can actually do — callers branch on capabilities, not on driver kind.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct Capabilities {
    pub upload: bool,
    pub start: bool,
    pub pause: bool,
    pub resume: bool,
    pub cancel: bool,
    pub camera: bool,
}

/// The driver contract. All methods are blocking; errors are user-presentable strings
/// (the tool layer forwards them verbatim to the agent).
pub trait PrinterDriver: Send + Sync {
    fn kind(&self) -> &'static str;
    fn capabilities(&self) -> Capabilities;
    fn status(&self) -> Result<PrinterStatus, String>;
    /// Upload a sliced file into printer storage. Does NOT start the print.
    fn upload(&self, local_path: &Path) -> Result<FileRef, String>;
    /// Start printing a previously uploaded file. HARD-GATED at the tool layer.
    fn start(&self, file: &FileRef) -> Result<(), String>;
    /// Pause is the SAFE action — always allowed autonomously.
    fn pause(&self) -> Result<(), String>;
    /// Resume is HARD-GATED at the tool layer (resin: no vat/plate/lid sensors).
    fn resume(&self) -> Result<(), String>;
    fn cancel(&self) -> Result<(), String>;
    fn camera(&self) -> Result<CameraSource, String>;
}
