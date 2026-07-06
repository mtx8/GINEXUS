# SP-FAB — Autonomous Fabrication Module (SP-Robotics Phase 3)

**Date:** 2026-07-06 · **Status:** approved by Principal ("build until full completion") · **Branch:** `feat/sp-fab`

GINEXUS gains a **Fabrication section**: AI-agent-run 3D printing — design/ingest → analyze →
slice → validate → (approval-gated) upload/start → monitor — over real network printers, with a
live console UI. This is the Phase 3 that `robotics.rs` explicitly deferred ("sending G-code to a
real printer will be HITL"), extended to resin (MSLA) printers, a printer driver layer, a job
queue, and a first-party **Fab MCP server**.

## Research basis (all claims adversarially verified 2026-07-06; 33-agent workflow)

- **SDCP V3.0.0** (CBD-Tech/Elegoo, MIT, `github.com/cbd-tech/SDCP-Smart-Device-Control-Protocol-V3.0.0`):
  UDP discovery = broadcast ASCII `M99999` → port 3000, JSON reply (MainboardID/MainboardIP/…).
  Control = WebSocket `ws://{ip}:3030/websocket`, JSON envelope `{Id, Data:{Cmd, Data, RequestID,
  MainboardID, TimeStamp, From}, Topic}`, topics `sdcp/{request,response,status,attributes,error,notice}/{MainboardID}`,
  text `ping`/`pong` heartbeat. Upload = chunked multipart POST `http://{ip}:3030/uploadFile/upload`
  (≤1 MB chunks; headers `S-File-MD5`, `Check`; fields Offset/Uuid/TotalSize/File). Commands:
  0 status, 1 attributes, 128 start (Filename **with `/local/` prefix**, StartLayer), 129 pause,
  130 stop, 131 resume, 258 file list, 386 camera (returns VideoUrl; RTSP on resin — nonstandard,
  ffmpeg-hostile; MJPEG on Centauri). Printers: Saturn 4/4 Ultra, Mars 5/5 Ultra (resin), Centauri
  Carbon (FDM dialect, extra codes, 60 s idle disconnect). **No auth, LAN-only, ~4-connection cap →
  ONE owned connection per printer, multiplexed.** Misspelled fields are load-bearing
  (`CurrenCoord`, `RelaseFilmState`). **No Rust SDCP client exists — ours is the first.**
- **Anycubic Photon Mono M7/M7 Pro/M7 Max**: 2.4 GHz Wi-Fi, **cloud-only** (MQTT
  `mqtt-universe.anycubic.com:8883` + REST `cloud-universe.anycubic.com`; mutual-TLS certs extracted
  by the community; Slicer-Next token required for realtime; Anycubic actively blocks third parties).
  No LAN mode (only Photon P1 has one). → **R2, monitor-only, Principal decision required** (ToS +
  cert-redistribution risk). Slicing for M7 is fully local today: UVtools ≥5 writes `.pm7/.pwsz/.pm7m`.
- **MCP landscape**: no first-party MCP from any printer/slicer vendor. OctoEverywhere + SimplyPrint
  ship official **cloud** MCPs (monitor/farm). Kiln (AGPL) and mcp-3D-printer-server (GPL-2) are the
  big community servers — copyleft, never vendor/link. **Gap we fill: Rust-native, local-first,
  HITL-gated fab MCP** (stdio, reuses the signed core binary like `--printful-mcp`).
- **Slicing (macOS, no GUI, all open-source)** — Chitubox/Lychee have NO headless mode; do not automate GUIs.
  - FDM: `/Applications/PrusaSlicer.app/Contents/MacOS/PrusaSlicer --load <full-config.ini> -g model.stl -o out.gcode` (verified locally, v2.9.5).
  - Resin: PrusaSlicer `--export-sla --printer-technology SLA -o out.sl1` → `UVtoolsCmd convert out.sl1 auto out_dir` (FILEFORMAT_ token in UVtools-shipped profiles picks .goo/.ctb/.pm7/.pwsz) → `UVtoolsCmd print-issues` (islands/resin traps/suction cups) as the post-slice gate. UVtools ships native osx-arm64; AGPL → **external CLI only, never linked** (same isolation as PrusaSlicer today).
  - Format map: Saturn 4 Ultra = ENCRYPTED.CTB (also .goo — prefer .goo so our Rust validators work), Saturn 4 / Mars 4/5 = .goo, older Mars/Saturn = .ctb, M7 = .pm7, M7 Pro = .pwsz, M7 Max = .pm7m, Centauri Carbon = .gcode.
- **CAD understanding**: Rust-native mesh gate is cheap and sufficient for v1 — STL parse (`stl_io`),
  watertight/manifold via edge-pairing, signed-volume, bbox, surface area, overhang detection
  (normal·−Z vs threshold). ModelReport JSON = the agent's "understanding". build123d/trimesh
  Python sidecar + Zoo text-to-CAD = R2. `cad_generate` (OpenSCAD) remains the local generator.
- **Critic findings honored**: macOS 15 Local Network TCC (`NSLocalNetworkUsageDescription` +
  manual-IP entry as first-class path); resin **never-automate** policy (below); camera =
  descriptor, not stream (AVFoundation can't RTSP/MJPEG — v1 shows URL + snapshot affordances);
  layer-time anomaly > camera for resin failure detection (R2); SDCP zero-auth ⇒ never assume sole
  controller — re-read status before acting; manual-unload gate between queued resin jobs.

## Safety doctrine (resin is a chemical + UV + crash hazard)

| Action | Autonomy |
|---|---|
| discover, status, attributes, file list, analyze, slice, validate | autonomous (read-only / file-producing) |
| pause | autonomous (the SAFE action — always allowed) |
| upload file to printer | irreversible → HITL-gated |
| **start print / resume print** | **irreversible + HARD GATE** (approval even in autonomous mode — no vat/plate/lid sensors exist) |
| cancel print | irreversible → HITL-gated |
| exposure/lift setting changes | agent must NEVER synthesize; profiles are curated files; any change is HITL |

## PSS enforcement (Principal directive 2026-07-06)

- **Zero downloads**: the module NEVER downloads, installs, or updates any tool, script, or
  firmware. Missing slicers produce an instruction to install the OFFICIAL build manually
  (PrusaSlicer from prusa3d.com; UVtools from github.com/sn4k3/UVtools releases). No
  `curl | bash` anywhere — the agent guidance forbids it explicitly.
- **Fixed tool paths**: external CLIs execute only from `/Applications/*.app` bundle paths —
  no `$PATH` lookup (hijack-proof), no user-writable prefixes.
- **Signature gate**: `codesign -v` must pass on the tool bundle before every pipeline run
  (tamper/substitution guard); conscious operator override via `GINEXUS_FAB_ALLOW_UNSIGNED_TOOLS=1`.
- **Copyleft isolation**: UVtools (AGPL) and PrusaSlicer (AGPL) are invoked as unmodified
  external processes only — never linked, never vendored. All crate deps are permissive
  (tungstenite/md-5/stl_io: MIT/Apache) and version-pinned.
- **No secrets on disk**: printer API keys live in the Keychain; configs store only an env-var
  NAME (`api_key_env`), injected by the signed app at spawn.
- **Zero-auth protocol discipline**: SDCP has no authentication → every state-changing command
  re-reads live status first; the module never assumes sole control of a printer.
- **MCP default-deny**: `--fab-mcp` excludes hard-gated physical actions unless the operator
  sets `GINEXUS_FAB_MCP_UNLOCK=1`; inside GINEXUS they always ride the HMAC approval loop.

## Architecture

```
SwiftUI app ── Fabrication section (cyan/amber console)
   │  GET/POST /v1/fab/* (UDS+token)
ginexus-server ── FabState { registry, statuses, jobs }
   │  registers fab tools into the agent ToolRegistry
ginexus-print (NEW crate)
   ├─ driver.rs    PrinterDriver trait · PrinterState · Capabilities · CameraSource
   ├─ sdcp/        codec.rs (sans-io, golden-message tests) · client.rs (UDP discover,
   │               WS actor: RequestID↔oneshot, status broadcast, ping keepalive, backoff)
   ├─ octoprint.rs REST driver (X-Api-Key; /api/job, /api/files?print=true)
   ├─ moonraker.rs REST driver (/printer/objects/query, /printer/print/*, /server/files/upload)
   ├─ mock.rs      deterministic MockDriver (state machine + progress ticks) — tests & UI dev
   ├─ geometry.rs  STL gate → ModelReport (watertight, volume, bbox, overhangs)
   ├─ pipeline.rs  PrusaSlicer/UVtoolsCmd orchestration (resin + FDM), format map
   ├─ jobs.rs      JobQueue state machine (Draft→Analyzed→Sliced→Validated→AwaitingApproval→
   │               Uploaded→Printing→Complete/Failed) + manual-unload gate, JSON persistence
   ├─ registry.rs  PrinterRegistry (id, name, kind, host, creds-env) JSON persistence
   └─ tools.rs     agent tools (fab_*) with the safety table above
--fab-mcp subcommand on ginexus-server = stdio MCP server exposing the same tools
   (mirrors --printful-mcp; usable from Claude Code / Hermes / any MCP host)
```

New workspace deps (all permissive): `tokio-tungstenite` (WS), `md-5` (upload checksum), `stl_io`
(STL I/O). Everything else = existing tokio/reqwest/serde.

### Server routes (app UI)
- `GET  /v1/fab/printers` → configured printers + cached live status
- `POST /v1/fab/printers` `{name, kind, host, api_key_env?}` · `POST /v1/fab/printers/remove {id}`
- `POST /v1/fab/discover` → SDCP UDP sweep (+manual-IP probe) results
- `GET  /v1/fab/jobs` → queue snapshot · `POST /v1/fab/jobs/remove {id}`

Status polling: on-request with a short cache; the app polls every 4 s only while the Fabrication
section is visible.

### Agent team (Nexus mapping — ENG-HW owns fabrication, AIL assists)
- **FAB-CAD** — model understanding & requirements ingestion: `read_document`/`read_pdf_text` →
  structured requirement JSON → `cad_generate` → `fab_analyze_model` gate.
- **FAB-OPS** — printer operation: discover/status/slice/queue; requests Principal approval for
  upload/start via the standard HITL grant flow.
- **FAB-QA** — monitoring: status watch, error topics, pause-first policy on anomaly.
These are conductor-routed roles expressed through AGENT_GUIDANCE (a FABRICATION paragraph) + the
fab tools' own descriptions — no separate runtime persona machinery in v1.

### UI — Fabrication console (Silo Unison × OMNISCIENT)
Sidebar gains **Fabrication** (nav item, `printer` SF symbol). Selecting it swaps the DETAIL pane
(not a sheet) to `FabricationView`:
- **Printer rack**: one card per configured printer — name stamp, kind chip, StatusDot,
  state label, thin progress bar, layer `n/N` + time-left in mono **tabular** figures.
- **Per-printer tabs** (ALL + one per printer) → detail: telemetry panel (temps/z/layer — mono,
  **cyan** data values), job queue panel, camera descriptor panel, control row
  (PAUSE free · RESUME/START/CANCEL ember, approval-gated via chat).
- **Add printer**: Discover (SDCP) + manual IP/kind/API-key — manual entry is first-class (TCC).
- **Palette law**: existing Brand tokens + new `Brand.cyan (#00E5FF)` = *live-data accent only*
  (OMNISCIENT grammar: cyan = data, ember = chrome/attention). Never cyan on buttons/nav; one
  accent per element; flat matte panels, hairlines, no glow shadows; `Brand.ease` only.
- `project.yml`: add `NSLocalNetworkUsageDescription` ("GINEXUS finds and monitors your 3D
  printers on your local network.").

## Scope

**v1 (this build):** SDCP driver (resin Elegoo + Centauri family) with mock-backed protocol tests
· OctoPrint + Moonraker REST drivers (poll) · MockDriver · geometry gate · resin+FDM slice
pipeline (external CLIs, graceful "not installed" errors) · job queue · fab agent tools + guidance
· `--fab-mcp` stdio server · `/v1/fab/*` routes · Fabrication UI + cyan token + add-printer flow ·
docs/CHANGELOG. **No physical printer on hand → hardware smoke test is the Principal's first-run
step; everything protocol-level is tested against the mock + golden messages from the spec.**

**R2 (documented, not built):** Anycubic M7 cloud monitor (needs Principal ToS/legal decision) ·
Bambu LAN (Developer-Mode-only; policy-fragile) · PrusaLink · camera streaming (retina/ffmpeg
decode) + VLM failure detection · layer-time anomaly detector · Python geometry sidecar
(trimesh/build123d) · Zoo text-to-CAD · legacy pre-V3 Elegoo (pull-model needs an HTTP listener).

## Adversarial review (2026-07-06, 28-agent gate) — fixes applied

A 4-dimension adversarial review with per-finding verification confirmed 22 real defects on the
first commit; all are fixed with regression tests:
- **iCloud symlink bypass** → `resolve_model_path` canonicalizes before the iCloud check.
- **`api_key_env` secret exfiltration** → namespace fence (`GINEXUS_FAB_*` only) + core-secret denylist.
- **`profile_ini` command injection** (`post_process`/`printhost_*` via PrusaSlicer `--load`) → validated/rejected.
- **Stale-slice → wrong-part print** → per-job workspace subdir + exit-status check + mtime freshness fence.
- **Corrupt `jobs.json` wipes queue → plate-gate bypass** → atomic write (temp+rename) + corrupt-file
  quarantine + a poisoned queue REFUSES the plate-clear check instead of trusting an empty queue.
- **Cancelled/Failed mid-print bypassed the unload gate** → `printed` flag; a print that reached the
  plate blocks the gate until physically cleared.
- **`--fab-mcp` exposed destructive tools by default** → default-deny ALL irreversible tools (was: only hard-gated).
- **SDCP upload only checked HTTP status** → parses the printer's response body for the documented
  upload error codes.
- **SDCP status precedence** → a busy machine state overrides a `PrintInfo.Status:0`, so an occupied
  printer never reads Idle to the start-gate.
- **`run_with_timeout` pipe deadlock + zombie leak** → threaded stdout/stderr drain + `wait()` reap after kill.
- **Route printer-remove left a stale driver** → `FabState::remove_printer` (drop cache + registry) used by both tool and route.
- **No Printing→Complete transition** → `live_status` reconciles the queue from live printer state.
- **Checked `jobs/remove`** → refuses a Printing job (409); Swift surfaces it.
- **Swift**: approval prompt was hidden while in the Fabrication section (now forces `.chat` on
  pending); `fabLoading` watchdog via `defer` + `SO_RCVTIMEO` read timeout; generation counter so a
  stale poll can't resurrect an optimistically-removed row.

**Residual (documented, low severity):** the JSON stores are now crash-safe (atomic writes) and
corruption-safe (quarantine+poison), but concurrent MUTATION from two processes (the app's core AND a
simultaneously-running `--fab-mcp`) can still lose an update (last-writer-wins on stale snapshots).
This is a consistency limitation, not a safety-gate bypass — atomic rename guarantees no reader ever
sees a half-written file. A cross-process advisory lock (flock) with reload-before-mutate is the
follow-up if the two are ever run against the same state dir concurrently.

## Decisions log
1. **Drivers in-crate, MCP as a façade** — GINEXUS registers fab tools natively (fast, typed);
   the same tools are exported via `--fab-mcp` for external MCP hosts. Both share one impl.
2. **SDCP first** because it's open, current Elegoo fleet, and greenfield in Rust; OctoPrint/
   Moonraker next because they're the stable FDM hubs; Bambu/Anycubic deferred for policy risk.
3. **Saturn 4 Ultra target format = .goo** (validatable), not encrypted CTB.
4. **AGPL tools (UVtools) and GPL references stay external processes** — no linking, no vendoring.
5. **Cyan enters Brand.swift as a scoped data-accent token**, honoring the one-accent-per-element law.
