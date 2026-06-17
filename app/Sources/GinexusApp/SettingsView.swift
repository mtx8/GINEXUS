// SettingsView.swift — the Settings sheet. Brand tokens only (dark-only, single ember accent,
// no emoji / glassmorphism / neon). Two kinds of setting:
//   • LIVE (default model / mode, import + privacy toggles) — applied immediately, no restart.
//   • CORE (Ollama endpoint, Obsidian vault, image generation) — read into the core's env at boot,
//     so a change reveals APPLY & RESTART CORE which respawns the embedded core.
import SwiftUI
import AppKit
import GinexusCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore
    /// The core-config values the running core was booted with; APPLY shows only when they differ
    /// (so reverting an edit hides it and avoids a no-op restart).
    @State private var baseline: GinexusSettings?

    private var autonomousBinding: Binding<Bool> {
        Binding(get: { model.autonomous }, set: { model.autonomous = $0 })
    }

    /// True when a CORE setting (endpoint / vault / image generation) differs from the booted value.
    private var coreDirty: Bool {
        guard let b = baseline else { return false }
        let s = store.settings
        return s.ollamaBase != b.ollamaBase
            || s.obsidianVaultPath != b.obsidianVaultPath
            || s.mediaSidecarEnabled != b.mediaSidecarEnabled
    }

    /// Block APPLY while a reply streams, or when the endpoint was changed to an invalid/blocked value.
    private var canApply: Bool {
        if model.sending { return false }
        let s = store.settings
        if s.ollamaBase != GinexusSettings.defaultOllamaBase,
           !(s.ollamaBaseIsValid && s.ollamaBaseHostAllowed) { return false }
        return true
    }

    var body: some View {
        ZStack {
            Brand.ink900.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        defaultsSection
                        runtimeSection
                        importSection
                        privacySection
                        Text("Saved to ~/Library/Application Support/GINEXUS/settings.json")
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(Brand.muted)
                            .padding(.top, 2)
                    }
                }
                if coreDirty { applyBar }
            }
            .padding(24)
        }
        .frame(width: 620, height: 660)
        .preferredColorScheme(.dark)
        .onAppear { if baseline == nil { baseline = store.settings } }
    }

    private var header: some View {
        HStack {
            Text("SETTINGS").font(.system(size: 14, weight: .bold, design: .monospaced)).kerning(2)
                .foregroundStyle(Brand.bone50)
            Spacer()
            Button("DONE") { model.settingsOpen = false }
                .buttonStyle(.plain).font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Brand.muted)
        }
    }

    // MARK: sections

    private var defaultsSection: some View {
        card("DEFAULTS") {
            row("Default model") {
                Picker("", selection: $model.selectedModel) {
                    ForEach(model.models) { m in Text(m.label).tag(m.id) }
                }
                .labelsHidden().pickerStyle(.menu).tint(Brand.ember500).frame(maxWidth: 260)
            }
            divider
            row("Default mode") {
                Picker("", selection: autonomousBinding) {
                    Text("HITL").tag(false)
                    Text("AUTO").tag(true)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 160)
            }
            caption("HITL asks for Touch ID on every irreversible action. AUTO runs them unattended except the hard gate (money, external comms, legal, delete, code execution).")
        }
    }

    private var runtimeSection: some View {
        card("PATHS & RUNTIME") {
            row("Ollama endpoint") {
                TextField(GinexusSettings.defaultOllamaBase, text: $store.settings.ollamaBase)
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Brand.bone50).padding(8).background(Brand.ink900)
                    .clipShape(RoundedRectangle(cornerRadius: 6)).frame(maxWidth: 300)
            }
            if !store.settings.ollamaBaseIsValid {
                caption("Must be a full http(s) URL ending in /v1, e.g. http://127.0.0.1:11434/v1")
            } else if !store.settings.ollamaBaseHostAllowed {
                caption("That host is blocked (link-local / metadata / wildcard) and will be ignored.")
            } else if !store.settings.ollamaBaseIsLoopback {
                caption("Remote host — GINEXUS will send your prompts off this Mac to that endpoint.")
            }
            divider
            row("Obsidian vault") {
                HStack(spacing: 8) {
                    Text(store.settings.obsidianVaultPath ?? "Auto-detect")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(store.settings.obsidianVaultPath == nil ? Brand.muted : Brand.bone50)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 200, alignment: .leading)
                    Button("Choose…") { chooseVault() }
                        .buttonStyle(.plain).font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Brand.ember500)
                    if store.settings.obsidianVaultPath != nil {
                        Button("Clear") { store.settings.obsidianVaultPath = nil }
                            .buttonStyle(.plain).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Brand.muted)
                    }
                }
            }
            divider
            row("Local image generation") {
                Toggle("", isOn: $store.settings.mediaSidecarEnabled)
                    .labelsHidden().tint(Brand.ember500)
            }
            caption("Runs the on-device image model. Off removes only the image-generation tool — it does not affect vision (image understanding).")
        }
    }

    private var importSection: some View {
        card("IMPORT") {
            row("Include assistant replies") {
                Toggle("", isOn: $store.settings.importIncludeAssistant).labelsHidden().tint(Brand.ember500)
            }
            caption("When importing an AI-data export, also load the assistant's replies. Imports are always stored as quarantined (untrusted) memory.")
        }
    }

    private var privacySection: some View {
        card("PRIVACY") {
            row("Keep conversations after quit") {
                Toggle("", isOn: $store.settings.persistTranscript).labelsHidden().tint(Brand.ember500)
            }
            caption("On: conversations are saved on this Mac and restored on launch. Off: chat history is kept only in memory and cleared on quit.")
        }
    }

    private var applyBar: some View {
        HStack {
            Text("Restart the core to apply endpoint / vault / image-generation changes.")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Brand.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: { model.restartCore(); baseline = store.settings }) {
                Text("APPLY & RESTART CORE").font(.system(size: 11, weight: .bold, design: .monospaced)).kerning(1)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .foregroundStyle(Brand.ink900).background(canApply ? Brand.ember500 : Brand.muted)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).disabled(!canApply)
        }
        .transition(.opacity)
    }

    // MARK: building blocks

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 9, weight: .bold, design: .monospaced)).kerning(1.5)
                .foregroundStyle(Brand.muted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(Brand.ink800).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func row<Control: View>(_ label: String, @ViewBuilder _ control: () -> Control) -> some View {
        HStack {
            Text(label).font(.system(size: 13, design: .monospaced)).foregroundStyle(Brand.bone50)
            Spacer()
            control()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 10, design: .monospaced)).foregroundStyle(Brand.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var divider: some View { Divider().overlay(Color.white.opacity(0.06)) }

    // MARK: vault picker (rejects iCloud per hard rule #1)

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose your Obsidian vault folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if SpineController.isICloudPath(url.path) { return }   // never point the vault into iCloud (symlink-resolved)
        store.settings.obsidianVaultPath = url.path
    }
}
