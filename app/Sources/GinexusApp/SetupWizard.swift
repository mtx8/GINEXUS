// SetupWizard.swift — the first-run Setup Assistant. Five steps: detect the machine → guide the
// Ollama runtime → choose a right-sized model → download it → apply. Mac-mini-first: the model
// step surfaces the hardware-appropriate recommendation (the 16 GB base mini can't run the 30B).
// Rectangular throughout (reuses FabComponents); no pills.
import SwiftUI
import AppKit
import GinexusCore

struct SetupWizard: View {
    @ObservedObject var model: AppModel

    private var probe: SetupProbe? { model.setupProbe }
    private var step: AppModel.SetupStep { model.setupStep }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Brand.line1).frame(height: 1)
            ScrollView { content.padding(24) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(Brand.line1).frame(height: 1)
            footer
        }
        .frame(width: 720, height: 620)
        .background(Brand.ink900)
        .preferredColorScheme(.dark)
        .onAppear { if probe == nil { model.runSetupProbe() } }
    }

    // MARK: header — title + step rail
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                GlyphMark(size: 18)
                Text("SETUP").font(.system(size: 14, weight: .semibold)).kerning(3).foregroundStyle(Brand.bone300)
                Text("ASSISTANT").font(.system(size: 14, weight: .semibold)).kerning(3).foregroundStyle(Brand.ember500)
                Spacer(minLength: 0)
                Text("GINEXUS runs AI locally on your Mac").font(Brand.body(11)).foregroundStyle(Brand.bone400)
            }
            HStack(spacing: 6) {
                ForEach(steps, id: \.0) { s in
                    HStack(spacing: 6) {
                        FabStepBadge(n: s.0 + 1, done: step.rawValue > s.0, active: step.rawValue == s.0)
                        Text(s.1).font(.system(size: 9, weight: .semibold)).kerning(1.0)
                            .foregroundStyle(step.rawValue == s.0 ? Brand.bone100 : Brand.bone400)
                        if s.0 < steps.count - 1 { Rectangle().fill(Brand.line1).frame(width: 18, height: 1) }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 16)
    }

    private var steps: [(Int, String)] {
        [(0, "SYSTEM"), (1, "RUNTIME"), (2, "MODEL"), (3, "DOWNLOAD"), (4, "READY")]
    }

    // MARK: content per step
    @ViewBuilder private var content: some View {
        switch step {
        case .system:   systemStep
        case .runtime:  runtimeStep
        case .model:    modelStep
        case .download: downloadStep
        case .ready:    readyStep
        }
    }

    // ── 1. SYSTEM ──
    private var systemStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle("Your machine", "GINEXUS detected your hardware to recommend a model that runs comfortably.")
            if let hw = probe?.hardware {
                FabPanel(title: "Detected") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 16) {
                        FabMetric(key: "CHIP", value: hw.chip)
                        FabMetric(key: "MEMORY", value: hw.ramLabel, live: true)
                        FabMetric(key: "USABLE FOR AI", value: hw.usableLabel, live: true)
                        FabMetric(key: "STORAGE", value: hw.storageLabel)
                        FabMetric(key: "CPU CORES", value: "\(hw.cpuCores)")
                        FabMetric(key: "ARCHITECTURE", value: hw.appleSilicon ? "Apple Silicon" : "Intel")
                    }
                }
                if let v = probe?.verdict {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 12)).foregroundStyle(Brand.success)
                        Text(v).font(Brand.body(12)).foregroundStyle(Brand.bone100)
                        Spacer(minLength: 0)
                    }
                    .padding(12).background(Brand.ink700, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.line1, lineWidth: 1))
                }
            } else {
                probingPlaceholder
            }
        }
    }

    // ── 2. RUNTIME (Ollama) ──
    private var runtimeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle("Local model runtime", "GINEXUS uses Ollama to run models on your Mac. Everything stays on-device.")
            if let d = probe?.deps {
                FabPanel(title: "Ollama", accent: d.ollamaReady ? Brand.success : Brand.warning) {
                    VStack(alignment: .leading, spacing: 10) {
                        FabDataRow(key: "Installed", value: d.ollamaInstalled ? "Yes" : "No",
                                   valueColor: d.ollamaInstalled ? Brand.success : Brand.warning)
                        FabDataRow(key: "Running", value: d.ollamaRunning ? "Yes\(d.ollamaVersion.map { " · v\($0)" } ?? "")" : "No",
                                   valueColor: d.ollamaRunning ? Brand.success : Brand.warning)
                        if !d.ollamaReady {
                            Rectangle().fill(Brand.line1).frame(height: 1)
                            Text(d.ollamaInstalled
                                 ? "Ollama is installed but not running. Start it, then re-check."
                                 : "Ollama isn't installed yet. Install it (one-time), then re-check.")
                                .font(Brand.body(12)).foregroundStyle(Brand.bone200)
                            HStack(spacing: 8) {
                                FabButton(title: "Download Ollama", icon: "arrow.down.circle") { model.setupOpenOllamaDownload() }
                                if d.homebrew {
                                    FabButton(title: "Copy brew command", icon: "doc.on.doc") { model.setupCopyBrewInstall() }
                                }
                                FabButton(title: model.setupProbing ? "Checking…" : "Re-check", icon: "arrow.clockwise",
                                          style: .primary, enabled: !model.setupProbing) { model.runSetupProbe() }
                            }
                            if let n = model.setupNotice {
                                Text(n).font(Brand.body(11)).foregroundStyle(Brand.cyan500)
                            }
                        } else {
                            Text("Ready — GINEXUS can download and run models.").font(Brand.body(12)).foregroundStyle(Brand.success)
                        }
                    }
                }
                // Bonus: fabrication tools (optional).
                FabPanel(title: "Optional · Fabrication Tools") {
                    HStack(spacing: 16) {
                        depDot("PrusaSlicer", d.prusaslicer)
                        depDot("UVtools", d.uvtools)
                        depDot("OpenSCAD", d.openscad)
                        Spacer(minLength: 0)
                    }
                    Text("Only needed for the 3D-printing (Fabrication) features. Install later if you want them.")
                        .font(Brand.body(10)).foregroundStyle(Brand.bone400)
                }
            } else { probingPlaceholder }
        }
    }

    private func depDot(_ name: String, _ ok: Bool) -> some View {
        HStack(spacing: 6) {
            StatusDot(color: ok ? Brand.success : Brand.ink500, size: 6)
            Text(name).font(Brand.body(12)).foregroundStyle(ok ? Brand.bone100 : Brand.bone400)
        }
    }

    // ── 3. MODEL ──
    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle("Choose your daily-driver model", "Recommended for your machine is highlighted. Bigger models are more capable but need more memory.")
            if let probe {
                if let rec = probe.recommendedModel { modelRow(rec, recommended: true) }
                FabPanel(title: "All Chat Models") {
                    VStack(spacing: 0) {
                        let others = probe.chatModels.filter { !$0.recommended }
                        ForEach(Array(others.enumerated()), id: \.element.id) { i, m in
                            modelRowInline(m)
                            if i < others.count - 1 { Rectangle().fill(Brand.line1).frame(height: 1) }
                        }
                    }
                }
                FabPanel(title: "Advanced · Custom Model") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            TextField("any Ollama tag, e.g. llama3.1:8b", text: $model.setupCustomModel)
                                .textFieldStyle(.plain).font(Brand.mono(12)).foregroundStyle(Brand.bone50)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(Brand.ink600, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Brand.line1, lineWidth: 1))
                        }
                        Text("Overrides the choice above. Anything in the Ollama library works.")
                            .font(Brand.body(10)).foregroundStyle(Brand.bone400)
                    }
                }
            } else { probingPlaceholder }
        }
    }

    private func modelRow(_ m: SetupModelInfo, recommended: Bool) -> some View {
        let chosen = effectiveChoice == m.id
        return Button { model.setupChosenModel = m.id; model.setupCustomModel = "" } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14)).foregroundStyle(chosen ? Brand.ember500 : Brand.bone400).padding(.top, 1)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(m.label).font(.system(size: 14, weight: .semibold)).foregroundStyle(Brand.bone50)
                        if recommended { FabTag(text: "Recommended", color: Brand.ember500, filled: true) }
                        FabTag(text: m.params, color: Brand.bone400)
                        fitTag(m.fit)
                        if m.installed { FabTag(text: "Installed", color: Brand.success) }
                        Spacer(minLength: 0)
                        Text(m.sizeLabel).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Brand.bone300)
                    }
                    Text(m.note).font(Brand.body(11)).foregroundStyle(Brand.bone300)
                }
            }
            .padding(14)
            .background(chosen ? Brand.ink600 : Brand.ink700, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(chosen ? Brand.ember700 : Brand.line1, lineWidth: 1))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func modelRowInline(_ m: SetupModelInfo) -> some View {
        let chosen = effectiveChoice == m.id
        return Button { model.setupChosenModel = m.id; model.setupCustomModel = "" } label: {
            HStack(spacing: 10) {
                Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13)).foregroundStyle(chosen ? Brand.ember500 : Brand.bone400)
                Text(m.label).font(Brand.body(13, weight: .medium)).foregroundStyle(Brand.bone50)
                FabTag(text: m.params, color: Brand.bone400)
                fitTag(m.fit)
                if m.installed { FabTag(text: "Installed", color: Brand.success) }
                Spacer(minLength: 0)
                Text(m.sizeLabel).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Brand.bone300)
            }
            .padding(.vertical, 9).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func fitTag(_ fit: String) -> some View {
        switch fit {
        case "comfortable": return FabTag(text: "Comfortable", color: Brand.success)
        case "tight":       return FabTag(text: "Tight", color: Brand.warning)
        default:            return FabTag(text: "Won't fit", color: Brand.error)
        }
    }

    private var effectiveChoice: String {
        model.setupCustomModel.trimmingCharacters(in: .whitespaces).isEmpty ? model.setupChosenModel : model.setupCustomModel
    }

    // ── 4. DOWNLOAD ──
    private var downloadStep: some View {
        let chosen = effectiveChoice
        let alreadyInstalled = probe?.models.first { $0.id == chosen }?.installed ?? false
        return VStack(alignment: .leading, spacing: 14) {
            stepTitle("Download the model", alreadyInstalled ? "This model is already installed — you're good to go." : "Pulling \(chosen) from the Ollama library. This can take a few minutes.")
            FabPanel(title: "Download") {
                VStack(alignment: .leading, spacing: 12) {
                    FabDataRow(key: "Model", value: chosen, valueColor: Brand.cyan500)
                    if alreadyInstalled && !model.pulling {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Brand.success)
                            Text("Already installed").font(Brand.body(12)).foregroundStyle(Brand.success)
                        }
                    } else if model.pulling {
                        ThinProgressBar(value: model.pullProgress, tint: Brand.cyan500).frame(height: 5)
                        Text(model.pullStatus).font(.system(size: 11, design: .monospaced)).foregroundStyle(Brand.bone300)
                    } else if model.pullStatus.hasPrefix("installed") {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Brand.success)
                            Text("Download complete").font(Brand.body(12)).foregroundStyle(Brand.success)
                        }
                    } else if model.pullStatus.hasPrefix("failed") {
                        Text(model.pullStatus).font(Brand.body(12)).foregroundStyle(Brand.error)
                        FabButton(title: "Retry", icon: "arrow.clockwise", style: .primary) { model.pullModel(chosen) }
                    } else {
                        FabButton(title: "Start Download", icon: "arrow.down.circle", style: .primary) { model.pullModel(chosen) }
                    }
                }
            }
            Text("You can also add or swap models any time from the Models panel in the sidebar.")
                .font(Brand.body(10)).foregroundStyle(Brand.bone400)
        }
    }

    // ── 5. READY ──
    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle("You're set", "GINEXUS will use this model as your daily driver and restart its local core to apply.")
            FabPanel(title: "Summary") {
                VStack(spacing: 0) {
                    FabDataRow(key: "Daily-driver model", value: effectiveChoice, valueColor: Brand.cyan500)
                    if let hw = probe?.hardware { FabDataRow(key: "Machine", value: "\(hw.chip) · \(hw.ramLabel)") }
                    FabDataRow(key: "Runtime", value: probe?.deps.ollamaVersion.map { "Ollama v\($0)" } ?? "Ollama")
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill").font(.system(size: 12)).foregroundStyle(Brand.ember500)
                Text("Everything runs on this Mac. Nothing is sent to the cloud unless you add an API provider later.")
                    .font(Brand.body(11)).foregroundStyle(Brand.bone300)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: footer
    private var footer: some View {
        HStack(spacing: 10) {
            if step != .system {
                FabButton(title: "Back", icon: "chevron.left", style: .ghost) { back() }
            }
            FabButton(title: "Skip setup", style: .ghost) { model.setupSkip() }
            Spacer(minLength: 0)
            if step == .ready {
                FabButton(title: "Start Using GINEXUS", icon: "checkmark", style: .primary) { model.setupFinish() }
            } else {
                FabButton(title: "Continue", icon: "chevron.right", style: .primary, enabled: canAdvance) { advance() }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var canAdvance: Bool {
        switch step {
        case .system:   return probe != nil
        case .runtime:  return probe?.deps.ollamaReady ?? false
        case .model:    return !effectiveChoice.isEmpty
        case .download:
            let installed = probe?.models.first { $0.id == effectiveChoice }?.installed ?? false
            return installed || model.pullStatus.hasPrefix("installed")
        case .ready:    return true
        }
    }

    private func advance() {
        withAnimation(Brand.ease(0.2)) {
            if let next = AppModel.SetupStep(rawValue: step.rawValue + 1) { model.setupStep = next }
        }
    }
    private func back() {
        withAnimation(Brand.ease(0.2)) {
            if let prev = AppModel.SetupStep(rawValue: step.rawValue - 1) { model.setupStep = prev }
        }
    }

    private func stepTitle(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 18, weight: .semibold)).foregroundStyle(Brand.bone50)
            Text(sub).font(Brand.body(12)).foregroundStyle(Brand.bone300)
        }
    }

    private var probingPlaceholder: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Detecting your system…").font(Brand.body(12)).foregroundStyle(Brand.bone300)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}
