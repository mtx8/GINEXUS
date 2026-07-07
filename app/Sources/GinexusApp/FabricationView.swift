// FabricationView.swift — the SP-FAB manufacturing cockpit. ALL view = the fleet at a glance;
// selecting a printer opens its workstation: an identity strip with connection detail, a dense
// live-telemetry grid, physical controls, camera, a numbered model-prep pipeline (model → analyze
// → profile → slice), and a job table. Rectangular throughout (no pills); OMNISCIENT density over
// the Silo Unison palette; cyan reserved for live values. Physical START/RESUME/CANCEL go through
// an explicit readiness confirmation — the deliberate click is the approval a hard action requires.
import SwiftUI
import AppKit
import GinexusCore

struct FabricationView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 14)
            Rectangle().fill(Brand.line1).frame(height: 1)
            if model.fabPrinters.isEmpty {
                emptyState
            } else {
                fleetTabs
                    .padding(.horizontal, 24).padding(.vertical, 12)
                if let sel = model.fabSelectedID,
                   let printer = model.fabPrinters.first(where: { $0.id == sel }) {
                    PrinterCockpit(model: model, printer: printer)
                        .id(sel)   // fresh transition per printer
                        .transition(.opacity)
                } else {
                    fleetOverview
                }
            }
            if let n = model.fabNotice { noticeBar(n, isError: false) }
            if let e = model.fabError { noticeBar(e, isError: true) }
        }
        .sheet(isPresented: $model.fabAddSheetOpen) { AddPrinterSheet(model: model) }
    }

    // MARK: header
    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 4) {
                Text("FABRICATION").font(.system(size: 14, weight: .semibold)).kerning(3).foregroundStyle(Brand.bone300)
                Text("BAY").font(.system(size: 14, weight: .semibold)).kerning(3).foregroundStyle(Brand.ember500)
            }
            if !model.fabPrinters.isEmpty {
                Rectangle().fill(Brand.line1).frame(width: 1, height: 16)
                statCount("\(model.fabPrinters.count)", "PRINTERS")
                if printingCount > 0 { statCount("\(printingCount)", "ACTIVE", color: Brand.cyan500) }
                if !model.fabJobs.isEmpty { statCount("\(model.fabJobs.count)", "JOBS") }
            }
            Spacer(minLength: 0)
            if model.fabLoading {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 10, height: 10)
                    Text("SYNCING").font(.system(size: 8.5, weight: .semibold, design: .monospaced)).kerning(1.4).foregroundStyle(Brand.bone400)
                }
            } else if !model.fabPrinters.isEmpty {
                TimelineView(.periodic(from: .now, by: 5)) { ctx in
                    let s = Int(ctx.date.timeIntervalSince(model.fabPrintersAt))
                    Text("SYNCED \(s < 5 ? "NOW" : "\(s)s AGO")")
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced)).kerning(1.2).foregroundStyle(Brand.bone400)
                }
            }
            FabButton(title: "Refresh", icon: "arrow.clockwise", style: .ghost, compact: true) { model.refreshFab() }
            FabButton(title: "Add Printer", icon: "plus", style: .primary) { model.fabAddSheetOpen = true }
        }
    }

    private func statCount(_ n: String, _ label: String, color: Color = Brand.bone100) -> some View {
        HStack(spacing: 5) {
            Text(n).font(.system(size: 14, weight: .heavy, design: .monospaced)).foregroundStyle(color)
            Text(label).font(.system(size: 9, weight: .semibold)).kerning(1.2).foregroundStyle(Brand.bone400)
        }
    }

    private var printingCount: Int { model.fabPrinters.filter { $0.state == "printing" }.count }

    private func noticeBar(_ text: String, isError: Bool) -> some View {
        HStack(spacing: 8) {
            StatusDot(color: isError ? Brand.ember500 : Brand.ok, size: 6)
            Text(text).font(Brand.body(12)).foregroundStyle(Brand.bone100)
            Spacer(minLength: 0)
            Button { if isError { model.fabError = nil } else { model.fabNotice = nil } } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Brand.bone400)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
        .background(Brand.ink850)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Brand.line1), alignment: .top)
    }

    // MARK: empty state
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            GlyphMark(size: 40)
            Text("NO PRINTERS IN THE FLEET").font(.system(size: 11, weight: .semibold)).kerning(2).foregroundStyle(Brand.bone300)
            Text("Discover Elegoo/SDCP printers on your network, or add OctoPrint, Moonraker, or a "
                 + "mock printer by address. Then select a printer to open its workstation.")
                .font(Brand.body(13)).foregroundStyle(Brand.bone300)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
            HStack(spacing: 10) {
                FabButton(title: "Add Printer", icon: "plus", style: .primary) { model.fabAddSheetOpen = true }
                FabButton(title: "Discover", icon: "dot.radiowaves.left.and.right") { model.fabAddSheetOpen = true; model.fabDiscover() }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: fleet tabs
    private var fleetTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                FabSegment(label: "All", selected: model.fabSelectedID == nil) { select(nil) }
                ForEach(model.fabPrinters) { p in
                    FabSegment(label: p.name, selected: model.fabSelectedID == p.id) { select(p.id) }
                }
            }
        }
    }

    private func select(_ id: String?) {
        withAnimation(Brand.ease(0.18)) {
            model.fabSelectedID = id; model.fabCamera = nil; model.fabNotice = nil; model.fabError = nil
        }
    }

    // MARK: ALL view — rack + global job table
    private var fleetOverview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14)], spacing: 14) {
                    ForEach(model.fabPrinters) { p in
                        FabPrinterCard(printer: p, onOpen: { select(p.id) }, onRemove: { model.fabRemovePrinter(p.id) })
                    }
                }
                FabPanel(title: "All Jobs") {
                    if model.fabJobs.isEmpty {
                        Text("No fabrication jobs yet. Open a printer to prepare and slice a model.")
                            .font(Brand.body(12)).foregroundStyle(Brand.bone300)
                    } else {
                        JobTable(model: model, jobs: model.fabJobs, showPrinter: true, cockpit: nil)
                    }
                }
                safetyStamp
            }
            .padding(.horizontal, 24).padding(.bottom, 28)
        }
    }

    private var safetyStamp: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(Brand.bone400)
            Text("START · RESUME · PLATE-CLEAR always ask you to confirm the machine is physically ready — PAUSE is instant.")
                .font(Brand.body(11)).foregroundStyle(Brand.bone400)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - per-printer cockpit

private struct PrinterCockpit: View {
    @ObservedObject var model: AppModel
    let printer: FabPrinter
    @State private var confirmStartJob: FabJobItem?
    @State private var confirmCancel = false

    private var jobs: [FabJobItem] { model.fabJobs.filter { $0.printerID == printer.id } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                identityPanel
                telemetryPanel
                HStack(alignment: .top, spacing: 14) {
                    controlsPanel.frame(maxWidth: .infinity)
                    cameraPanel.frame(maxWidth: .infinity)
                }
                preparePanel
                FabPanel(title: "Jobs · This Printer") {
                    if jobs.isEmpty {
                        Text("No jobs yet. Prepare a model below, then Slice → Queue.")
                            .font(Brand.body(12)).foregroundStyle(Brand.bone300)
                    } else {
                        JobTable(model: model, jobs: jobs, showPrinter: false,
                                 cockpit: JobActions(onStart: { confirmStartJob = $0 }))
                    }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 2).padding(.bottom, 28)
        }
        .confirmationDialog("Start this print?", isPresented: Binding(
            get: { confirmStartJob != nil }, set: { if !$0 { confirmStartJob = nil } }
        ), presenting: confirmStartJob) { job in
            Button("Printer is ready — start", role: .destructive) { model.fabStart(jobID: job.id); confirmStartJob = nil }
            Button("Cancel", role: .cancel) { confirmStartJob = nil }
        } message: { _ in
            Text("Confirm the machine is physically ready: resin in the vat (or filament loaded), build "
                 + "plate installed, previous part removed, and the lid/cover closed. The printer cannot "
                 + "sense these — starting is irreversible.")
        }
        .confirmationDialog("Cancel the active print?", isPresented: $confirmCancel) {
            Button("Cancel the print", role: .destructive) {
                let active = jobs.first { $0.state == "printing" }?.id ?? ""
                model.fabCancel(printerID: printer.id, jobID: active); confirmCancel = false
            }
            Button("Keep printing", role: .cancel) { confirmCancel = false }
        } message: { Text("This stops the print and destroys the in-progress part. It cannot be undone.") }
    }

    // MARK: identity
    private var identityPanel: some View {
        FabPanel(title: "Printer", accent: stateColor,
                 accessory: AnyView(HStack(spacing: 6) {
                    Text(printer.state.uppercased())
                        .font(.system(size: 11, weight: .heavy, design: .monospaced)).kerning(1.4)
                        .foregroundStyle(stateColor == Brand.ink500 ? Brand.bone400 : stateColor)
                 })) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    StatusDot(color: stateColor, glow: printer.isActive, size: 9)
                    Text(printer.name).font(.system(size: 18, weight: .semibold)).foregroundStyle(Brand.bone50)
                    FabTag(text: printer.kind)
                    if !printer.model.isEmpty {
                        Text(printer.model).font(Brand.body(12)).foregroundStyle(Brand.bone300).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                // Connection detail rows (host/board id are copyable on hover).
                VStack(spacing: 0) {
                    if !printer.host.isEmpty { FabCopyRow(key: "Host", value: printer.host) }
                    if !printer.mainboardID.isEmpty { FabCopyRow(key: "Board ID", value: printer.mainboardID) }
                    FabDataRow(key: "Protocol", value: protocolName)
                    if let j = printer.jobName, !j.isEmpty { FabDataRow(key: "Active File", value: (j as NSString).lastPathComponent) }
                }
                // Capability tags.
                HStack(spacing: 6) {
                    ForEach(capabilities, id: \.self) { FabTag(text: $0, color: Brand.bone400) }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var protocolName: String {
        switch printer.kind {
        case "sdcp": return "SDCP V3 (LAN)"
        case "octoprint": return "OctoPrint REST"
        case "moonraker": return "Moonraker (Klipper)"
        case "mock": return "Simulator"
        default: return printer.kind.uppercased()
        }
    }
    private var capabilities: [String] {
        printer.kind == "mock" ? ["UPLOAD", "START", "PAUSE"] : ["UPLOAD", "START", "PAUSE", "CANCEL", "CAMERA"]
    }

    // MARK: telemetry grid
    private var telemetryPanel: some View {
        let active = printer.isActive
        return FabPanel(title: "Live Telemetry",
                        accessory: active ? AnyView(HStack(spacing: 5) {
                            Circle().fill(Brand.cyan500).frame(width: 5, height: 5)
                            Text("LIVE").font(.system(size: 8.5, weight: .bold, design: .monospaced)).kerning(1.4).foregroundStyle(Brand.cyan500)
                        }) : nil) {
            VStack(alignment: .leading, spacing: 12) {
                if printer.state == "printing" || printer.state == "paused" {
                    ThinProgressBar(value: printer.progress ?? 0, tint: Brand.cyan500).frame(height: 5)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), spacing: 16) {
                    FabMetric(key: "STATE", value: printer.state.uppercased(), live: active)
                    if let p = printer.progress { FabMetric(key: "PROGRESS", value: "\(Int((p * 100).rounded()))%", live: active) }
                    if let c = printer.currentLayer, let t = printer.totalLayers { FabMetric(key: "LAYER", value: "\(c) / \(t)", live: active) }
                    if let e = printer.elapsedSecs, active {
                        FabLiveMetric(key: "ELAPSED", baseSecs: e, since: model.fabPrintersAt, countUp: true)
                    }
                    if let s = printer.timeLeftSecs {
                        if active { FabLiveMetric(key: "REMAINING", baseSecs: s, since: model.fabPrintersAt, countUp: false) }
                        else { FabMetric(key: "REMAINING", value: fabETA(s)) }
                    }
                    ForEach(printer.extra) { t in FabMetric(key: t.label, value: t.value, live: true) }
                    if !active && printer.progress == nil {
                        FabMetric(key: "PROTOCOL", value: protocolShort)
                    }
                }
                if let d = printer.detail, !d.isEmpty, printer.state == "error" {
                    Text(d).font(Brand.body(11)).foregroundStyle(Brand.error)
                }
            }
        }
    }

    private var protocolShort: String {
        switch printer.kind { case "sdcp": return "SDCP V3"; case "octoprint": return "OCTOPRINT"
        case "moonraker": return "MOONRAKER"; case "mock": return "SIMULATOR"; default: return printer.kind.uppercased() }
    }

    private var stateColor: Color { fabStateColor(printer.state) }

    // MARK: controls
    private var controlsPanel: some View {
        FabPanel(title: "Controls",
                 accessory: AnyView(Button { model.fabRemovePrinter(printer.id); model.fabSelectedID = nil } label: {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Brand.bone400)
                 }.buttonStyle(.plain).help("Remove printer"))) {
            HStack(spacing: 8) {
                FabButton(title: "Pause", icon: "pause.fill",
                          enabled: printer.state == "printing" && !model.fabBusy) { model.fabPause(printerID: printer.id) }
                    .help("Pause immediately — always safe; resume after inspection")
                FabButton(title: "Resume", icon: "play.fill", style: .primary,
                          enabled: printer.state == "paused" && !model.fabBusy) { model.fabResume(printerID: printer.id) }
                    .help("Resume — confirm the machine is clear first")
                FabButton(title: "Cancel", icon: "stop.fill", style: .danger,
                          enabled: (printer.state == "printing" || printer.state == "paused") && !model.fabBusy) { confirmCancel = true }
                    .help("Stop the print — destroys the in-progress part")
            }
        }
    }

    // MARK: camera
    private var cameraPanel: some View {
        FabPanel(title: "Camera",
                 accessory: AnyView(FabButton(title: "Get Stream", icon: "video.fill", compact: true) { model.fabLoadCamera(printerID: printer.id) })) {
            VStack(alignment: .leading, spacing: 8) {
                if let cam = model.fabCamera {
                    if cam.hasStream {
                        FabDataRow(key: "Type", value: cam.kind.replacingOccurrences(of: "_url", with: "").uppercased(), valueColor: Brand.cyan500)
                        HStack(spacing: 8) {
                            Text(cam.url).font(.system(size: 11, design: .monospaced)).foregroundStyle(Brand.bone200).lineLimit(1)
                            Spacer(minLength: 0)
                            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cam.url, forType: .string) } label: {
                                Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundStyle(Brand.bone400)
                            }.buttonStyle(.plain).help("Copy stream URL")
                            Button { if let u = URL(string: cam.url) { NSWorkspace.shared.open(u) } } label: {
                                Image(systemName: "arrow.up.forward.app").font(.system(size: 11)).foregroundStyle(Brand.ember500)
                            }.buttonStyle(.plain).help("Open in your default player (IINA/VLC)")
                        }
                        if cam.kind == "rtsp_url" {
                            Text("Resin RTSP streams are nonstandard — open at most one viewer.")
                                .font(Brand.body(10)).foregroundStyle(Brand.bone400)
                        }
                    } else {
                        Text("No camera reported by this printer.").font(Brand.body(11)).foregroundStyle(Brand.bone400)
                    }
                } else {
                    Text("Streams open in your external player — macOS can't render RTSP/MJPEG inline.")
                        .font(Brand.body(11)).foregroundStyle(Brand.bone400)
                }
            }
        }
    }

    // MARK: prepare — numbered pipeline
    private var preparePanel: some View {
        let hasModel = !model.fabModelPath.isEmpty
        let analyzed = model.fabReport != nil
        let hasProfile = !model.fabProfilePath.isEmpty
        return FabPanel(title: "Prepare · Model → Print") {
            VStack(alignment: .leading, spacing: 0) {
                stepRow(1, "Model", done: hasModel, active: !hasModel) {
                    HStack(spacing: 8) {
                        FabButton(title: "Choose STL", icon: "cube", compact: true) { model.fabPickModel() }
                        Text(hasModel ? (model.fabModelPath as NSString).lastPathComponent : "no model selected")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(hasModel ? Brand.bone100 : Brand.bone400).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                stepConnector
                stepRow(2, "Analyze — mesh gate", done: analyzed, active: hasModel && !analyzed) {
                    VStack(alignment: .leading, spacing: 10) {
                        FabButton(title: model.fabAnalyzing ? "Analyzing…" : "Run Analysis", icon: "waveform.path.ecg",
                                  enabled: hasModel && !model.fabAnalyzing, compact: true) { model.fabAnalyze() }
                        if model.fabAnalyzing { FabIndeterminateBar().frame(maxWidth: 320) }
                        if let r = model.fabReport { reportGrid(r) }
                    }
                }
                stepConnector
                stepRow(3, "Slicer Profile", done: hasProfile, active: analyzed && !hasProfile) {
                    HStack(spacing: 8) {
                        FabButton(title: "Profile .ini", icon: "slider.horizontal.3", compact: true) { model.fabPickProfile() }
                        Text(hasProfile ? (model.fabProfilePath as NSString).lastPathComponent : "resin requires a profile; FDM optional")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(hasProfile ? Brand.bone100 : Brand.bone400).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                stepConnector
                stepRow(4, "Slice → Queue", done: false, active: analyzed) {
                    VStack(alignment: .leading, spacing: 6) {
                        FabButton(title: model.fabSlicing ? "Slicing…" : "Slice → Queue", icon: "square.stack.3d.up",
                                  style: .primary, enabled: hasModel && !model.fabSlicing) { model.fabSlice(printerID: printer.id) }
                        if model.fabSlicing {
                            FabIndeterminateBar().frame(maxWidth: 320)
                            Text("Slicing can take a minute or two on detailed models — this stays live.")
                                .font(Brand.body(10)).foregroundStyle(Brand.cyan500)
                        } else {
                            Text("Runs the official PrusaSlicer + UVtools (must be installed at /Applications). Nothing is downloaded.")
                                .font(Brand.body(10)).foregroundStyle(Brand.bone400)
                        }
                    }
                }
            }
        }
    }

    private func stepRow<C: View>(_ n: Int, _ title: String, done: Bool, active: Bool, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 12) {
            FabStepBadge(n: n, done: done, active: active)
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(1.4)
                    .foregroundStyle(active ? Brand.bone100 : Brand.bone300)
                content()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }

    private var stepConnector: some View {
        Rectangle().fill(Brand.line1).frame(width: 1, height: 12).padding(.leading, 10)
    }

    // MARK: analyze report — a proper engineering grid
    private func reportGrid(_ r: FabModelReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: r.passes ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .font(.system(size: 12)).foregroundStyle(r.passes ? Brand.success : Brand.error)
                Text(r.passes ? "SLICEABLE SOLID" : "NOT PRINTABLE — REPAIR FIRST")
                    .font(.system(size: 10, weight: .heavy)).kerning(1.6)
                    .foregroundStyle(r.passes ? Brand.success : Brand.error)
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 24) {
                reportColumn("TOPOLOGY", [
                    ("Watertight", r.watertight ? "YES" : "NO", r.watertight ? Brand.success : Brand.error),
                    ("Boundary edges", "\(r.boundaryEdges)", r.boundaryEdges == 0 ? Brand.bone100 : Brand.error),
                    ("Non-manifold", "\(r.nonManifoldEdges)", r.nonManifoldEdges == 0 ? Brand.bone100 : Brand.error),
                ])
                reportColumn("GEOMETRY", [
                    ("Triangles", "\(r.triangles)", Brand.bone100),
                    ("Vertices", "\(r.vertices)", Brand.bone100),
                    ("Bounding box", r.dims, Brand.cyan500),
                ])
                reportColumn("MASS · SUPPORT", [
                    ("Volume", String(format: "%.2f cm³", r.volumeCM3), Brand.cyan500),
                    ("≈ Resin", String(format: "%.1f ml", r.volumeCM3), Brand.bone100),
                    // PLA ≈ 1.24 g/cm³ — a real derived estimate, model volume only (excludes supports/infill).
                    ("≈ Filament", String(format: "%.0f g PLA", r.volumeCM3 * 1.24), Brand.bone100),
                    ("Overhang area", "\(Int((r.overhangFraction * 100).rounded()))%", r.overhangFraction > 0.25 ? Brand.warning : Brand.bone100),
                ])
            }
            if !r.notes.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(r.notes.enumerated()), id: \.offset) { _, note in
                        Text("• \(note)").font(Brand.body(11)).foregroundStyle(Brand.bone200)
                    }
                }
            }
        }
        .padding(12)
        .background(Brand.ink600, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Brand.line1, lineWidth: 1))
    }

    private func reportColumn(_ title: String, _ rows: [(String, String, Color)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 8.5, weight: .bold)).kerning(1.4).foregroundStyle(Brand.bone400)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    Text(row.0).font(.system(size: 10)).foregroundStyle(Brand.bone300)
                    Spacer(minLength: 8)
                    Text(row.1).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(row.2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func fabStateColor(_ s: String) -> Color {
    switch s {
    case "printing": return Brand.cyan500
    case "paused": return Brand.warning
    case "complete": return Brand.success
    case "error", "failed": return Brand.error
    case "offline", "unknown", "cancelled": return Brand.ink500
    default: return Brand.ok
    }
}

/// Job-state color (distinct from printer-state: sliced/uploaded are in-flight ember).
private func jobStateColor(_ s: String) -> Color {
    switch s {
    case "printing": return Brand.cyan500
    case "complete": return Brand.success
    case "failed": return Brand.error
    case "cancelled": return Brand.bone400
    case "sliced", "uploaded": return Brand.ember400
    default: return Brand.bone300
    }
}

// MARK: - job table (rectangular rows, inline actions)

private struct JobActions {
    let onStart: (FabJobItem) -> Void
}

private struct JobTable: View {
    @ObservedObject var model: AppModel
    let jobs: [FabJobItem]
    let showPrinter: Bool
    let cockpit: JobActions?

    @State private var hoveredJob: String?

    var body: some View {
        VStack(spacing: 0) {
            // header row
            HStack(spacing: 10) {
                col("JOB", width: nil)
                if showPrinter { col("PRINTER", width: 110) }
                col("STATE", width: 84)
                col("VALIDATION", width: nil)
                col("UPDATED", width: 74)
                col("ACTION", width: 130, trailing: true)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            Rectangle().fill(Brand.line1).frame(height: 1)
            ForEach(Array(jobs.enumerated()), id: \.element.id) { i, job in
                HStack(spacing: 10) {
                    Text(job.name).font(Brand.body(12, weight: .medium)).foregroundStyle(Brand.bone50)
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    if showPrinter {
                        Text(model.fabPrinters.first { $0.id == job.printerID }?.name ?? job.printerID)
                            .font(Brand.body(11)).foregroundStyle(Brand.bone300).lineLimit(1).frame(width: 110, alignment: .leading)
                    }
                    Text(job.state.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced)).kerning(0.8)
                        .foregroundStyle(jobStateColor(job.state))
                        .frame(width: 84, alignment: .leading)
                    Text(job.validation.split(separator: "\n").first.map(String.init) ?? "—")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(Brand.bone400)
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text(fabRelTime(job.updatedMs)).font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Brand.bone400).frame(width: 74, alignment: .leading)
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        actions(job)
                    }.frame(width: 130, alignment: .trailing)
                }
                .padding(.horizontal, 8).padding(.vertical, 8)
                .background(hoveredJob == job.id ? Brand.ink600 : .clear)
                .onHover { hoveredJob = $0 ? job.id : (hoveredJob == job.id ? nil : hoveredJob) }
                if i < jobs.count - 1 { Rectangle().fill(Brand.line1).frame(height: 1) }
            }
        }
    }

    private func col(_ t: String, width: CGFloat?, trailing: Bool = false) -> some View {
        Text(t).font(.system(size: 8.5, weight: .bold)).kerning(1.2).foregroundStyle(Brand.bone400)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: trailing ? .trailing : .leading)
            .frame(width: width, alignment: trailing ? .trailing : .leading)
    }

    @ViewBuilder private func actions(_ job: FabJobItem) -> some View {
        switch job.state {
        case "sliced":
            FabButton(title: "Upload", icon: "arrow.up.circle", enabled: !model.fabBusy, compact: true) { model.fabUpload(jobID: job.id) }
        case "uploaded":
            if let ck = cockpit {
                FabButton(title: "Start", icon: "play.fill", style: .primary, enabled: !model.fabBusy, compact: true) { ck.onStart(job) }
            } else {
                Text("open printer").font(.system(size: 9)).foregroundStyle(Brand.bone400)
            }
        case "complete", "failed", "cancelled":
            FabButton(title: job.awaitsClearance ? "Plate Cleared" : "Dismiss",
                      style: job.awaitsClearance ? .primary : .ghost, compact: true) { model.fabClearJob(job.id) }
        default:
            EmptyView()
        }
    }
}

// MARK: - printer card (ALL view)

private struct FabPrinterCard: View {
    let printer: FabPrinter
    let onOpen: () -> Void
    let onRemove: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                // header strip with accent spine
                HStack(spacing: 0) {
                    Rectangle().fill(fabStateColor(printer.state)).frame(width: 2, height: 12)
                    StatusDot(color: fabStateColor(printer.state), glow: printer.isActive, size: 7).padding(.leading, 8)
                    Text(printer.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Brand.bone50).lineLimit(1).padding(.leading, 7)
                    Spacer(minLength: 8)
                    Text(printer.state.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced)).kerning(1.0)
                        .foregroundStyle(fabStateColor(printer.state) == Brand.ink500 ? Brand.bone400 : fabStateColor(printer.state))
                }
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 10)
                Rectangle().fill(Brand.line1).frame(height: 1)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        FabTag(text: printer.kind)
                        if !printer.model.isEmpty { Text(printer.model).font(Brand.body(11)).foregroundStyle(Brand.bone300).lineLimit(1) }
                        Spacer(minLength: 0)
                    }
                    if printer.state == "printing" || printer.state == "paused" {
                        ThinProgressBar(value: printer.progress ?? 0, tint: Brand.cyan500).frame(height: 4)
                        HStack(spacing: 16) {
                            if let c = printer.currentLayer, let t = printer.totalLayers { mini("LAYER", "\(c)/\(t)") }
                            if let s = printer.timeLeftSecs { mini("ETA", fabETA(s)) }
                            Spacer(minLength: 0)
                            Text("OPEN →").font(.system(size: 8, weight: .bold, design: .monospaced)).kerning(1.2).foregroundStyle(Brand.ember500)
                        }
                    } else {
                        HStack {
                            Text(printer.host.isEmpty ? "no address" : printer.host).font(.system(size: 10, design: .monospaced)).foregroundStyle(Brand.bone400)
                            Spacer(minLength: 0)
                            Text("OPEN →").font(.system(size: 8, weight: .bold, design: .monospaced)).kerning(1.2)
                                .foregroundStyle(hover ? Brand.ember400 : Brand.ember500)
                        }
                    }
                }
                .padding(12)
            }
            .background(hover ? Brand.ink600 : Brand.ink700, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(printer.isActive ? Brand.cyan700 : (hover ? Brand.line2 : Brand.line1), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Brand.ease(0.15)) { hover = h } }
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) { Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Brand.bone400) }
                .buttonStyle(.plain).padding(9).opacity(hover ? 1 : 0)
        }
    }

    private func mini(_ k: String, _ v: String) -> some View {
        HStack(spacing: 5) {
            Text(k).font(.system(size: 8.5, weight: .semibold)).kerning(1.0).foregroundStyle(Brand.bone400)
            Text(v).font(.system(size: 11, weight: .semibold, design: .monospaced)).monospacedDigit().foregroundStyle(Brand.cyan500)
        }
    }
}

// MARK: - add printer sheet (rectangular)

private struct AddPrinterSheet: View {
    @ObservedObject var model: AppModel
    @State private var name = ""
    @State private var kind = "sdcp"
    @State private var host = ""
    @State private var printerModel = ""
    @State private var apiKeyEnv = ""
    @State private var probeHost = ""

    private let kinds = [
        ("sdcp", "Elegoo / SDCP"), ("octoprint", "OctoPrint"),
        ("moonraker", "Moonraker (Klipper)"), ("mock", "Mock (simulator)"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("ADD PRINTER").font(.system(size: 12, weight: .semibold)).kerning(2.5).foregroundStyle(Brand.bone300)
                Spacer()
                Button { model.fabAddSheetOpen = false } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.bone400)
                }.buttonStyle(.plain)
            }

            FabPanel(title: "Discover · SDCP") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        FabButton(title: model.fabDiscovering ? "Scanning…" : "Scan Network", icon: "dot.radiowaves.left.and.right",
                                  enabled: !model.fabDiscovering, compact: true) { model.fabDiscover() }
                        field("or probe an IP, e.g. 192.168.1.44", text: $probeHost, mono: true)
                        FabButton(title: "Probe",
                                  enabled: !probeHost.trimmingCharacters(in: .whitespaces).isEmpty, compact: true) { model.fabDiscover(host: probeHost) }
                    }
                    // Network context — tells the user what network their Mac is on (and flags the
                    // iPhone-hotspot trap where devices can't see each other).
                    if let ln = model.fabLocalNet {
                        HStack(spacing: 6) {
                            StatusDot(color: ln.isHotspot ? Brand.ember500 : Brand.bone400, size: 5)
                            Text(ln.isHotspot
                                 ? "Your Mac is on an iPhone Personal Hotspot (\(ln.cidr)) — devices are isolated and can't see each other. Put the Mac and printer on the same Wi‑Fi router."
                                 : "Your Mac: \(ln.cidr). The printer must be on this same network.")
                                .font(Brand.body(10)).foregroundStyle(ln.isHotspot ? Brand.bone200 : Brand.bone400)
                            Spacer(minLength: 0)
                        }
                    }
                    if model.fabDiscovered.isEmpty && !model.fabDiscovering && model.fabDiag == nil {
                        Text("Nothing yet. Scan finds Elegoo/SDCP printers on your Wi‑Fi; if it comes up empty, "
                             + "enter the printer's IP (from its Network screen) and Probe.")
                            .font(Brand.body(11)).foregroundStyle(Brand.bone400)
                    }
                    if model.fabDiagTesting {
                        HStack(spacing: 6) { ProgressView().controlSize(.small)
                            Text("Testing reachability…").font(Brand.body(11)).foregroundStyle(Brand.bone300) }
                    }
                    if let diag = model.fabDiag { diagnosisView(diag) }
                    ForEach(Array(model.fabDiscovered.enumerated()), id: \.offset) { _, d in
                        HStack(spacing: 8) {
                            StatusDot(color: Brand.ok, size: 6)
                            Text(d["model"] ?? d["name"] ?? "printer").font(Brand.body(12, weight: .medium)).foregroundStyle(Brand.bone50)
                            Text(d["ip"] ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(Brand.cyan500)
                            Spacer(minLength: 0)
                            FabButton(title: "Add", style: .primary, compact: true) {
                                model.fabAddPrinter(name: d["name"]?.isEmpty == false ? d["name"]! : (d["model"] ?? "Printer"),
                                                    kind: "sdcp", host: d["ip"] ?? "", model: d["model"] ?? "", mainboardID: d["mainboard_id"] ?? "")
                                model.fabAddSheetOpen = false
                            }
                        }
                    }
                }
            }

            FabPanel(title: "Manual") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        field("Name", text: $name, mono: false)
                        Picker("", selection: $kind) { ForEach(kinds, id: \.0) { k in Text(k.1).tag(k.0) } }
                            .pickerStyle(.menu).labelsHidden().fixedSize()
                    }
                    if kind != "mock" {
                        HStack(spacing: 8) {
                            field("Host / IP (e.g. 192.168.1.44 or octopi.local)", text: $host, mono: true)
                            // Test the connection FIRST — reports exactly why it can't reach the
                            // printer instead of silently saving an offline device.
                            FabButton(title: model.fabDiagTesting ? "Testing…" : "Test", icon: "bolt.horizontal",
                                      enabled: !host.trimmingCharacters(in: .whitespaces).isEmpty && !model.fabDiagTesting, compact: true) {
                                model.fabTestConnection(host: host, kind: kind)
                            }
                        }
                        field("Printer model (drives slicing format, e.g. ELEGOO Saturn 4 Ultra)", text: $printerModel, mono: false)
                    }
                    if kind == "octoprint" || kind == "moonraker" {
                        field("API-key env var (must start with GINEXUS_FAB_; key stays in env, never on disk)", text: $apiKeyEnv, mono: true)
                    }
                    if let diag = model.fabDiag, kind != "mock" { diagnosisView(diag) }
                    HStack {
                        Spacer(minLength: 0)
                        FabButton(title: "Add Printer", icon: "plus", style: .primary,
                                  enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty && (kind == "mock" || !host.trimmingCharacters(in: .whitespaces).isEmpty)) {
                            model.fabAddPrinter(name: name, kind: kind, host: host, model: printerModel, apiKeyEnv: apiKeyEnv)
                            model.fabAddSheetOpen = false
                        }
                    }
                }
            }

            if let e = model.fabError {
                HStack(spacing: 8) {
                    StatusDot(color: Brand.ember500, size: 5)
                    Text(e).font(Brand.body(11)).foregroundStyle(Brand.bone300)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(20).frame(width: 580).background(Brand.ink900).preferredColorScheme(.dark)
        .onAppear { model.fabRefreshLocalNet(); model.fabDiag = nil }
    }

    /// A reachability verdict — flat ink panel with a hairline, ember for "attention" and the
    /// muted connection dot for OK. No fills, no colored borders (the app's established grammar).
    private func diagnosisView(_ d: FabDiagnosis) -> some View {
        let attention = d.severity != "ok"
        return HStack(alignment: .top, spacing: 9) {
            StatusDot(color: attention ? Brand.ember500 : Brand.ok, size: 6).padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(d.summary).font(Brand.body(12, weight: .semibold)).foregroundStyle(Brand.bone50)
                Text(d.detail).font(Brand.body(11)).foregroundStyle(Brand.bone300)
                if d.severity == "error" {
                    Button {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                            NSWorkspace.shared.open(u)
                        }
                    } label: {
                        Text("Open Local Network settings").font(Brand.body(10, weight: .semibold)).foregroundStyle(Brand.ember500)
                    }.buttonStyle(.plain).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12).background(Brand.ink700, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.line1, lineWidth: 1))
    }

    private func field(_ placeholder: String, text: Binding<String>, mono: Bool) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(mono ? Brand.mono(12) : Brand.body(13)).foregroundStyle(Brand.bone50)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Brand.ink600, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Brand.line1, lineWidth: 1))
    }
}
