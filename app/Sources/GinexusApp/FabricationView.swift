// FabricationView.swift — the SP-FAB console: the printer fleet, live telemetry, and the job
// queue, rendered in the Silo Unison recipe with OMNISCIENT's cyan as the live-data accent.
// Grammar: ember = chrome/actions/attention · cyan = live telemetry VALUES (numbers, progress)
// · mono + tabular figures for anything numeric · flat matte panels, hairlines, no glow.
// Physical actions (start/resume/clear) happen through the agent with Principal approval —
// this console observes, adds/removes printers, and clears finished plates (a human click IS
// the plate-clear confirmation).
import SwiftUI
import GinexusCore

struct FabricationView: View {
    @ObservedObject var model: AppModel

    private var shownPrinters: [FabPrinter] {
        guard let sel = model.fabSelectedID else { return model.fabPrinters }
        return model.fabPrinters.filter { $0.id == sel }
    }

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
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        printerRack
                        jobsPanel
                        safetyStamp
                    }
                    .padding(.horizontal, 22).padding(.bottom, 24)
                }
            }
        }
        .sheet(isPresented: $model.fabAddSheetOpen) { AddPrinterSheet(model: model) }
    }

    // MARK: header — stamp + live counts + actions
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
            Button { model.refreshFab() } label: {
                BrandChip(icon: "arrow.clockwise", label: "Refresh")
            }
            .buttonStyle(.plain).help("Poll the fleet now")
            EmberButton(title: "Add Printer", icon: "plus") { model.fabAddSheetOpen = true }
        }
    }

    private var printingCount: Int {
        model.fabPrinters.filter { $0.state == "printing" }.count
    }

    // MARK: empty state
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            GlyphMark(size: 40)
            StampText(text: "NO PRINTERS IN THE FLEET", size: 11)
            Text("Discover Elegoo/SDCP printers on your network, or add OctoPrint, Moonraker, "
                 + "or a mock printer by address. You can also just ask GINEXUS in chat.")
                .font(Brand.body(13)).foregroundStyle(Brand.bone300)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack(spacing: 10) {
                EmberButton(title: "Add Printer", icon: "plus") { model.fabAddSheetOpen = true }
                Button { model.fabAddSheetOpen = true; model.fabDiscover() } label: {
                    TacticalLabel(text: "Discover", icon: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(.plain)
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
                ForEach(model.fabPrinters) { p in
                    fleetTab(p.id, label: p.name.uppercased())
                }
            }
        }
    }

    private func fleetTab(_ id: String?, label: String) -> some View {
        let selected = model.fabSelectedID == id
        return Button {
            withAnimation(Brand.ease(0.18)) { model.fabSelectedID = id }
        } label: {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold)).kerning(1.4)
                .foregroundStyle(selected ? Brand.bone50 : Brand.bone300)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Brand.ink600 : Brand.ink700, in: Capsule())
                .overlay(Capsule().stroke(selected ? Brand.ember700 : Brand.line1, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: printer rack
    private var printerRack: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
            ForEach(shownPrinters) { p in
                FabPrinterCard(printer: p) { model.fabRemovePrinter(p.id) }
            }
        }
    }

    // MARK: jobs
    private var jobsPanel: some View {
        Panel(title: "JOB QUEUE") {
            if model.fabJobs.isEmpty {
                Text("No fabrication jobs. Ask GINEXUS to analyze and slice a model — "
                     + "starting a print always comes back to you for approval.")
                    .font(Brand.body(12)).foregroundStyle(Brand.bone300)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.fabJobs.enumerated()), id: \.element.id) { i, job in
                        FabJobRow(
                            job: job,
                            printerName: model.fabPrinters.first { $0.id == job.printerID }?.name
                                ?? job.printerID
                        ) { model.fabClearJob(job.id) }
                        if i < model.fabJobs.count - 1 {
                            Divider().overlay(Brand.line1)
                        }
                    }
                }
            }
        }
    }

    // MARK: safety stamp — state the doctrine where the operator can see it
    private var safetyStamp: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 10)).foregroundStyle(Brand.bone400)
            Text("START · RESUME · PLATE-CLEAR always require your approval — PAUSE is instant and free")
                .font(Brand.body(11)).foregroundStyle(Brand.bone400)
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }
}

// MARK: - one printer card
private struct FabPrinterCard: View {
    let printer: FabPrinter
    let onRemove: () -> Void

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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusDot(color: stateColor, glow: printer.isActive, size: 7)
                Text(printer.name)
                    .font(Brand.body(14, weight: .semibold)).foregroundStyle(Brand.bone50)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(printer.state.uppercased())
                    .font(Brand.mono(9, weight: .semibold)).kerning(1.4)
                    .foregroundStyle(stateColor == Brand.ink500 ? Brand.bone400 : stateColor)
                DestructiveIconButton(icon: "trash", size: 11, help: "Remove printer", action: onRemove)
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
                    if let c = printer.currentLayer, let t = printer.totalLayers {
                        telemetry("LAYER", "\(c)/\(t)")
                    }
                    if let p = printer.progress {
                        telemetry("DONE", "\(Int((p * 100).rounded()))%")
                    }
                    if let s = printer.timeLeftSecs {
                        telemetry("ETA", fabETA(s))
                    }
                    Spacer(minLength: 0)
                }
                if let job = printer.jobName, !job.isEmpty {
                    Text(job).font(Brand.mono(10)).foregroundStyle(Brand.bone300).lineLimit(1)
                }
            } else if let detail = printer.detail, !detail.isEmpty, printer.state == "error" {
                Text(detail).font(Brand.body(11)).foregroundStyle(Brand.error).lineLimit(2)
            } else if printer.state == "offline" {
                Text(printer.host.isEmpty ? "no address" : printer.host)
                    .font(Brand.mono(10)).foregroundStyle(Brand.bone400)
            }
        }
        .padding(14)
        .background(Brand.ink700, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(printer.isActive ? Brand.cyan700 : Brand.line1, lineWidth: 1))
    }

    /// Telemetry pair: dim uppercase key + CYAN tabular value (the one place cyan is law).
    private func telemetry(_ key: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(Brand.mono(9, weight: .semibold)).kerning(1.2)
                .foregroundStyle(Brand.bone400)
            Text(value).font(Brand.mono(11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Brand.cyan500)
        }
    }
}

// MARK: - one job row
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
            Text(job.name).font(Brand.body(12, weight: .medium)).foregroundStyle(Brand.bone50)
                .lineLimit(1)
            Text(printerName).font(Brand.body(11)).foregroundStyle(Brand.bone300).lineLimit(1)
            Spacer(minLength: 0)
            if !job.validation.isEmpty, let first = job.validation.split(separator: "\n").first {
                Text(String(first)).font(Brand.mono(9)).foregroundStyle(Brand.bone400)
                    .lineLimit(1).frame(maxWidth: 220, alignment: .trailing)
            }
            Text(job.state.uppercased())
                .font(Brand.mono(9, weight: .semibold)).kerning(1.2)
                .foregroundStyle(stateColor)
            if job.awaitsClearance {
                // A human clicking this IS the physical "plate is clear" confirmation.
                Button(action: onClear) { TacticalLabel(text: "Plate Cleared", filled: true) }
                    .buttonStyle(.plain)
                    .help("Confirm the finished part has been removed from the build plate")
            } else if job.state == "failed" || job.state == "cancelled" {
                Button(action: onClear) { TacticalLabel(text: "Dismiss") }
                    .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - add printer sheet (discover + manual — manual is first-class: macOS Local Network
// permission or a VLAN can silently blank broadcast discovery)
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
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Brand.bone400)
                }
                .buttonStyle(.plain)
            }

            // ── discovery ──
            Panel(title: "DISCOVER · SDCP") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Button { model.fabDiscover() } label: {
                            TacticalLabel(text: model.fabDiscovering ? "Scanning…" : "Scan Network",
                                          icon: "dot.radiowaves.left.and.right")
                        }
                        .buttonStyle(.plain).disabled(model.fabDiscovering)
                        TextField("or probe an IP, e.g. 192.168.1.44", text: $probeHost)
                            .textFieldStyle(.plain).font(Brand.mono(12))
                            .foregroundStyle(Brand.bone50)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Brand.ink600, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Brand.line1, lineWidth: 1))
                        Button { model.fabDiscover(host: probeHost) } label: {
                            TacticalLabel(text: "Probe")
                        }
                        .buttonStyle(.plain)
                        .disabled(probeHost.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if model.fabDiscovered.isEmpty && !model.fabDiscovering {
                        Text("Nothing yet. Broadcast can be blocked by VLANs or the macOS Local "
                             + "Network permission — probing the printer's IP always works.")
                            .font(Brand.body(11)).foregroundStyle(Brand.bone400)
                    }
                    ForEach(Array(model.fabDiscovered.enumerated()), id: \.offset) { _, d in
                        HStack(spacing: 8) {
                            StatusDot(color: Brand.ok, size: 6)
                            Text(d["model"] ?? d["name"] ?? "printer")
                                .font(Brand.body(12, weight: .medium)).foregroundStyle(Brand.bone50)
                            Text(d["ip"] ?? "").font(Brand.mono(11)).foregroundStyle(Brand.cyan500)
                            Spacer(minLength: 0)
                            Button {
                                model.fabAddPrinter(
                                    name: d["name"]?.isEmpty == false ? d["name"]! : (d["model"] ?? "Printer"),
                                    kind: "sdcp",
                                    host: d["ip"] ?? "",
                                    model: d["model"] ?? "",
                                    mainboardID: d["mainboard_id"] ?? ""
                                )
                                model.fabAddSheetOpen = false
                            } label: { TacticalLabel(text: "Add", filled: true) }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // ── manual ──
            Panel(title: "MANUAL") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        field("Name", text: $name, mono: false)
                        Picker("", selection: $kind) {
                            ForEach(kinds, id: \.0) { k in Text(k.1).tag(k.0) }
                        }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                    }
                    if kind != "mock" {
                        field("Host / IP (e.g. 192.168.1.44 or octopi.local)", text: $host, mono: true)
                        field("Printer model (drives slicing format, e.g. ELEGOO Saturn 4 Ultra)",
                              text: $printerModel, mono: false)
                    }
                    if kind == "octoprint" || kind == "moonraker" {
                        field("API-key env var name (key stays in Keychain/env — never on disk)",
                              text: $apiKeyEnv, mono: true)
                    }
                    HStack {
                        Spacer(minLength: 0)
                        EmberButton(title: "Add Printer", icon: "plus",
                                    enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty
                                        && (kind == "mock" || !host.trimmingCharacters(in: .whitespaces).isEmpty)) {
                            model.fabAddPrinter(name: name, kind: kind, host: host,
                                                model: printerModel, apiKeyEnv: apiKeyEnv)
                            model.fabAddSheetOpen = false
                        }
                    }
                }
            }

            if let e = model.fabError {
                Text(e).font(Brand.body(11)).foregroundStyle(Brand.error)
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(Brand.ink900)
        .preferredColorScheme(.dark)
    }

    private func field(_ placeholder: String, text: Binding<String>, mono: Bool) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(mono ? Brand.mono(12) : Brand.body(13))
            .foregroundStyle(Brand.bone50)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Brand.ink600, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Brand.line1, lineWidth: 1))
    }
}
