//! The fab agent tools — the ONLY way the agent touches printers. Safety doctrine (SP-FAB spec):
//! resin printers have no vat/plate/lid sensors, so anything that makes UV light or motion
//! happen on stale assumptions is gated:
//!   autonomous  — discover, list, status, analyze, slice/validate (file-producing), pause, camera
//!   irreversible— upload, remove printer, cancel (HITL-gated in HITL mode)
//!   HARD GATE   — start, resume, clear-job (approval even in fully-autonomous mode; clear-job
//!                 asserts the PHYSICAL fact "a human removed the part" — an agent may never
//!                 assert that on its own)
//! SDCP has zero auth: every state-changing tool re-reads live printer status first and refuses
//! on conflict — this process is never assumed to be the sole controller.

use crate::driver::{PrinterState, PrinterStatus};
use crate::jobs::{JobQueue, JobState};
use crate::pipeline;
use crate::registry::{PrinterConfig, PrinterRegistry};
use crate::sdcp::client as sdcp;
use ginexus_agent::{abbreviate_home, Tool, ToolResult};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub struct FabState {
    pub printers: Mutex<PrinterRegistry>,
    pub jobs: Mutex<JobQueue>,
    /// Where sliced artifacts land: `<state>/fab/work`.
    pub workspace: PathBuf,
    /// One LIVE driver per printer id — required for correctness, not just speed: the SDCP
    /// driver serializes its transient connections behind a per-instance lock, and the mock
    /// keeps its print state in memory. Invalidated on printer removal.
    drivers: Mutex<std::collections::HashMap<String, Arc<dyn crate::driver::PrinterDriver>>>,
}

impl FabState {
    pub fn open(state_dir: &Path) -> Arc<Self> {
        let fab = state_dir.join("fab");
        let workspace = fab.join("work");
        let _ = std::fs::create_dir_all(&workspace);
        Arc::new(Self {
            printers: Mutex::new(PrinterRegistry::open(fab.clone())),
            jobs: Mutex::new(JobQueue::open(fab)),
            workspace,
            drivers: Mutex::new(std::collections::HashMap::new()),
        })
    }

    pub fn driver_for(
        &self, cfg: &PrinterConfig,
    ) -> Result<Arc<dyn crate::driver::PrinterDriver>, String> {
        let mut cache = self.drivers.lock().unwrap();
        if let Some(d) = cache.get(&cfg.id) {
            return Ok(d.clone());
        }
        let d: Arc<dyn crate::driver::PrinterDriver> = Arc::from(cfg.driver()?);
        cache.insert(cfg.id.clone(), d.clone());
        Ok(d)
    }

    fn drop_driver(&self, id: &str) {
        self.drivers.lock().unwrap().remove(id);
    }

    /// Live status for one configured printer (offline on connect failure, error on bad config).
    pub fn live_status(&self, printer_id: &str) -> Result<(PrinterConfig, PrinterStatus), String> {
        let cfg = self
            .printers
            .lock()
            .unwrap()
            .get(printer_id)
            .cloned()
            .ok_or_else(|| format!("no printer '{printer_id}' — fab_list_printers shows the fleet"))?;
        let status = self.driver_for(&cfg)?.status()?;
        Ok((cfg, status))
    }
}

fn is_icloud(p: &str) -> bool {
    p.contains("Mobile Documents") || p.contains("com~apple~CloudDocs")
}

fn resolve_model_path(raw: &str) -> Result<PathBuf, String> {
    let expanded = if let Some(rest) = raw.strip_prefix('~') {
        match std::env::var("HOME") {
            Ok(h) => format!("{h}{rest}"),
            Err(_) => raw.to_string(),
        }
    } else {
        raw.to_string()
    };
    if is_icloud(&expanded) {
        return Err("refusing an iCloud path — keep model files local".into());
    }
    let p = PathBuf::from(&expanded);
    if !p.exists() {
        return Err(format!("file not found: {}", abbreviate_home(&expanded)));
    }
    Ok(p)
}

fn arg_str(a: &Value, k: &str) -> String {
    a.get(k).and_then(|v| v.as_str()).unwrap_or("").trim().to_string()
}

fn status_json(cfg: &PrinterConfig, s: &PrinterStatus) -> Value {
    json!({
        "printer_id": cfg.id, "name": cfg.name, "kind": cfg.kind, "model": cfg.model,
        "state": s.state.label(), "progress": s.progress,
        "current_layer": s.current_layer, "total_layers": s.total_layers,
        "time_left_secs": s.time_left_secs, "job_name": s.job_name, "detail": s.detail,
    })
}

/// Build the full fab tool set over shared state.
pub fn fab_tools(state: Arc<FabState>) -> Vec<Tool> {
    let mut tools = Vec::new();

    // ── fab_discover_printers ────────────────────────────────────────────────
    let st = state.clone();
    tools.push(Tool::new(
        "fab_discover_printers",
        "Find 3D printers on the local network (Elegoo/Chitu SDCP: Saturn, Mars, Centauri). \
         Optional `host` probes one IP directly (use when broadcast finds nothing — VLANs and \
         macOS Local Network permission can block broadcast). Returns name/model/IP/board id. \
         Found printers are NOT added automatically — call fab_add_printer.",
        json!({"type": "object", "properties": {
            "host": {"type": "string", "description": "optional single IP to probe"},
            "timeout_secs": {"type": "integer", "description": "listen window, default 3"}}}),
        false,
        Arc::new(move |a: Value| {
            let _ = &st; // fleet config not needed; discovery is stateless
            let timeout =
                Duration::from_secs(a.get("timeout_secs").and_then(|v| v.as_u64()).unwrap_or(3).clamp(1, 15));
            let host = arg_str(&a, "host");
            let found = if host.is_empty() { sdcp::discover(timeout) } else { sdcp::probe(&host, timeout) };
            match found {
                Ok(list) if list.is_empty() => ToolResult::ok(
                    "no printers answered. Check: printer on the same network/VLAN, macOS Local \
                     Network permission granted to GINEXUS, or probe a known IP with `host`.",
                ),
                Ok(list) => {
                    let rows: Vec<Value> = list.iter().map(|r| json!({
                        "name": r.data.name, "model": r.data.machine_name, "brand": r.data.brand_name,
                        "ip": r.data.mainboard_ip, "mainboard_id": r.data.mainboard_id,
                        "protocol": r.data.protocol_version, "firmware": r.data.firmware_version,
                    })).collect();
                    ToolResult::ok(serde_json::to_string_pretty(&rows).unwrap_or_default())
                }
                Err(e) => ToolResult::err(e),
            }
        }),
    ));

    // ── fab_add_printer ──────────────────────────────────────────────────────
    let st = state.clone();
    tools.push(Tool::new(
        "fab_add_printer",
        "Register a printer in the GINEXUS fleet. kind = 'sdcp' (Elegoo resin/Centauri), \
         'octoprint', 'moonraker', or 'mock' (simulator). host = IP or base URL (empty for mock). \
         For octoprint/moonraker pass api_key_env = name of the env var holding the API key \
         (never the key itself). model drives the slicing format (e.g. 'ELEGOO Saturn 4 Ultra').",
        json!({"type": "object", "properties": {
            "name": {"type": "string"}, "kind": {"type": "string"}, "host": {"type": "string"},
            "model": {"type": "string"}, "mainboard_id": {"type": "string"},
            "api_key_env": {"type": "string"}},
            "required": ["name", "kind"]}),
        false,
        Arc::new(move |a: Value| {
            let cfg = PrinterConfig {
                id: String::new(),
                name: arg_str(&a, "name"),
                kind: arg_str(&a, "kind"),
                host: arg_str(&a, "host"),
                mainboard_id: arg_str(&a, "mainboard_id"),
                model: arg_str(&a, "model"),
                api_key_env: arg_str(&a, "api_key_env"),
            };
            match st.printers.lock().unwrap().add(cfg) {
                Ok(id) => ToolResult::ok(format!("printer registered with id '{id}'")),
                Err(e) => ToolResult::err(e),
            }
        }),
    ));

    // ── fab_remove_printer ───────────────────────────────────────────────────
    let st = state.clone();
    tools.push(Tool::new(
        "fab_remove_printer",
        "Remove a printer from the fleet by id.",
        json!({"type": "object", "properties": {"printer_id": {"type": "string"}},
               "required": ["printer_id"]}),
        true,
        Arc::new(move |a: Value| {
            let id = arg_str(&a, "printer_id");
            st.drop_driver(&id);
            if st.printers.lock().unwrap().remove(&id) {
                ToolResult::ok(format!("printer '{id}' removed"))
            } else {
                ToolResult::err(format!("no printer '{id}'"))
            }
        }),
    ));

    // ── fab_list_printers ────────────────────────────────────────────────────
    let st = state.clone();
    tools.push(Tool::new(
        "fab_list_printers",
        "List the configured printer fleet (id, name, kind, host, model). Use \
         fab_printer_status for live state.",
        json!({"type": "object", "properties": {}}),
        false,
        Arc::new(move |_a: Value| {
            let reg = st.printers.lock().unwrap();
            let rows: Vec<Value> = reg.list().iter().map(|p| json!({
                "printer_id": p.id, "name": p.name, "kind": p.kind,
                "host": p.host, "model": p.model,
            })).collect();
            if rows.is_empty() {
                ToolResult::ok("no printers configured yet — fab_discover_printers, then fab_add_printer")
            } else {
                ToolResult::ok(serde_json::to_string_pretty(&rows).unwrap_or_default())
            }
        }),
    ));

    // ── fab_printer_status ───────────────────────────────────────────────────
    let st = state.clone();
    tools.push(Tool::new(
        "fab_printer_status",
        "Live status of one printer: state (idle/printing/paused/error/offline), progress, \
         layer n/N, time left, active job.",
        json!({"type": "object", "properties": {"printer_id": {"type": "string"}},
               "required": ["printer_id"]}),
        false,
        Arc::new(move |a: Value| {
            match st.live_status(&arg_str(&a, "printer_id")) {
                Ok((cfg, s)) => ToolResult::ok(
                    serde_json::to_string_pretty(&status_json(&cfg, &s)).unwrap_or_default(),
                ),
                Err(e) => ToolResult::err(e),
            }
        }),
    ));

    // ── fab_analyze_model ────────────────────────────────────────────────────
    tools.push(Tool::new(
        "fab_analyze_model",
        "Analyze a 3D model (STL) BEFORE printing: watertight/manifold check, dimensions (mm), \
         volume, surface area, steep-overhang fraction. Always run this gate on any generated or \
         downloaded model; do not slice a model that fails it. Returns a ModelReport JSON.",
        json!({"type": "object", "properties": {"path": {"type": "string"}},
               "required": ["path"]}),
        false,
        Arc::new(move |a: Value| {
            let path = match resolve_model_path(&arg_str(&a, "path")) {
                Ok(p) => p,
                Err(e) => return ToolResult::err(e),
            };
            match crate::geometry::analyze_stl(&path) {
                Ok(mut r) => {
                    r.file = abbreviate_home(&r.file);
                    ToolResult::ok(serde_json::to_string_pretty(&r).unwrap_or_default())
                }
                Err(e) => ToolResult::err(e),
            }
        }),
    ));

    // ── fab_slice_model ──────────────────────────────────────────────────────
    let st = state.clone();
    tools.push(Tool::new(
        "fab_slice_model",
        "Slice a model for a configured printer and create a fab job. Resin printers \
         (Elegoo Saturn/Mars, Photon Mono M7): PrusaSlicer SLA → SL1 → UVtools converts to the \
         printer's native format and validates islands/resin traps; REQUIRES `profile_ini` = a \
         curated resin profile .ini for the exact printer+resin (never invent exposure values). \
         FDM (Centauri, OctoPrint/Moonraker rigs): PrusaSlicer → gcode, `profile_ini` optional. \
         Returns the job id — next steps are fab_upload then fab_start_print (approval-gated).",
        json!({"type": "object", "properties": {
            "path": {"type": "string", "description": "model STL path"},
            "printer_id": {"type": "string"},
            "profile_ini": {"type": "string", "description": "slicer config .ini for this printer/material"},
            "name": {"type": "string", "description": "job name (defaults to the file name)"}},
            "required": ["path", "printer_id"]}),
        false,
        Arc::new(move |a: Value| {
            let path = match resolve_model_path(&arg_str(&a, "path")) {
                Ok(p) => p,
                Err(e) => return ToolResult::err(e),
            };
            let printer_id = arg_str(&a, "printer_id");
            let Some(cfg) = st.printers.lock().unwrap().get(&printer_id).cloned() else {
                return ToolResult::err(format!("no printer '{printer_id}'"));
            };
            // Mesh gate first — never slice a broken solid.
            let report = match crate::geometry::analyze_stl(&path) {
                Ok(r) => r,
                Err(e) => return ToolResult::err(e),
            };
            if !report.passes() {
                return ToolResult::err(format!(
                    "model failed the mesh gate: {} — repair it before slicing",
                    report.notes.join("; ")
                ));
            }
            let (tech, ext) = pipeline::native_format_for(&cfg.model);
            let profile = arg_str(&a, "profile_ini");
            let profile_path = if profile.is_empty() { None } else {
                match resolve_model_path(&profile) {
                    Ok(p) => Some(p),
                    Err(e) => return ToolResult::err(format!("profile_ini: {e}")),
                }
            };
            let name = {
                let n = arg_str(&a, "name");
                if n.is_empty() {
                    path.file_stem().and_then(|s| s.to_str()).unwrap_or("part").to_string()
                } else { n }
            };

            let (sliced, validation) = match tech {
                pipeline::Tech::Fdm => {
                    match pipeline::slice_fdm(&path, profile_path.as_deref(), &st.workspace) {
                        Ok(g) => (g, String::from("gcode produced")),
                        Err(e) => return ToolResult::err(e),
                    }
                }
                pipeline::Tech::Resin => {
                    let Some(prof) = profile_path.as_deref() else {
                        return ToolResult::err(
                            "resin slicing requires `profile_ini` — a curated profile for this \
                             exact printer + resin (UVtools ships per-printer PrusaSlicer \
                             profiles; exposure settings are never invented)",
                        );
                    };
                    let sl1 = match pipeline::slice_resin_sl1(&path, prof, &st.workspace) {
                        Ok(s) => s,
                        Err(e) => return ToolResult::err(e),
                    };
                    let native = match pipeline::convert_sl1(&sl1, ext, &st.workspace) {
                        Ok(n) => n,
                        Err(e) => return ToolResult::err(e),
                    };
                    let validation = pipeline::validate_sliced(&native)
                        .unwrap_or_else(|e| format!("validation unavailable: {e}"));
                    (native, validation)
                }
            };

            let job_id = {
                let mut jobs = st.jobs.lock().unwrap();
                let id = jobs.create(&name, &printer_id, &path.to_string_lossy());
                let sliced_s = sliced.to_string_lossy().to_string();
                let val = validation.clone();
                let _ = jobs.update(&id, |j| {
                    j.sliced_path = sliced_s;
                    j.validation = val;
                });
                let _ = jobs.transition(&id, JobState::Sliced);
                id
            };
            ToolResult::ok(format!(
                "job '{job_id}' sliced for {} → {}\nvalidation: {}\nnext: fab_upload {{job_id}}, \
                 then fab_start_print (requires approval)",
                cfg.name,
                abbreviate_home(&sliced.to_string_lossy()),
                validation.lines().take(6).collect::<Vec<_>>().join(" | ")
            ))
            .with_artifact(sliced.to_string_lossy().to_string())
        }),
    ));

    // ── fab_upload ───────────────────────────────────────────────────────────
    let st = state.clone();
    tools.push(Tool::new(
        "fab_upload",
        "Upload a sliced job's file to its printer storage. Does NOT start the print.",
        json!({"type": "object", "properties": {"job_id": {"type": "string"}},
               "required": ["job_id"]}),
        true,
        Arc::new(move |a: Value| {
            let job_id = arg_str(&a, "job_id");
            let job = match st.jobs.lock().unwrap().get(&job_id).cloned() {
                Some(j) => j,
                None => return ToolResult::err(format!("no job '{job_id}'")),
            };
            if job.state != JobState::Sliced {
                return ToolResult::err(format!(
                    "job '{}' is {:?} — only Sliced jobs can be uploaded", job.name, job.state));
            }
            let (cfg, live) = match st.live_status(&job.printer_id) {
                Ok(x) => x,
                Err(e) => return ToolResult::err(e),
            };
            if live.state == PrinterState::Offline {
                return ToolResult::err(format!("'{}' is offline — cannot upload", cfg.name));
            }
            let driver = match st.driver_for(&cfg) {
                Ok(d) => d,
                Err(e) => return ToolResult::err(e),
            };
            match driver.upload(Path::new(&job.sliced_path)) {
                Ok(fref) => {
                    let mut jobs = st.jobs.lock().unwrap();
                    let (storage, name) = (fref.storage.clone(), fref.name.clone());
                    let _ = jobs.update(&job_id, |j| {
                        j.remote_storage = storage;
                        j.remote_name = name;
                    });
                    let _ = jobs.transition(&job_id, JobState::Uploaded);
                    ToolResult::ok(format!(
                        "uploaded '{}' to {} — fab_start_print '{job_id}' starts it (approval required)",
                        fref.name, cfg.name
                    ))
                }
                Err(e) => ToolResult::err(e),
            }
        }),
    ));

    // ── fab_start_print (HARD GATE) ──────────────────────────────────────────
    let st = state.clone();
    tools.push(
        Tool::new(
            "fab_start_print",
            "START a print job on a physical printer. ALWAYS requires the Principal's approval: \
             resin printers cannot sense whether the vat has resin, the plate is installed, or \
             the lid is closed — a human must confirm the machine is physically ready. Refuses if \
             the printer is not idle or a finished part has not been cleared.",
            json!({"type": "object", "properties": {"job_id": {"type": "string"}},
                   "required": ["job_id"]}),
            true,
            Arc::new(move |a: Value| {
                let job_id = arg_str(&a, "job_id");
                let job = match st.jobs.lock().unwrap().get(&job_id).cloned() {
                    Some(j) => j,
                    None => return ToolResult::err(format!("no job '{job_id}'")),
                };
                if job.state != JobState::Uploaded {
                    return ToolResult::err(format!(
                        "job '{}' is {:?} — upload it first (fab_upload)", job.name, job.state));
                }
                // Manual-unload gate across the queue.
                if let Err(e) = st.jobs.lock().unwrap().printer_clear(&job.printer_id) {
                    return ToolResult::err(e);
                }
                // Zero-auth doctrine: re-read LIVE state immediately before commanding motion.
                let (cfg, live) = match st.live_status(&job.printer_id) {
                    Ok(x) => x,
                    Err(e) => return ToolResult::err(e),
                };
                if live.state != PrinterState::Idle {
                    return ToolResult::err(format!(
                        "'{}' is {} right now — refusing to start '{}'",
                        cfg.name, live.state.label(), job.name));
                }
                let driver = match st.driver_for(&cfg) {
                    Ok(d) => d,
                    Err(e) => return ToolResult::err(e),
                };
                let fref = crate::driver::FileRef::new(job.remote_storage.clone(), job.remote_name.clone());
                match driver.start(&fref) {
                    Ok(()) => {
                        let _ = st.jobs.lock().unwrap().transition(&job_id, JobState::Printing);
                        ToolResult::ok(format!("print '{}' started on {}", job.name, cfg.name))
                    }
                    Err(e) => ToolResult::err(e),
                }
            }),
        )
        .hard_gated(),
    );

    // ── fab_pause_print (the SAFE action — autonomous) ───────────────────────
    let st = state.clone();
    tools.push(Tool::new(
        "fab_pause_print",
        "Pause the active print. This is the SAFE action — use it immediately and autonomously \
         whenever something looks wrong; a human can resume after inspection.",
        json!({"type": "object", "properties": {"printer_id": {"type": "string"}},
               "required": ["printer_id"]}),
        false,
        Arc::new(move |a: Value| {
            let (cfg, _live) = match st.live_status(&arg_str(&a, "printer_id")) {
                Ok(x) => x,
                Err(e) => return ToolResult::err(e),
            };
            match st.driver_for(&cfg).and_then(|d| d.pause()) {
                Ok(()) => ToolResult::ok(format!("'{}' paused", cfg.name)),
                Err(e) => ToolResult::err(e),
            }
        }),
    ));

    // ── fab_resume_print (HARD GATE) ─────────────────────────────────────────
    let st = state.clone();
    tools.push(
        Tool::new(
            "fab_resume_print",
            "Resume a paused print. ALWAYS requires approval — resuming after an anomaly can \
             crash the plate into the FEP/LCD; a human must inspect the machine first.",
            json!({"type": "object", "properties": {"printer_id": {"type": "string"}},
                   "required": ["printer_id"]}),
            true,
            Arc::new(move |a: Value| {
                let (cfg, live) = match st.live_status(&arg_str(&a, "printer_id")) {
                    Ok(x) => x,
                    Err(e) => return ToolResult::err(e),
                };
                if live.state != PrinterState::Paused {
                    return ToolResult::err(format!(
                        "'{}' is {} — only paused printers can resume", cfg.name, live.state.label()));
                }
                match st.driver_for(&cfg).and_then(|d| d.resume()) {
                    Ok(()) => ToolResult::ok(format!("'{}' resumed", cfg.name)),
                    Err(e) => ToolResult::err(e),
                }
            }),
        )
        .hard_gated(),
    );

    // ── fab_cancel_print ─────────────────────────────────────────────────────
    let st = state.clone();
    tools.push(Tool::new(
        "fab_cancel_print",
        "Cancel/stop the active print on a printer. Destroys the in-progress part.",
        json!({"type": "object", "properties": {
            "printer_id": {"type": "string"},
            "job_id": {"type": "string", "description": "optional fab job to mark cancelled"}},
            "required": ["printer_id"]}),
        true,
        Arc::new(move |a: Value| {
            let (cfg, _live) = match st.live_status(&arg_str(&a, "printer_id")) {
                Ok(x) => x,
                Err(e) => return ToolResult::err(e),
            };
            match st.driver_for(&cfg).and_then(|d| d.cancel()) {
                Ok(()) => {
                    let job_id = arg_str(&a, "job_id");
                    if !job_id.is_empty() {
                        let _ = st.jobs.lock().unwrap().transition(&job_id, JobState::Cancelled);
                    }
                    ToolResult::ok(format!("print on '{}' cancelled", cfg.name))
                }
                Err(e) => ToolResult::err(e),
            }
        }),
    ));

    // ── fab_list_jobs ────────────────────────────────────────────────────────
    let st = state.clone();
    tools.push(Tool::new(
        "fab_list_jobs",
        "List fabrication jobs and their states (draft/sliced/uploaded/printing/complete/…).",
        json!({"type": "object", "properties": {}}),
        false,
        Arc::new(move |_a: Value| {
            let jobs = st.jobs.lock().unwrap();
            if jobs.list().is_empty() {
                return ToolResult::ok("no fab jobs yet");
            }
            let rows: Vec<Value> = jobs.list().iter().map(|j| json!({
                "job_id": j.id, "name": j.name, "printer_id": j.printer_id,
                "state": j.state, "sliced": abbreviate_home(&j.sliced_path),
                "validation": j.validation.lines().next().unwrap_or(""),
            })).collect();
            ToolResult::ok(serde_json::to_string_pretty(&rows).unwrap_or_default())
        }),
    ));

    // ── fab_clear_job (HARD GATE — asserts a physical fact) ──────────────────
    let st = state.clone();
    tools.push(
        Tool::new(
            "fab_clear_job",
            "Confirm a finished/cancelled job's part has been PHYSICALLY removed from the plate \
             and remove the job from the queue. Requires approval — only a human standing at the \
             printer can assert the plate is clear.",
            json!({"type": "object", "properties": {"job_id": {"type": "string"}},
                   "required": ["job_id"]}),
            true,
            Arc::new(move |a: Value| {
                let job_id = arg_str(&a, "job_id");
                let state_now = st.jobs.lock().unwrap().get(&job_id).map(|j| j.state);
                match state_now {
                    None => ToolResult::err(format!("no job '{job_id}'")),
                    Some(JobState::Printing) => {
                        ToolResult::err("job is still printing — cancel it first")
                    }
                    Some(_) => {
                        st.jobs.lock().unwrap().remove(&job_id);
                        ToolResult::ok(format!("job '{job_id}' cleared — printer is free"))
                    }
                }
            }),
        )
        .hard_gated(),
    );

    // ── fab_camera ───────────────────────────────────────────────────────────
    let st = state;
    tools.push(Tool::new(
        "fab_camera",
        "Get the printer's camera stream descriptor (RTSP/MJPEG/snapshot URL). Resin RTSP \
         streams are nonstandard — open at most ONE viewer (IINA/VLC), never several.",
        json!({"type": "object", "properties": {"printer_id": {"type": "string"}},
               "required": ["printer_id"]}),
        false,
        Arc::new(move |a: Value| {
            let (cfg, _live) = match st.live_status(&arg_str(&a, "printer_id")) {
                Ok(x) => x,
                Err(e) => return ToolResult::err(e),
            };
            match st.driver_for(&cfg).and_then(|d| d.camera()) {
                Ok(cam) => ToolResult::ok(serde_json::to_string_pretty(&cam).unwrap_or_default()),
                Err(e) => ToolResult::err(e),
            }
        }),
    ));

    tools
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fab_state(tag: &str) -> Arc<FabState> {
        let d = std::env::temp_dir().join(format!("gx-fabtools-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        FabState::open(&d)
    }

    fn tool<'a>(tools: &'a [Tool], name: &str) -> &'a Tool {
        tools.iter().find(|t| t.name == name).expect(name)
    }

    #[test]
    fn safety_gates_are_pinned() {
        let tools = fab_tools(fab_state("gates"));
        // HARD GATES — approval even in autonomous mode. Load-bearing; do not weaken.
        for name in ["fab_start_print", "fab_resume_print", "fab_clear_job"] {
            let t = tool(&tools, name);
            assert!(t.irreversible && t.hard_gate, "{name} must be hard-gated");
        }
        // Plain irreversible (HITL-gated in HITL mode).
        for name in ["fab_upload", "fab_cancel_print", "fab_remove_printer"] {
            let t = tool(&tools, name);
            assert!(t.irreversible, "{name} must be irreversible");
            assert!(!t.hard_gate, "{name} should not be hard-gated");
        }
        // The SAFE action stays autonomous.
        for name in ["fab_pause_print", "fab_printer_status", "fab_analyze_model",
                     "fab_slice_model", "fab_list_printers", "fab_list_jobs",
                     "fab_discover_printers", "fab_camera", "fab_add_printer"] {
            assert!(!tool(&tools, name).irreversible, "{name} must be autonomous");
        }
    }

    #[test]
    fn mock_fleet_end_to_end_minus_slicing() {
        let state = fab_state("e2e");
        let tools = fab_tools(state.clone());

        // Add a mock printer.
        let out = tool(&tools, "fab_add_printer")
            .run(json!({"name": "Bench Mock", "kind": "mock"}));
        assert!(out.ok, "{}", out.output);
        assert!(out.output.contains("bench-mock"));

        // Status.
        let out = tool(&tools, "fab_printer_status").run(json!({"printer_id": "bench-mock"}));
        assert!(out.ok);
        assert!(out.output.contains("\"state\": \"idle\""), "{}", out.output);

        // Fake a sliced job (skip the external slicer).
        let sliced = std::env::temp_dir().join("gx-fab-e2e.goo");
        std::fs::write(&sliced, b"layers").unwrap();
        let job_id = {
            let mut jobs = state.jobs.lock().unwrap();
            let id = jobs.create("bench part", "bench-mock", "/tmp/x.stl");
            let sp = sliced.to_string_lossy().to_string();
            jobs.update(&id, |j| j.sliced_path = sp).unwrap();
            jobs.transition(&id, JobState::Sliced).unwrap();
            id
        };

        // Upload → start → status shows printing.
        let out = tool(&tools, "fab_upload").run(json!({"job_id": job_id}));
        assert!(out.ok, "{}", out.output);
        let out = tool(&tools, "fab_start_print").run(json!({"job_id": job_id}));
        assert!(out.ok, "{}", out.output);
        let out = tool(&tools, "fab_printer_status").run(json!({"printer_id": "bench-mock"}));
        assert!(out.output.contains("printing"), "{}", out.output);

        // Double-start refused (printer busy + job state).
        let out = tool(&tools, "fab_start_print").run(json!({"job_id": job_id}));
        assert!(!out.ok);

        // Pause autonomously, resume path errors if not paused → pause then resume.
        let out = tool(&tools, "fab_pause_print").run(json!({"printer_id": "bench-mock"}));
        assert!(out.ok, "{}", out.output);
        let out = tool(&tools, "fab_resume_print").run(json!({"printer_id": "bench-mock"}));
        assert!(out.ok, "{}", out.output);

        // Cancel + clear.
        let out = tool(&tools, "fab_cancel_print")
            .run(json!({"printer_id": "bench-mock", "job_id": job_id}));
        assert!(out.ok, "{}", out.output);
        let out = tool(&tools, "fab_clear_job").run(json!({"job_id": job_id}));
        assert!(out.ok, "{}", out.output);
        let _ = std::fs::remove_file(&sliced);
    }

    #[test]
    fn analyze_rejects_icloud_and_missing() {
        let tools = fab_tools(fab_state("paths"));
        let t = tool(&tools, "fab_analyze_model");
        let out = t.run(json!({"path": "/Users/x/Library/Mobile Documents/com~apple~CloudDocs/part.stl"}));
        assert!(!out.ok && out.output.contains("iCloud"));
        let out = t.run(json!({"path": "/tmp/definitely-not-here-gx.stl"}));
        assert!(!out.ok);
    }
}
