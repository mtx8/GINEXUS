// ContentView.swift — the GINEXUS "Execution Stream": a three-pane agentic console over the live
// hardened core. Icon rail · conversation sidebar · execution stream · context+tools rail. All
// MackTrax brand tokens (see Brand.swift) — dark-only, ember the single accent, no fake stats.
import SwiftUI
import AppKit
import GinexusCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var pendingDelete: String?                 // model name awaiting uninstall confirm
    @State private var renamingID: UUID?                      // conversation being inline-renamed
    @State private var renameText = ""
    @State private var pendingDeleteConversation: ConversationMeta?
    @State private var sidebarShown = true                    // collapse the conversations panel
    @State private var contextShown = true                    // collapse the Context & Tools panel

    var body: some View {
        HStack(spacing: 0) {
            iconRail   // far-left bar + icons — full height, untouched
            // Everything else: a full-width GINEXUS header bar on top, panels + stream BELOW it.
            VStack(spacing: 0) {
                streamHeader
                    .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 14)
                Divider().overlay(Brand.line1)
                HStack(spacing: 0) {
                    leftColumn
                    streamColumn
                    rightColumn
                }
            }
        }
        .animation(Brand.ease(0.28), value: sidebarShown)
        .animation(Brand.ease(0.28), value: contextShown)
        .background(ZStack { Brand.ink900; Brand.canvasGlow }.ignoresSafeArea())
        .frame(minWidth: 1180, minHeight: 680)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.memoryOpen) { memorySheet }
        .sheet(isPresented: $model.modelsOpen) { modelsSheet }
        .sheet(isPresented: $model.settingsOpen) { SettingsView(model: model, store: model.settings) }
    }

    // MARK: ── far-left icon rail ───────────────────────────────────────────────
    private var iconRail: some View {
        VStack(spacing: 6) {
            GlyphMark(size: 38, spinning: model.sending).padding(.top, 16).padding(.bottom, 12)
            railIcon("square.and.pencil", "New conversation", enabled: model.connected && !model.sending) { model.newChat() }
            railIcon("brain", "Memory — what GINEXUS knows", enabled: model.connected) { model.openMemory() }
            railIcon("cube.box", "Models — download / manage", enabled: model.connected) { model.openModels() }
            railIcon("gearshape", "Settings") { model.openSettings() }   // always reachable (recovery)
            Spacer()
            StatusDot(color: model.connected ? Brand.success : Brand.bone400, glow: model.connected, size: 8)
                .padding(.bottom, 16)
                .help(model.connected ? "Connected to the local core" : "Core offline")
        }
        .frame(width: 56)
        .frame(maxHeight: .infinity)
        .background(Brand.ink850)
        .overlay(alignment: .trailing) { Rectangle().fill(Brand.line1).frame(width: 1) }
    }

    private func railIcon(_ system: String, _ help: String, enabled: Bool = true,
                          _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 16))
                .foregroundStyle(enabled ? Brand.bone300 : Brand.bone400)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).disabled(!enabled)
    }

    // MARK: ── left: conversations (floating panel) ─────────────────────────────
    @ViewBuilder private var leftColumn: some View {
        if sidebarShown {
            conversationPanel
                .frame(width: 256)
                .padding(.leading, 14).padding(.vertical, 16)
                .transition(.move(edge: .leading).combined(with: .opacity))
        } else {
            CollapsedTab(label: "Chats", expandIcon: "chevron.right") { sidebarShown = true }
                .frame(maxHeight: .infinity, alignment: .top)   // top of the panel area (already below the header bar)
                .padding(.leading, 12).padding(.vertical, 16)
                .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    private var conversationPanel: some View {
        FloatingPanel(
            title: "Conversations",
            collapseIcon: "chevron.left",
            onCollapse: { sidebarShown = false },
            headerAccessory: AnyView(
                Button(action: { model.newChat() }) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .bold)).foregroundStyle(Brand.ember500)
                }.buttonStyle(.plain).help("New conversation").disabled(!model.connected || model.sending)
            )
        ) {
            VStack(spacing: 0) {
                if model.conversations.isEmpty {
                    Text("No conversations yet").font(Brand.mono(11)).foregroundStyle(Brand.bone400)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.top, 14)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(model.conversations) { c in
                                ConversationRow(
                                    c: c, selected: c.id == model.activeConversationID,
                                    disabled: model.sending && c.id != model.activeConversationID,
                                    renamingID: $renamingID, renameText: $renameText,
                                    onSelect: { renamingID = nil; model.selectConversation(c.id) },
                                    onCommitRename: { model.renameConversation(c.id, to: renameText); renamingID = nil },
                                    onRequestRename: { renameText = c.title; renamingID = c.id },
                                    onRequestDelete: { pendingDeleteConversation = c })
                            }
                        }
                        .padding(8).animation(Brand.ease, value: model.conversations)
                    }
                }
                Divider().overlay(Brand.line1)
                HStack(spacing: 8) {
                    StatusDot(color: statusColor, glow: model.connected, size: 7)
                    Text("AGENT").font(Brand.mono(9, weight: .bold)).kerning(1).foregroundStyle(Brand.bone400)
                    Text(statusLabel).font(Brand.mono(10, weight: .bold)).kerning(1).foregroundStyle(statusColor)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
            }
        }
        .confirmationDialog(
            "Delete this conversation?",
            isPresented: Binding(get: { pendingDeleteConversation != nil }, set: { if !$0 { pendingDeleteConversation = nil } }),
            presenting: pendingDeleteConversation
        ) { c in
            Button("Delete", role: .destructive) { model.deleteConversation(c.id); pendingDeleteConversation = nil }
            Button("Cancel", role: .cancel) { pendingDeleteConversation = nil }
        } message: { c in Text("\"\(c.title)\" will be permanently removed. This cannot be undone.") }
    }

    private var statusColor: Color { model.sending ? Brand.warning : (model.connected ? Brand.success : Brand.bone400) }
    private var statusLabel: String { model.sending ? "THINKING" : (model.connected ? "ONLINE" : "OFFLINE") }

    // MARK: ── center: execution stream ────────────────────────────────────────
    // Center: just the execution stream + input — the GINEXUS header now lives in the top bar above.
    private var streamColumn: some View {
        VStack(spacing: 0) {
            executionStream
            inputBar.frame(maxWidth: 760).frame(maxWidth: .infinity)
                .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var streamHeader: some View {
        HStack(spacing: 12) {
            Wordmark(size: 30).layoutPriority(2)   // never yields — the brand holds its line
            Rectangle().fill(Brand.line2).frame(width: 1, height: 22).padding(.horizontal, 2)
            Text("Execution Stream").font(Brand.body(14, weight: .medium)).foregroundStyle(Brand.bone300)
                .lineLimit(1).truncationMode(.tail).layoutPriority(0)   // truncates first on a tight header
            Spacer(minLength: 8)
            autonomyToggle.layoutPriority(1)
            modelSelector.layoutPriority(1)
        }
    }

    private var autonomyToggle: some View {
        Button(action: { model.autonomous.toggle() }) {
            TacticalLabel(text: model.autonomous ? "Auto" : "HITL",
                          icon: model.autonomous ? "bolt.fill" : "hand.raised.fill",
                          filled: false, tint: model.autonomous ? Brand.ember500 : Brand.bone300)
        }
        .buttonStyle(.plain).disabled(!model.connected)
        .help(model.autonomous
            ? "Autonomous — irreversible actions run unattended EXCEPT the hard gate (money / comms / legal / delete / exec)."
            : "Human-in-the-loop — every irreversible action asks for Touch ID.")
    }

    private var modelSelector: some View {
        Menu {
            ForEach(model.models) { m in
                Button(action: { model.selectedModel = m.id }) {
                    if m.id == model.selectedModel { Label(m.label, systemImage: "checkmark") } else { Text(m.label) }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "cpu").font(.system(size: 10, weight: .semibold))
                Text(model.activeModelLabel).font(Brand.mono(10.5, weight: .bold)).kerning(0.6).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Brand.bone200)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Brand.ink850).clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Brand.line2, lineWidth: 1))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .frame(maxWidth: 260).disabled(!model.connected)
    }

    private var executionStream: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if model.chat.isEmpty && model.pending == nil { emptyState }
                    ForEach(model.chat) { msg in streamBlock(msg).id(msg.id) }
                    if let p = model.pending { approvalBlock(p).id("approval") }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 760, alignment: .leading)   // readable centered column (Gemini-style)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 8)
            }
            .onChange(of: model.chat.count) { _, _ in withAnimation(Brand.ease) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: model.chat.last?.text.count) { _, _ in
                if model.sending { withAnimation(Brand.ease) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onChange(of: model.pending?.id) { _, id in if id != nil { withAnimation(Brand.ease) { proxy.scrollTo("approval", anchor: .bottom) } } }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Ready", color: Brand.ember500)
            Text("Ask GINEXUS anything — it runs entirely on this Mac.")
                .font(Brand.body(14)).foregroundStyle(Brand.bone300)
        }
        .padding(.top, 44)
    }

    /// One conversation turn. Your message → a right-aligned soft bubble. GINEXUS's reply → the
    /// agent FLOW: an "Action" card per tool the agent used (the execution blocks from your reference),
    /// then the answer as clean bare prose led by the brand glyph. Plain chats (no tools) show no
    /// cards — just the prose — so it stays clean, not gimmicky.
    @ViewBuilder private func streamBlock(_ msg: ChatMsg) -> some View {
        if msg.role == "user" {
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 64)
                VStack(alignment: .leading, spacing: 8) {
                    Text(msg.text).font(Brand.body(14)).foregroundStyle(Brand.bone50)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if let path = msg.imagePath { StreamImage(path: path) }
                }
                .padding(.horizontal, 15).padding(.vertical, 11)
                .background(Brand.ink600)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                // Completed agent actions (tools used this turn) → clean Action cards.
                ForEach(Array(msg.steps.enumerated()), id: \.offset) { _, step in
                    BlockCard(label: "Action · \(step)", icon: "bolt.fill", accent: Brand.ember300) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Brand.success)
                            Text("Completed").font(Brand.mono(11)).foregroundStyle(Brand.bone300)
                        }
                    }
                }
                // Live action card while a tool runs.
                if msg.streaming, let s = msg.status {
                    BlockCard(label: s, icon: "bolt.fill", accent: Brand.ember300, active: true) {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.mini)
                            Text("Running…").font(Brand.mono(11)).foregroundStyle(Brand.ember300)
                        }
                    }
                }
                // The answer — bare, readable prose led by the brand glyph (Gemini-clean).
                HStack(alignment: .top, spacing: 12) {
                    GlyphMark(size: 22, spinning: msg.streaming)
                    VStack(alignment: .leading, spacing: 10) {
                        if msg.streaming {
                            StreamingText(text: msg.text)
                        } else {
                            MarkdownReply(text: msg.text)
                            if let path = msg.imagePath { StreamImage(path: path) }
                            if let doc = msg.docPath { finalOutputCard(doc) }
                            assistantActions(msg)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Final Output card — a generated PDF/Word document with open + reveal actions.
    private func finalOutputCard(_ path: String) -> some View {
        let url = URL(fileURLWithPath: path)
        let isPDF = path.lowercased().hasSuffix(".pdf")
        return BlockCard(label: "Final Output", icon: "doc.richtext", accent: Brand.ember500) {
            HStack(spacing: 12) {
                Image(systemName: isPDF ? "doc.fill" : "doc.text.fill").font(.system(size: 20)).foregroundStyle(Brand.ember500)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent).font(Brand.mono(12, weight: .medium)).foregroundStyle(Brand.bone50).lineLimit(1).truncationMode(.middle)
                    Text(isPDF ? "PDF DOCUMENT" : "WORD DOCUMENT").font(Brand.mono(8.5, weight: .bold)).kerning(0.8).foregroundStyle(Brand.bone400)
                }
                Spacer()
                Button(action: { NSWorkspace.shared.open(url) }) { TacticalLabel(text: "Open", icon: "arrow.up.forward", filled: true) }.buttonStyle(.plain)
                Button(action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }) { TacticalLabel(text: "Reveal") }.buttonStyle(.plain)
            }
        }
    }

    /// Subtle action row under a finished reply (copy, for now).
    private func assistantActions(_ msg: ChatMsg) -> some View {
        HStack(spacing: 16) {
            Button(action: { copyText(msg.text) }) {
                Image(systemName: "doc.on.doc").font(.system(size: 12)).foregroundStyle(Brand.bone400)
            }.buttonStyle(.plain).help("Copy")
            Spacer()
        }
        .padding(.top, 4)
    }
    private func copyText(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// Inline Human Approval block — replaces the modal sheet; Approve drives Touch ID.
    private func approvalBlock(_ p: PendingAction) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Approval Required", color: Brand.ember500)
            Text("GINEXUS wants to run an action that changes something. Approve with Touch ID to proceed.")
                .font(Brand.body(12)).foregroundStyle(Brand.bone300).fixedSize(horizontal: false, vertical: true)
            Text(p.preview).font(Brand.mono(13)).foregroundStyle(Brand.bone50).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(Brand.ink850).clipShape(RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 10) {
                Button(action: { model.approve() }) {
                    HStack(spacing: 6) { Image(systemName: "touchid"); Text("APPROVE") }
                        .font(Brand.display(12, weight: .bold)).kerning(1.2)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .foregroundStyle(Brand.ink900).background(Brand.ember500)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
                Button(action: { model.deny() }) {
                    Text("DENY").font(Brand.display(12, weight: .bold)).kerning(1.2)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .foregroundStyle(Brand.bone300).background(Brand.ink700)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.line2, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Brand.ember500.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.ember600.opacity(0.55), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: ── input bar ───────────────────────────────────────────────────────
    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            attachmentChip
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    plusMenu
                    TextField("Message GINEXUS…", text: $model.chatInput)
                        .textFieldStyle(.plain).font(Brand.mono(14)).foregroundStyle(Brand.bone50)
                        .onSubmit { model.send(model.chatInput) }
                }
                .padding(.horizontal, 12).padding(.vertical, 12)
                .background(Brand.ink700).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Brand.line1, lineWidth: 1))
                Button(action: { model.send(model.chatInput) }) {
                    Text("SEND").font(Brand.mono(12, weight: .bold)).kerning(1.6)
                        .padding(.horizontal, 24).padding(.vertical, 14)
                        .foregroundStyle(canSend ? Brand.ink900 : Brand.bone400)
                        .background(canSend ? Brand.ember500 : Brand.ink600)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain).disabled(!canSend)
            }
        }
    }

    private var canSend: Bool {
        model.connected && !model.sending &&
        (!model.chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.attachment != nil)
    }

    /// The "+" menu inside the input row: capabilities that act on your message, plus attachments.
    private var plusMenu: some View {
        Menu {
            Section("Do with your message") {
                Button("Perspectives", action: model.runCouncil).disabled(!model.canQuickAction)
                Button("Research", action: model.runResearch).disabled(!model.canQuickAction)
                Button("Create image", action: model.runImage).disabled(!model.canQuickAction)
            }
            Section("Attach") {
                Button("Attach file…", action: model.attachAny)
                Button("Attach image…", action: model.attachImage)
                Button("Import AI data…", action: model.importExport)
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Brand.bone200).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(!model.connected)
        .help("Capabilities + attach a file, image, or AI-data export")
    }

    @ViewBuilder private var attachmentChip: some View {
        if let att = model.attachment {
            HStack(spacing: 6) {
                if att.kind == "image", let thumb = model.attachmentThumb {
                    Image(nsImage: thumb).resizable().scaledToFill()
                        .frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: att.kind == "image" ? "photo" : "doc.text")
                        .font(.system(size: 11)).foregroundStyle(Brand.ember500)
                }
                Text(att.name).font(Brand.mono(11)).foregroundStyle(Brand.bone50).lineLimit(1)
                if att.kind == "image", !model.visionAvailable, !model.visionStatus.isEmpty {
                    Text(model.visionStatus).font(Brand.mono(9, weight: .bold)).kerning(0.5).foregroundStyle(Brand.bone300)
                }
                Button(action: { model.clearAttachment() }) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Brand.bone400)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Brand.ink700).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.line1, lineWidth: 1))
        }
    }

    // MARK: ── right: Context & Tools (floating panel) ─────────────────────────
    @ViewBuilder private var rightColumn: some View {
        if contextShown {
            contextPanel
                .frame(width: 300)
                .padding(.trailing, 14).padding(.vertical, 16)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            CollapsedTab(label: "Tools", expandIcon: "chevron.left") { contextShown = true }
                .frame(maxHeight: .infinity, alignment: .top)   // top of the panel area (already below the header bar)
                .padding(.trailing, 12).padding(.vertical, 16)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    private var contextPanel: some View {
        FloatingPanel(title: "Context & Tools", collapseIcon: "chevron.right", onCollapse: { contextShown = false }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    railSection("Session") {
                        statRow("Status", model.connected ? "CONNECTED" : "OFFLINE", dot: model.connected ? Brand.success : Brand.bone400)
                        statRow("Model", model.activeModelLabel, dot: nil)
                        statRow("Conversations", "\(model.conversations.count)", dot: nil)
                        statRow("Memory facts", model.memFactsCount > 0 ? "\(model.memFactsCount)" : "—", dot: nil)
                    }
                    railDivider
                    railSection("Token Usage") { TokenUsageGauge(usage: model.lastUsage) }
                    railDivider
                    railSection("Current File Context") { currentContextContent }
                    railDivider
                    railSection("Enabled Tools") {
                        capRow("network", "Web research", on: true)
                        capRow("terminal.fill", "Terminal", on: true)
                        capRow("brain.head.profile", "Memory", on: true)
                        capRow("person.3.fill", "Council", on: true)
                        capRow("doc.text.magnifyingglass", "Deep research", on: true)
                        capRow("photo.fill.on.rectangle.fill", "Image generation", on: model.settings.settings.mediaSidecarEnabled) { model.openSettings() }
                        capRow("eye.fill", "Vision", on: model.visionAvailable, warn: !model.visionAvailable, note: model.visionStatus) { model.openModels() }
                        capRow("books.vertical.fill", "Obsidian vault", on: model.obsidianAvailable) { model.openSettings() }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 15)
            }
        }
    }

    private func railSection<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Eyebrow(text: title, color: Brand.bone300)
            content()
        }
    }
    private var railDivider: some View { Divider().overlay(Brand.line1).padding(.vertical, 13) }

    private func statRow(_ label: String, _ value: String, dot: Color?) -> some View {
        HStack(spacing: 8) {
            Text(label.uppercased()).font(Brand.mono(10)).foregroundStyle(Brand.bone300)
            Spacer(minLength: 8)
            if let dot { StatusDot(color: dot, size: 6) }
            Text(value).font(Brand.mono(11, weight: .medium)).foregroundStyle(Brand.bone100)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    @ViewBuilder private var currentContextContent: some View {
        if let att = model.attachment {
            HStack(spacing: 10) {
                if att.kind == "image", let t = model.attachmentThumb {
                    Image(nsImage: t).resizable().scaledToFill().frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: att.kind == "image" ? "photo" : "doc.text")
                        .font(.system(size: 14)).foregroundStyle(Brand.ember500)
                        .frame(width: 32, height: 32).background(Brand.ink600).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(att.name).font(Brand.mono(11)).foregroundStyle(Brand.bone50).lineLimit(1).truncationMode(.middle)
                    Text(att.kind.uppercased()).font(Brand.mono(9, weight: .bold)).foregroundStyle(Brand.bone400)
                }
                Spacer()
                Button(action: { model.clearAttachment() }) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(Brand.bone400)
                }.buttonStyle(.plain)
            }
        } else {
            Text("No file attached. Use + to add a file, image, or AI-data export.")
                .font(Brand.body(11)).foregroundStyle(Brand.bone400).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func capRow(_ icon: String, _ label: String, on: Bool, warn: Bool = false,
                        note: String = "", config: (() -> Void)? = nil) -> some View {
        let statusColor = on ? Brand.success : (warn ? Brand.warning : Brand.bone400)
        return HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(on ? Brand.ember500 : Brand.bone400).frame(width: 18)
            Text(label).font(Brand.body(12.5)).foregroundStyle(on ? Brand.bone100 : Brand.bone300).lineLimit(1)
            Spacer(minLength: 6)
            if let config {
                Button(action: config) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 10)).foregroundStyle(Brand.bone400)
                }.buttonStyle(.plain).help(note.isEmpty ? "Configure" : note)
            }
            Text(on ? "CONNECTED" : (warn ? "UPDATE" : "OFFLINE"))
                .font(Brand.mono(8.5, weight: .bold)).foregroundStyle(statusColor)
            StatusDot(color: statusColor, size: 5)
        }
        .help(note.isEmpty ? "" : note)
    }

    // MARK: ── sheets (memory / models) ────────────────────────────────────────
    /// Model manager — download models (Ollama registry tags or Hugging Face GGUF), with live progress.
    private var modelsSheet: some View {
        ZStack {
            Brand.ink900.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("MODELS").font(Brand.display(15, weight: .bold)).kerning(2).foregroundStyle(Brand.bone50)
                    if !model.ollamaVersion.isEmpty {
                        Text("Ollama \(model.ollamaVersion)").font(Brand.mono(11)).foregroundStyle(Brand.bone300)
                    }
                    Spacer()
                    Button("DONE") { model.modelsOpen = false }
                        .buttonStyle(.plain).font(Brand.display(12, weight: .bold)).foregroundStyle(Brand.ember500)
                }
                if model.ollamaNeedsUpgradeForVision {
                    Text("Vision models (e.g. Qwen3-VL) need Ollama ≥ 0.12.7 — upgrade Ollama to enable image understanding. Text models still pull fine.")
                        .font(Brand.mono(11)).foregroundStyle(Brand.ember300)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Brand.ember500.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Eyebrow(text: "Suggested (Apache-2.0)")
                HStack(spacing: 8) {
                    pickChip("Qwen3-VL 30B", "qwen3-vl:30b-a3b-instruct")
                    pickChip("Qwen3-VL 8B", "qwen3-vl:8b")
                    pickChip("Mistral-Small 3.2", "mistral-small3.2")
                    Spacer()
                }
                HStack {
                    Eyebrow(text: "Installed")
                    if !model.installed.isEmpty {
                        Text("· \(model.installed.count) · \(sizeFmt(model.installed.reduce(0) { $0 + $1.size }))")
                            .font(Brand.mono(9)).foregroundStyle(Brand.bone300)
                    }
                    Spacer()
                    Button(action: { model.refreshModels() }) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.bone300)
                    }.buttonStyle(.plain).help("Refresh the installed list")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if model.installed.isEmpty {
                            Text("No models installed yet.").font(Brand.mono(11)).foregroundStyle(Brand.bone400)
                        }
                        ForEach(model.installed) { m in
                            ModelRow(m: m, sizeText: sizeFmt(m.size)) { pendingDelete = m.name }
                        }
                    }
                    .padding(.vertical, 2)
                    .animation(Brand.ease(0.25), value: model.installed.count)
                }
                if model.pulling || model.pullProgress > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.pullStatus).font(Brand.mono(11)).foregroundStyle(Brand.ember300)
                        ProgressView(value: model.pullProgress).tint(Brand.ember500)
                    }
                }
                if !model.hfResults.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(model.hfResults) { r in
                                Button(action: { model.pickHF(r) }) {
                                    HStack {
                                        Text(r.id).font(Brand.mono(11)).foregroundStyle(Brand.bone50).lineLimit(1)
                                        if r.gated { Text("gated").font(Brand.mono(8, weight: .bold)).foregroundStyle(Brand.ember500) }
                                        Spacer()
                                        Text(dlFmt(r.downloads)).font(Brand.mono(9)).foregroundStyle(Brand.bone300)
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                    .background(Brand.ink700).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.line1, lineWidth: 1))
                }
                HStack(spacing: 8) {
                    TextField("search Hugging Face, or paste a tag / hf.co/<org>/<repo>:<QUANT>", text: $model.pullInput)
                        .textFieldStyle(.plain).font(Brand.mono(12)).foregroundStyle(Brand.bone50)
                        .padding(10).background(Brand.ink700).clipShape(RoundedRectangle(cornerRadius: 8))
                        .onChange(of: model.pullInput) { _, _ in model.scheduleHFSearch() }
                        .onSubmit { model.pullModel(model.pullInput) }
                    Button(action: { model.pullModel(model.pullInput) }) {
                        Text("PULL").font(Brand.display(12, weight: .bold)).kerning(1)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .foregroundStyle(Brand.ink900).background(Brand.ember500).clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).disabled(model.pulling)
                }
            }
            .padding(24)
        }
        .frame(width: 640, height: 640)
        .preferredColorScheme(.dark)
        .confirmationDialog(
            "Uninstall \(pendingDelete ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { name in
            Button("Uninstall · free disk", role: .destructive) { model.deleteModel(name); pendingDelete = nil }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { name in Text("Removes \(name) and its layers from disk. You can re-download it anytime.") }
    }

    /// Memory browser — core blocks (incl. the consolidated profile) + searchable archival facts.
    private var memorySheet: some View {
        ZStack {
            Brand.ink900.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("MEMORY").font(Brand.display(15, weight: .bold)).kerning(2).foregroundStyle(Brand.bone50)
                    Text("\(model.memFactsCount) facts").font(Brand.mono(11)).foregroundStyle(Brand.bone300)
                    Spacer()
                    if model.memLoading { ProgressView().controlSize(.small) }
                    Button("BUILD PROFILE") { model.buildProfile() }
                        .buttonStyle(.plain).font(Brand.display(12, weight: .bold)).foregroundStyle(Brand.ember500)
                        .disabled(!model.connected || model.sending)
                        .help("Summarize what GINEXUS knows about you from memory, and keep it in mind")
                    Button("DONE") { model.memoryOpen = false }
                        .buttonStyle(.plain).font(Brand.display(12, weight: .bold)).foregroundStyle(Brand.bone300)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.memBlocks.isEmpty {
                            Text("Nothing learned about you yet. Tap BUILD PROFILE above to summarize what GINEXUS knows from your memory.")
                                .font(Brand.mono(12)).foregroundStyle(Brand.bone300).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(model.memBlocks) { b in
                            VStack(alignment: .leading, spacing: 4) {
                                Eyebrow(text: b.name, color: Brand.ember500)
                                Text(b.value).font(Brand.body(13)).foregroundStyle(Brand.bone50).fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(Brand.ink700).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        Divider().overlay(Color.white.opacity(0.08))
                        ForEach(model.memResults) { f in
                            HStack(alignment: .top, spacing: 8) {
                                Text(f.origin == "untrusted" ? "DATA" : "·").font(Brand.mono(8, weight: .bold))
                                    .foregroundStyle(Brand.bone300).frame(width: 34, alignment: .leading)
                                Text(f.text).font(Brand.body(12)).foregroundStyle(Brand.bone100).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                HStack(spacing: 8) {
                    TextField("Search memory…", text: $model.memQuery)
                        .textFieldStyle(.plain).font(Brand.mono(13)).foregroundStyle(Brand.bone50)
                        .padding(10).background(Brand.ink700).clipShape(RoundedRectangle(cornerRadius: 8))
                        .onSubmit { model.searchMemory() }
                    Button(action: { model.searchMemory() }) {
                        Text("SEARCH").font(Brand.display(12, weight: .bold)).kerning(1)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .foregroundStyle(Brand.ink900).background(Brand.ember500).clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
            }
            .padding(24)
        }
        .frame(width: 620, height: 640)
        .preferredColorScheme(.dark)
    }

    // MARK: ── helpers ─────────────────────────────────────────────────────────
    private func sizeFmt(_ bytes: Int) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
    private func pickChip(_ title: String, _ ref: String) -> some View {
        Button(action: { model.pullModel(ref) }) {
            Text(title).font(Brand.display(11, weight: .bold)).kerning(0.5).foregroundStyle(Brand.ember500)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Brand.ember500.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain).disabled(model.pulling).help("Pull \(ref)")
    }
    private func dlFmt(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM↓", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000)K↓" }
        return "\(n)↓"
    }
}

// MARK: - streaming answer text with a blinking ember cursor (matches the EXECUTE accent)
// MARK: - token usage gauge (Context rail) — REAL counts only, honest empty state ("—")
private struct TokenUsageGauge: View {
    let usage: TokenUsage?
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            metricRow("Prompt", usage.map { "\($0.prompt)" })
            metricRow("Completion", usage.map { "\($0.completion)" })
            // Proportional bar: ember = prompt, bone = completion. Hidden until there's real data.
            if let u = usage, u.total > 0 {
                GeometryReader { geo in
                    // Clamp to [0, width] so a malformed total (< prompt) can't overflow the bar.
                    let pw = min(geo.size.width, geo.size.width * CGFloat(u.prompt) / CGFloat(u.total))
                    HStack(spacing: 0) {
                        Rectangle().fill(Brand.ember500).frame(width: max(0, pw))
                        Rectangle().fill(Brand.bone300.opacity(0.55)).frame(width: max(0, geo.size.width - pw))
                    }
                }
                .frame(height: 4)
                .clipShape(Capsule())
                .padding(.vertical, 1)
            }
            Divider().overlay(Brand.line1).padding(.vertical, 1)
            HStack(spacing: 8) {
                Text("TOTAL").font(Brand.mono(10, weight: .bold)).foregroundStyle(Brand.bone300)
                Spacer(minLength: 8)
                Text(usage.map { "\($0.total)" } ?? "—")
                    .font(Brand.mono(12, weight: .semibold)).foregroundStyle(usage == nil ? Brand.bone400 : Brand.ember500)
            }
        }
    }
    private func metricRow(_ label: String, _ value: String?) -> some View {
        HStack(spacing: 8) {
            Text(label.uppercased()).font(Brand.mono(10)).foregroundStyle(Brand.bone300)
            Spacer(minLength: 8)
            Text(value ?? "—").font(Brand.mono(11, weight: .medium)).foregroundStyle(value == nil ? Brand.bone400 : Brand.bone100)
        }
    }
}

private struct StreamingText: View {
    let text: String
    @State private var on = true
    private let blink = Timer.publish(every: 0.53, on: .main, in: .common).autoconnect()
    var body: some View {
        Text(attributed).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).onReceive(blink) { _ in on.toggle() }
    }
    private var attributed: AttributedString {
        var s = AttributedString(text); s.font = .system(size: 14); s.foregroundColor = Brand.bone50
        var cursor = AttributedString("▌"); cursor.font = .system(size: 14); cursor.foregroundColor = on ? Brand.ember500 : .clear
        return s + cursor
    }
}

// MARK: - inline transcript image, decoded ONCE (downsampled) — never per streamed token
private struct StreamImage: View {
    let path: String
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: 420, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Brand.line2, lineWidth: 1))
            }
        }
        // .task(id:) runs once per path (not per render/token); decode a downsampled thumbnail.
        .task(id: path) { if image == nil { image = AppModel.thumbnailImage(path, maxPixel: 840) } }
    }
}

// MARK: - one conversation in the sidebar (hover affordance, inline rename, brand selection)
private struct ConversationRow: View {
    let c: ConversationMeta
    let selected: Bool
    let disabled: Bool
    @Binding var renamingID: UUID?
    @Binding var renameText: String
    let onSelect: () -> Void
    let onCommitRename: () -> Void
    let onRequestRename: () -> Void
    let onRequestDelete: () -> Void
    @State private var hover = false
    private var isRenaming: Bool { renamingID == c.id }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Title", text: $renameText)
                        .textFieldStyle(.plain).font(Brand.mono(13)).foregroundStyle(Brand.bone50).tint(Brand.ember500)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Brand.ink800).clipShape(RoundedRectangle(cornerRadius: 6))
                        .onSubmit(onCommitRename).onExitCommand { renamingID = nil }
                } else {
                    Text(c.title).font(Brand.mono(13)).foregroundStyle(selected ? Brand.ember500 : Brand.bone50).lineLimit(1)
                }
                Text("\(relativeTime(c.updatedAt)) · \(c.messageCount)").font(Brand.mono(10)).foregroundStyle(Brand.bone400)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Brand.ink700 : Color.white.opacity(hover ? 0.04 : 0))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(disabled)
        .onHover { h in withAnimation(Brand.ease) { hover = h } }
        .contextMenu {
            Button("Rename", action: onRequestRename)
            Button("Delete", role: .destructive, action: onRequestDelete)
        }
    }
}

private func relativeTime(_ d: Date) -> String {
    let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
    return f.localizedString(for: d, relativeTo: Date())
}

// MARK: - one installed model card (hover-lighten, uninstall)
private struct ModelRow: View {
    let m: InstalledModel
    let sizeText: String
    let onDelete: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox.fill").font(.system(size: 13)).foregroundStyle(Brand.ember500.opacity(0.85))
            VStack(alignment: .leading, spacing: 2) {
                Text(m.name).font(Brand.mono(12, weight: .medium)).foregroundStyle(Brand.bone50).lineLimit(1)
                Text([m.detail, sizeText].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                    .font(Brand.mono(10)).foregroundStyle(Brand.bone300)
            }
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(hover ? Brand.bone50 : Brand.bone400)
            }.buttonStyle(.plain).help("Uninstall and free disk")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.white.opacity(hover ? 0.07 : 0.035))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(hover ? 0.13 : 0.06), lineWidth: 1))
        .onHover { h in withAnimation(Brand.ease) { hover = h } }
    }
}

// MARK: - headless render-safe mirror of the stream (for ImageRenderer verification)
struct SnapshotView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ZStack {
            Brand.ink900
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) { Wordmark(size: 30); Spacer() }
                HStack(spacing: 8) {
                    StatusDot(color: model.connected ? Brand.success : Brand.bone400, size: 8)
                    Text(model.spineStatus).font(Brand.mono(11, weight: .medium))
                        .foregroundStyle(model.connected ? Brand.success : Brand.bone400)
                    Spacer()
                }
                ForEach(model.chat) { msg in
                    let isUser = msg.role == "user"
                    VStack(alignment: .leading, spacing: 3) {
                        Eyebrow(text: isUser ? "User Input" : "GINEXUS", color: isUser ? Brand.ember500 : Brand.bone300)
                        Text(msg.text).font(Brand.mono(14)).foregroundStyle(Brand.bone50)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(isUser ? Brand.ink700 : Color.white.opacity(0.03))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                if model.sending { Text("…thinking").font(Brand.mono(12)).foregroundStyle(Brand.ember500) }
                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .frame(width: 640, height: 560)
    }
}
