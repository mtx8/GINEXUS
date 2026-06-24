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
    /// The Brave key lives in the Keychain (not settings), so track its change separately to drive APPLY.
    @State private var braveDirty = false

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
            || s.mcpServers != b.mcpServers   // a new/removed/toggled connection needs a core restart
            || braveDirty
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
                        connectionsSection
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

    // MARK: connections (external MCP integrations) — lives in Settings, not the chat

    private func isConnected(_ name: String) -> Bool {
        store.settings.mcpServers.contains { $0.name == name }
    }

    private var connectionsSection: some View {
        card("CONNECTIONS") {
            caption("Connect external tools over MCP. Tool calls are approval-gated and writes need your Touch ID. New connections take effect after you restart the core (button below).")

            connector("Notion", hint: "Internal integration token (ntn_ / secret_).",
                      placeholder: "Notion integration token", token: $model.notionTokenDraft,
                      connected: isConnected("notion"), connect: model.connectNotion)
            divider
            connector("GitHub", hint: "Personal access token (repo / issues scopes).",
                      placeholder: "GitHub PAT (ghp_… / github_pat_…)", token: $model.githubTokenDraft,
                      connected: isConnected("github"), connect: model.connectGitHub)
            divider
            tokenlessConnector("Shopify", hint: "Shopify's official dev MCP (docs + Admin schema). No token needed.",
                               connected: isConnected("shopify"), connect: model.connectShopify)
            divider
            connector("Printful", hint: "API token from Printful → Settings → Developers. Uses GINEXUS's own professional Printful MCP (catalog, products, orders, shipping).",
                      placeholder: "Printful API token", token: $model.printfulTokenDraft,
                      connected: isConnected("printful"), connect: model.connectPrintful)
            divider
            braveRow
            divider
            customServerRow
            if !store.settings.mcpServers.isEmpty {
                divider
                configuredList
            }
        }
    }

    /// A preset connector with a token field, or a CONNECTED badge once added.
    private func connector(_ name: String, hint: String, placeholder: String,
                           token: Binding<String>, connected: Bool, connect: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(Brand.mono(13, weight: .bold)).foregroundStyle(Brand.bone50)
                Spacer()
                if connected { connectedBadge }
            }
            caption(hint)
            if !connected {
                HStack(spacing: 8) {
                    SecureField(placeholder, text: token)
                        .textFieldStyle(.plain).font(Brand.mono(12)).foregroundStyle(Brand.bone50)
                        .padding(9).background(Brand.ink900).clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Brand.line1, lineWidth: 1))
                    emberButton("CONNECT", enabled: !token.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty, action: connect)
                }
            }
        }
    }

    /// A preset connector that needs no token (Shopify dev MCP).
    private func tokenlessConnector(_ name: String, hint: String, connected: Bool, connect: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(Brand.mono(13, weight: .bold)).foregroundStyle(Brand.bone50)
                Spacer()
                if connected { connectedBadge } else { emberButton("CONNECT", enabled: true, action: connect) }
            }
            caption(hint)
        }
    }

    private var braveRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Brave Search key").font(Brand.mono(13, weight: .bold)).foregroundStyle(Brand.bone50)
                Spacer()
                if model.braveSearchConfigured {
                    connectedBadge
                    Button("Remove") { model.clearBraveKey(); braveDirty = true }
                        .buttonStyle(.plain).font(Brand.mono(10)).foregroundStyle(Brand.muted)
                }
            }
            caption("Optional. Powers full live web search (news, prices, recent events). Without it, search is keyless and limited. Free key at api.search.brave.com.")
            if !model.braveSearchConfigured {
                HStack(spacing: 8) {
                    SecureField("Brave Search API key", text: $model.braveKeyDraft)
                        .textFieldStyle(.plain).font(Brand.mono(12)).foregroundStyle(Brand.bone50)
                        .padding(9).background(Brand.ink900).clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Brand.line1, lineWidth: 1))
                    emberButton("SAVE", enabled: !model.braveKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty,
                                action: { model.saveBraveKey(); braveDirty = true })
                }
            }
        }
    }

    private var customServerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add any MCP server").font(Brand.mono(11, weight: .bold)).kerning(1).foregroundStyle(Brand.bone200)
            caption("Any stdio MCP server — e.g. a command like npx -y <package>.")
            smallField("Name (e.g. linear)", $model.mcpCustomName)
            smallField("Command (e.g. npx -y @some/mcp-server)", $model.mcpCustomCommand)
            HStack(spacing: 8) {
                smallField("Token env var (optional)", $model.mcpCustomTokenEnv)
                smallSecure("Token (optional)", $model.mcpCustomToken)
            }
            HStack {
                Spacer()
                emberButton("ADD SERVER",
                            enabled: !model.mcpCustomName.trimmingCharacters(in: .whitespaces).isEmpty
                                  && !model.mcpCustomCommand.trimmingCharacters(in: .whitespaces).isEmpty,
                            action: model.addCustomMcp)
            }
        }
    }

    private var configuredList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Configured").font(Brand.mono(11, weight: .bold)).kerning(1).foregroundStyle(Brand.bone200)
            ForEach(model.mcpServers) { s in
                HStack(spacing: 10) {
                    Circle().fill(s.enabled ? Brand.ember500 : Brand.muted).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name).font(Brand.mono(12, weight: .bold)).foregroundStyle(Brand.bone50)
                        Text(s.command).font(Brand.mono(9)).foregroundStyle(Brand.muted).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { s.enabled }, set: { model.setMcpEnabled(s.id, $0) }))
                        .labelsHidden().toggleStyle(.switch).tint(Brand.ember500)
                    Button(role: .destructive) { model.removeMcpServer(s.id) } label: {
                        Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Brand.muted)
                    }.buttonStyle(.plain)
                }
                .padding(8).background(Brand.ink900).clipShape(RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private var connectedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 10))
            Text("CONNECTED").font(Brand.mono(9, weight: .bold)).kerning(1)
        }.foregroundStyle(Brand.ember500)
    }

    private func emberButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Brand.mono(11, weight: .bold)).kerning(1.2).foregroundStyle(Brand.ink900)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(enabled ? Brand.ember500 : Brand.muted).clipShape(RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).disabled(!enabled)
    }

    private func smallField(_ ph: String, _ text: Binding<String>) -> some View {
        TextField(ph, text: text)
            .textFieldStyle(.plain).font(Brand.mono(11)).foregroundStyle(Brand.bone50)
            .padding(8).background(Brand.ink900).clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Brand.line1, lineWidth: 1))
    }
    private func smallSecure(_ ph: String, _ text: Binding<String>) -> some View {
        SecureField(ph, text: text)
            .textFieldStyle(.plain).font(Brand.mono(11)).foregroundStyle(Brand.bone50)
            .padding(8).background(Brand.ink900).clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Brand.line1, lineWidth: 1))
    }

    private var applyBar: some View {
        HStack {
            Text("Restart the core to apply connection, endpoint, vault, or image-generation changes.")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Brand.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: { model.restartCore(); baseline = store.settings; braveDirty = false }) {
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
        .background(Brand.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .top) { Brand.topSheen.frame(height: 1).clipShape(RoundedRectangle(cornerRadius: 10)) }
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Brand.line1, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
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
