// FabricationView.swift — the SP-FAB manufacturing cockpit. ALL view = the printer fleet at a
// glance; selecting a printer opens its workstation: live telemetry, camera, physical controls,
// and a model-prep pipeline (pick STL → analyze the mesh → slice → queue → upload → start).
// Silo Unison recipe; OMNISCIENT cyan reserved for LIVE telemetry VALUES; ember = chrome/actions.
// Physical START/RESUME/CANCEL go through an explicit readiness confirmation — that deliberate
// human click is the approval a hard-gated action requires.
import SwiftUI
import AppKit
import GinexusCore

struct FabricationView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 22).padding(.top, 26).padding(.bottom, 12)
            Divider().overlay(Brand.line1)
            if model.fabPrinters.isEmpty {
                emptyState
            } else {
                fleetTabs
                    .padding(.horizontal, 22).padding(.vertical, 10)
                if let sel = model.fabSelectedID,
                   let printer = model.fabPrinters.first(where: { $0.id == sel }) {
                    PrinterCockpit(model: model, printer: printer)
                } else {
                    fleetOverview
                }
            }
            if let n = model.fabNotice { noticeBar(n, color: Brand.success) }
            if let e = model.fabError { noticeBar(e, color: Brand.error) }
        }
        .sheet(isPresented: $model.fabAddSheetOpen) { AddPrinterSheet(model: model) }
    }

    // MARK: header
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            StampText(text: "FABRICATION BAY", size: 13, ember: "BAY")
            if printingCount > 0 {
                HStack(spacing: 5) {
                    StatusDot(color: Brand.cyan500, glow: true, size: 6)
                    Text("\(printingCount) PRINTING")
                        .font(Brand.mono(10, weight: .semibold)).kerning(1.2)
                        .foregroundStyle(Brand.cyan500)
                }
            }
            Spacer(minLength: 0)
            if model.fabLoading {
                Text("SYNC").font(Brand.mono(9, weight: .semibold)).kerning(1.5)
                    .foregroundStyle(Brand.bone400)
            }
            Button { model.refreshFab() } label: { BrandChip(icon: "arrow.clockwise", label: "Refresh") }
                .buttonStyle(.plain).help("Poll the fleet now")
            EmberButton(title: "Add Printer", icon: "plus") { model.fabAddSheetOpen = true }
        }
    }

    private var printingCount: Int { model.fabPrinters.filter { $0.state == "printing" }.count }

    private func noticeBar(_ text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: color == Brand.error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11)).foregroundStyle(color)
            Text(text).font(Brand.body(12)).foregroundStyle(Brand.bone100)
            Spacer(minLength: 0)
            Button {
                if color == Brand.error { model.fabError = nil } else { model.fabNotice = nil }
            } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Brand.bone400) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 22).padding(.vertical, 9)
        .background(Brand.ink850)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Brand.line1), alignment: .top)
    }

    // MARK: empty state
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            GlyphMark(size: 40)
            StampText(text: "NO PRINTERS IN THE FLEET", size: 11)
            Text("Discover Elegoo/SDCP printers on your network, or add OctoPrint, Moonraker, "
                 + "or a mock printer by address. Then pick a printer to open its workstation.")
                .font(Brand.body(13)).foregroundStyle(Brand.bone300)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
            HStack(spacing: 10) {
                EmberButton(title: "Add Printer", icon: "plus") { model.fabAddSheetOpen = true }
                Button { model.fabAddSheetOpen = true; model.fabDiscover() } label: {
                    TacticalLabel(text: "Discover", icon: "dot.radiowaves.left.and.right")
                }.buttonStyle(.plain)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: fleet tabs — ALL + one per printer
    private var fleetTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                fleetTab(nil, label: "ALL")
                ForEach(model.fabPrinters) { p in fleetTab(p.id, label: p.name.uppercased()) }
            }
        }
    }

    private func fleetTab(_ id: String?, label: String) -> some View {
        let selected = model.fabSelectedID == id
        return Button {
            withAnimation(Brand.ease(0.18)) {
                model.fabSelectedID = id
                model.fabCamera = nil; model.fabNotice = nil; model.fabError = nil
            }
        } label: {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold)).kerning(1.4)
                .foregroundStyle(selected ? Brand.bone50 : Brand.bone300)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Brand.ink600 : Brand.ink700, in: Capsule())
                .overlay(Capsule().stroke(selected ? Brand.ember700 : Brand.line1, lineWidth: 1))
                .contentShape(Capsule())
        }.buttonStyle(.plain)
    }

    // MARK: ALL view — rack + global queue
    private var fleetOverview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                    ForEach(model.fabPrinters) { p in
                        FabPrinterCard(printer: p,
                                       onOpen: { withAnimation(Brand.ease(0.18)) { model.fabSelectedID = p.id } },
                                       onRemove: { model.fabRemovePrinter(p.id) })
                    }
                }
                Panel(title: "ALL JOBS") {
                    if model.fabJobs.isEmpty {
                        Text("No fabrication jobs yet. Open a printer to prepare and slice a model.")
                            .font(Brand.body(12)).foregroundStyle(Brand.bone300)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(model.fabJobs.enumerated()), id: \.element.id) { i, job in
                                FabJobRow(job: job,
                                          printerName: model.fabPrinters.first { $0.id == job.printerID }?.name ?? job.printerID) {
                                    model.fabClearJob(job.id)
                                }
                                if i < model.fabJobs.count - 1 { Divider().overlay(Brand.line1) }
                            }
                        }
                    }
                }
                safetyStamp
            }
            .padding(.horizontal, 22).padding(.bottom, 24)
        }
    }

    private var safetyStamp: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(Brand.bone400)
            Text("START · RESUME · PLATE-CLEAR always ask you to confirm the machine is physically ready — PAUSE is instant")
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
                telemetryPanel
                controlsPanel
                cameraPanel
                preparePanel
                jobsPanel
            }
            .padding(.horizontal, 22).padding(.vertical, 4).padding(.bottom, 24)
        }
        .confirmationDialog("Start this print?", isPresented: Binding(
            get: { confirmStartJob != nil }, set: { if !$0 { confirmStartJob = nil } }
        ), presenting: confirmStartJob) { job in
            Button("Printer is ready — start", role: .destructive) {
                model.fabStart(jobID: job.id); confirmStartJob = nil
            }
            Button("Cancel", role: .cancel) { confirmStartJob = nil }
        } message: { _ in
            Text("Confirm the machine is physically ready: resin in the vat (or filament loaded), "
                 + "build plate installed, previous part removed, and the lid/cover closed. "
                 + "The printer cannot sense these — starting is irreversible.")
        }
        .confirmationDialog("Cancel the active print?", isPresented: $confirmCancel) {
            Button("Cancel the print", role: .destructive) {
                let activeJob = jobs.first { $0.state == "printing" }?.id ?? ""
                model.fabCancel(printerID: printer.id, jobID: activeJob); confirmCancel = false
            }
            Button("Keep printing", role: .cancel) { confirmCancel = false }
        } message: { Text("This stops the print and destroys the in-progress part. It cannot be undone.") }
    }

    // MARK: telemetry
    private var telemetryPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    StatusDot(color: stateColor, glow: printer.isActive, size: 9)
                    Text(printer.name).font(Brand.body(17, weight: .semibold)).foregroundStyle(Brand.bone50)
                    BrandChip(label: printer.kind.uppercased())
                    Spacer(minLength: 0)
                    Text(printer.state.uppercased())
                        .font(Brand.mono(11, weight: .semibold)).kerning(1.6)
                        .foregroundStyle(stateColor == Brand.ink500 ? Brand.bone400 : stateColor)
                }
                if !printer.model.isEmpty {
                    Text(printer.model).font(Brand.body(12)).foregroundStyle(Brand.bone300)
                }
                if printer.state == "printing" || printer.state == "paused" {
                    ThinProgressBar(value: printer.progress ?? 0, tint: Brand.cyan500)
                    HStack(spacing: 22) {
                        if let c = printer.currentLayer, let t = printer.totalLayers { metric("LAYER", "\(c) / \(t)") }
                        if let p = printer.progress { metric("PROGRESS", "\(Int((p * 100).rounded()))%") }
                        if let s = printer.timeLeftSecs { metric("TIME LEFT", fabETA(s)) }
                        Spacer(minLength: 0)
                    }
                    if let j = printer.jobName, !j.isEmpty {
                        Text(j).font(Brand.mono(10)).foregroundStyle(Brand.bone300).lineLimit(1)
                    }
                } else {
                    HStack(spacing: 22) {
                        metric("HOST", printer.host.isEmpty ? "—" : printer.host)
                        if let d = printer.detail, !d.isEmpty { metric("STATUS", d) }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func metric(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key).font(Brand.mono(9, weight: .semibold)).kerning(1.3).foregroundStyle(Brand.bone400)
            Text(value).font(Brand.mono(13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(printer.isActive ? Brand.cyan500 : Brand.bone100)
        }
    }

    private var stateColor: Color {
        switch printer.state {
        case "printing": return Brand.cyan500
        case "paused": return Brand.warning
        case "complete": return Brand.success
        case "error": return Brand.error
        case "offline", "unknown": return Brand.ink500
        default: return Brand.ok
        }
    }

    // MARK: controls
    private var controlsPanel: some View {
        Panel(title: "CONTROLS") {
            HStack(spacing: 10) {
                // Pause is the safe action — always available while printing.
                Button { model.fabPause(printerID: printer.id) } label: {
                    TacticalLabel(text: "Pause", icon: "pause.fill")
                }
                .buttonStyle(.plain)
                .disabled(printer.state != "printing" || model.fabBusy)
                .opacity(printer.state == "printing" ? 1 : 0.4)

                Button { model.fabResume(printerID: printer.id) } label: {
                    TacticalLabel(text: "Resume", icon: "play.fill", filled: true)
                }
                .buttonStyle(.plain)
                .disabled(printer.state != "paused" || model.fabBusy)
                .opacity(printer.state == "paused" ? 1 : 0.4)

                Button { confirmCancel = true } label: {
                    TacticalLabel(text: "Cancel", icon: "stop.fill", tint: Brand.hi500)
                }
                .buttonStyle(.plain)
                .disabled(!(printer.state == "printing" || printer.state == "paused") || model.fabBusy)
                .opacity((printer.state == "printing" || printer.state == "paused") ? 1 : 0.4)

                Spacer(minLength: 0)
                DestructiveIconButton(icon: "trash", size: 12, help: "Remove printer") {
                    model.fabRemovePrinter(printer.id)
                    model.fabSelectedID = nil
                }
            }
        }
    }

    // MARK: camera
    private var cameraPanel: some View {
        Panel(title: "CAMERA") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button { model.fabLoadCamera(printerID: printer.id) } label: {
                        TacticalLabel(text: "Get Stream", icon: "video.fill")
                    }.buttonStyle(.plain)
                    if let cam = model.fabCamera, cam.hasStream {
                        Text(cam.kind.replacingOccurrences(of: "_url", with: "").uppercased())
                            .font(Brand.mono(9, weight: .semibold)).kerning(1.2).foregroundStyle(Brand.cyan500)
                    }
                    Spacer(minLength: 0)
                }
                if let cam = model.fabCamera {
                    if cam.hasStream {
                        HStack(spacing: 8) {
                            Text(cam.url).font(Brand.mono(11)).foregroundStyle(Brand.bone200).lineLimit(1)
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
                    Text("Streams open in your external player — inline RTSP/MJPEG isn't supported by macOS natively.")
                        .font(Brand.body(11)).foregroundStyle(Brand.bone400)
                }
            }
        }
    }

    // MARK: prepare — model → analyze → slice
    private var preparePanel: some View {
        Panel(title: "PREPARE · MODEL") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button { model.fabPickModel() } label: { TacticalLabel(text: "Choose STL", icon: "cube") }
                        .buttonStyle(.plain)
                    if !model.fabModelPath.isEmpty {
                        Text((model.fabModelPath as NSString).lastPathComponent)
                            .font(Brand.mono(11)).foregroundStyle(Brand.bone100).lineLimit(1)
                    } else {
                        Text("no model selected").font(Brand.body(11)).foregroundStyle(Brand.bone400)
                    }
                    Spacer(minLength: 0)
                    Button { model.fabAnalyze() } label: {
                        TacticalLabel(text: model.fabAnalyzing ? "Analyzing…" : "Analyze", icon: "waveform.path.ecg")
                    }
                    .buttonStyle(.plain).disabled(model.fabModelPath.isEmpty || model.fabAnalyzing)
                }

                if let r = model.fabReport { reportCard(r) }

                Divider().overlay(Brand.line1)
                HStack(spacing: 8) {
                    Button { model.fabPickProfile() } label: { TacticalLabel(text: "Profile .ini", icon: "slider.horizontal.3") }
                        .buttonStyle(.plain)
                    if !model.fabProfilePath.isEmpty {
                        Text((model.fabProfilePath as NSString).lastPathComponent)
                            .font(Brand.mono(11)).foregroundStyle(Brand.bone100).lineLimit(1)
                    } else {
                        Text("resin needs a profile; FDM optional").font(Brand.body(11)).foregroundStyle(Brand.bone400)
                    }
                    Spacer(minLength: 0)
                    EmberButton(title: model.fabSlicing ? "Slicing…" : "Slice → Queue", icon: "square.stack.3d.up",
                                enabled: !model.fabModelPath.isEmpty && !model.fabSlicing) {
                        model.fabSlice(printerID: printer.id)
                    }
                }
                Text("Slicing runs the official PrusaSlicer + UVtools (must be installed). Nothing is downloaded.")
                    .font(Brand.body(10)).foregroundStyle(Brand.bone400)
            }
        }
    }

    private func reportCard(_ r: FabModelReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: r.passes ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .font(.system(size: 12)).foregroundStyle(r.passes ? Brand.success : Brand.error)
                Text(r.passes ? "SLICEABLE SOLID" : "NOT PRINTABLE")
                    .font(Brand.mono(10, weight: .heavy)).kerning(1.8)
                    .foregroundStyle(r.passes ? Brand.success : Brand.error)
                Spacer(minLength: 0)
            }
            HStack(spacing: 22) {
                reportMetric("SIZE", r.dims)
                reportMetric("VOLUME", String(format: "%.2f cm³", r.volumeCM3))
                reportMetric("TRIANGLES", "\(r.triangles)")
                reportMetric("OVERHANG", "\(Int((r.overhangFraction * 100).rounded()))%")
                Spacer(minLength: 0)
            }
            ForEach(Array(r.notes.enumerated()), id: \.offset) { _, note in
                Text("• \(note)").font(Brand.body(11)).foregroundStyle(Brand.bone200)
            }
        }
        .padding(12)
        .background(Brand.ink600, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.line1, lineWidth: 1))
    }

    private func reportMetric(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key).font(Brand.mono(8, weight: .semibold)).kerning(1.2).foregroundStyle(Brand.bone400)
            Text(value).font(Brand.mono(12, weight: .semibold)).monospacedDigit().foregroundStyle(Brand.cyan500)
        }
    }

    // MARK: jobs (this printer) with inline actions
    private var jobsPanel: some View {
        Panel(title: "JOBS · THIS PRINTER") {
            if jobs.isEmpty {
                Text("No jobs yet. Prepare a model above, then Slice → Queue.")
                    .font(Brand.body(12)).foregroundStyle(Brand.bone300)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(jobs.enumerated()), id: \.element.id) { i, job in
                        cockpitJobRow(job)
                        if i < jobs.count - 1 { Divider().overlay(Brand.line1) }
                    }
                }
            }
        }
    }

    private func cockpitJobRow(_ job: FabJobItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(job.name).font(Brand.body(13, weight: .medium)).foregroundStyle(Brand.bone50).lineLimit(1)
                Text(job.state.uppercased()).font(Brand.mono(9, weight: .semibold)).kerning(1.2)
                    .foregroundStyle(jobStateColor(job.state))
                Spacer(minLength: 0)
                jobActions(job)
            }
            if !job.validation.isEmpty, let first = job.validation.split(separator: "\n").first {
                Text(String(first)).font(Brand.mono(9)).foregroundStyle(Brand.bone400).lineLimit(1)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private func jobActions(_ job: FabJobItem) -> some View {
        switch job.state {
        case "sliced":
            Button { model.fabUpload(jobID: job.id) } label: { TacticalLabel(text: "Upload", icon: "arrow.up.circle") }
                .buttonStyle(.plain).disabled(model.fabBusy)
        case "uploaded":
            Button { confirmStartJob = job } label: { TacticalLabel(text: "Start", icon: "play.fill", filled: true) }
                .buttonStyle(.plain).disabled(model.fabBusy)
        case "complete", "failed", "cancelled":
            Button { model.fabClearJob(job.id) } label: {
                TacticalLabel(text: job.awaitsClearance ? "Plate Cleared" : "Dismiss",
                              filled: job.awaitsClearance)
            }.buttonStyle(.plain)
        default:
            EmptyView()
        }
    }

    private func jobStateColor(_ s: String) -> Color {
        switch s {
        case "printing": return Brand.cyan500
        case "complete": return Brand.success
        case "failed": return Brand.error
        case "cancelled": return Brand.bone400
        case "uploaded", "sliced": return Brand.ember400
        default: return Brand.bone300
        }
    }
}

// MARK: - one printer card (ALL view)

private struct FabPrinterCard: View {
    let printer: FabPrinter
    let onOpen: () -> Void
    let onRemove: () -> Void
    @State private var hover = false

    private var stateColor: Color {
        switch printer.state {
        case "printing": return Brand.cyan500
        case "paused": return Brand.warning
        case "complete": return Brand.success
        case "error": return Brand.error
        case "offline", "unknown": return Brand.ink500
        default: return Brand.ok
        }
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusDot(color: stateColor, glow: printer.isActive, size: 7)
                    Text(printer.name).font(Brand.body(14, weight: .semibold)).foregroundStyle(Brand.bone50).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(printer.state.uppercased()).font(Brand.mono(9, weight: .semibold)).kerning(1.4)
                        .foregroundStyle(stateColor == Brand.ink500 ? Brand.bone400 : stateColor)
                }
                HStack(spacing: 6) {
                    BrandChip(label: printer.kind.uppercased())
                    if !printer.model.isEmpty {
                        Text(printer.model).font(Brand.body(11)).foregroundStyle(Brand.bone300).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                if printer.state == "printing" || printer.state == "paused" {
                    ThinProgressBar(value: printer.progress ?? 0, tint: Brand.cyan500)
                    HStack(spacing: 14) {
                        if let c = printer.currentLayer, let t = printer.totalLayers { telemetry("LAYER", "\(c)/\(t)") }
                        if let s = printer.timeLeftSecs { telemetry("ETA", fabETA(s)) }
                        Spacer(minLength: 0)
                        Text("OPEN →").font(Brand.mono(8, weight: .semibold)).kerning(1.4).foregroundStyle(Brand.ember500)
                    }
                } else {
                    HStack {
                        Text(printer.host.isEmpty ? "" : printer.host).font(Brand.mono(10)).foregroundStyle(Brand.bone400)
                        Spacer(minLength: 0)
                        Text("OPEN →").font(Brand.mono(8, weight: .semibold)).kerning(1.4)
                            .foregroundStyle(hover ? Brand.ember400 : Brand.ember500)
                    }
                }
            }
            .padding(14)
            .background(hover ? Brand.ink600 : Brand.ink700, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(printer.isActive ? Brand.cyan700 : (hover ? Brand.line2 : Brand.line1), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Brand.ease(0.15)) { hover = h } }
        .overlay(alignment: .topTrailing) {
            DestructiveIconButton(icon: "trash", size: 11, help: "Remove printer", action: onRemove)
                .padding(8).opacity(hover ? 1 : 0)
        }
    }

    private func telemetry(_ key: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(Brand.mono(9, weight: .semibold)).kerning(1.2).foregroundStyle(Brand.bone400)
            Text(value).font(Brand.mono(11, weight: .semibold)).monospacedDigit().foregroundStyle(Brand.cyan500)
        }
    }
}

// MARK: - one job row (ALL view, read-only + clear)

private struct FabJobRow: View {
    let job: FabJobItem
    let printerName: String
    let onClear: () -> Void

    private var stateColor: Color {
        switch job.state {
        case "printing": return Brand.cyan500
        case "complete": return Brand.success
        case "failed": return Brand.error
        case "cancelled": return Brand.bone400
        default: return Brand.bone300
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(job.name).font(Brand.body(12, weight: .medium)).foregroundStyle(Brand.bone50).lineLimit(1)
            Text(printerName).font(Brand.body(11)).foregroundStyle(Brand.bone300).lineLimit(1)
            Spacer(minLength: 0)
            Text(job.state.uppercased()).font(Brand.mono(9, weight: .semibold)).kerning(1.2).foregroundStyle(stateColor)
            if job.awaitsClearance {
                Button(action: onClear) { TacticalLabel(text: "Plate Cleared", filled: true) }
                    .buttonStyle(.plain).help("Confirm the finished part has been removed from the plate")
            } else if job.state == "failed" || job.state == "cancelled" {
                Button(action: onClear) { TacticalLabel(text: "Dismiss") }.buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - add printer sheet (discover + manual; manual is first-class for LAN-privacy blind spots)

private struct AddPrinterSheet: View {
    @ObservedObject var model: AppModel
    @State private var name = ""
    @State private var kind = "sdcp"
    @State private var host = ""
    @State private var printerModel = ""
    @State private var apiKeyEnv = ""
    @State private var probeHost = ""

    private let kinds = [
        ("sdcp", "Elegoo / SDCP"),
        ("octoprint", "OctoPrint"),
        ("moonraker", "Moonraker (Klipper)"),
        ("mock", "Mock (simulator)"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                StampText(text: "ADD PRINTER", size: 12)
                Spacer()
                Button { model.fabAddSheetOpen = false } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.bone400)
                }.buttonStyle(.plain)
            }

            Panel(title: "DISCOVER · SDCP") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Button { model.fabDiscover() } label: {
                            TacticalLabel(text: model.fabDiscovering ? "Scanning…" : "Scan Network",
                                          icon: "dot.radiowaves.left.and.right")
                        }.buttonStyle(.plain).disabled(model.fabDiscovering)
                        TextField("or probe an IP, e.g. 192.168.1.44", text: $probeHost)
                            .textFieldStyle(.plain).font(Brand.mono(12)).foregroundStyle(Brand.bone50)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Brand.ink600, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Brand.line1, lineWidth: 1))
                        Button { model.fabDiscover(host: probeHost) } label: { TacticalLabel(text: "Probe") }
                            .buttonStyle(.plain).disabled(probeHost.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if model.fabDiscovered.isEmpty && !model.fabDiscovering {
                        Text("Nothing yet. Broadcast can be blocked by VLANs or the macOS Local Network "
                             + "permission — probing the printer's IP always works.")
                            .font(Brand.body(11)).foregroundStyle(Brand.bone400)
                    }
                    ForEach(Array(model.fabDiscovered.enumerated()), id: \.offset) { _, d in
                        HStack(spacing: 8) {
                            StatusDot(color: Brand.ok, size: 6)
                            Text(d["model"] ?? d["name"] ?? "printer").font(Brand.body(12, weight: .medium)).foregroundStyle(Brand.bone50)
                            Text(d["ip"] ?? "").font(Brand.mono(11)).foregroundStyle(Brand.cyan500)
                            Spacer(minLength: 0)
                            Button {
                                model.fabAddPrinter(
                                    name: d["name"]?.isEmpty == false ? d["name"]! : (d["model"] ?? "Printer"),
                                    kind: "sdcp", host: d["ip"] ?? "", model: d["model"] ?? "",
                                    mainboardID: d["mainboard_id"] ?? "")
                                model.fabAddSheetOpen = false
                            } label: { TacticalLabel(text: "Add", filled: true) }.buttonStyle(.plain)
                        }
                    }
                }
            }

            Panel(title: "MANUAL") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        field("Name", text: $name, mono: false)
                        Picker("", selection: $kind) { ForEach(kinds, id: \.0) { k in Text(k.1).tag(k.0) } }
                            .pickerStyle(.menu).labelsHidden().fixedSize()
                    }
                    if kind != "mock" {
                        field("Host / IP (e.g. 192.168.1.44 or octopi.local)", text: $host, mono: true)
                        field("Printer model (drives slicing format, e.g. ELEGOO Saturn 4 Ultra)", text: $printerModel, mono: false)
                    }
                    if kind == "octoprint" || kind == "moonraker" {
                        field("API-key env var (must start with GINEXUS_FAB_; key stays in env, never on disk)", text: $apiKeyEnv, mono: true)
                    }
                    HStack {
                        Spacer(minLength: 0)
                        EmberButton(title: "Add Printer", icon: "plus",
                                    enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty
                                        && (kind == "mock" || !host.trimmingCharacters(in: .whitespaces).isEmpty)) {
                            model.fabAddPrinter(name: name, kind: kind, host: host, model: printerModel, apiKeyEnv: apiKeyEnv)
                            model.fabAddSheetOpen = false
                        }
                    }
                }
            }

            if let e = model.fabError { Text(e).font(Brand.body(11)).foregroundStyle(Brand.error) }
        }
        .padding(20).frame(width: 560).background(Brand.ink900).preferredColorScheme(.dark)
    }

    private func field(_ placeholder: String, text: Binding<String>, mono: Bool) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(mono ? Brand.mono(12) : Brand.body(13)).foregroundStyle(Brand.bone50)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Brand.ink600, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Brand.line1, lineWidth: 1))
    }
}
