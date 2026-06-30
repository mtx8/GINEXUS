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
        .overlay { if model.paletteOpen { CommandPalette(model: model) } }
        .animation(Brand.ease(0.18), value: model.paletteOpen)
        .sheet(isPresented: $model.memoryOpen) { memorySheet }
        .sheet(isPresented: $model.modelsOpen) { modelsSheet }
        .sheet(isPresented: $model.settingsOpen) { SettingsView(model: model, store: model.settings) }
        .sheet(isPresented: $model.projectSheetOpen) { ProjectEditorSheet(model: model) }
        .sheet(isPresented: $model.connectionsOpen) { ConnectionsSheet(model: model) }
        .sheet(isPresented: $model.projectsOpen) { ProjectsSheet(model: model) }
        .sheet(isPresented: $model.schedulesOpen) { ScheduledTasksSheet(model: model) }
        .sheet(isPresented: $model.scheduleSheetOpen) { ScheduleEditorSheet(model: model) }
    }

    // MARK: ── far-left icon rail ───────────────────────────────────────────────
    private var iconRail: some View {
        VStack(spacing: 6) {
            GlyphMark(size: 38, spinning: model.sending).padding(.top, 16).padding(.bottom, 12)
            railIcon("square.and.pencil", "New conversation", enabled: model.connected && !model.sending) { model.newChat() }
            railIcon("folder", "Projects — folders, files, custom instructions", enabled: model.connected) {
                model.selectedProjectID = model.activeProjectID ?? model.projects.first?.id
                model.projectsOpen = true
            }
            railIcon("clock.arrow.circlepath", "Scheduled tasks — routine automation", enabled: model.connected) { model.openSchedules() }
            railIcon("brain", "Memory — what GINEXUS knows", enabled: model.connected) { model.openMemory() }
            railIcon("cube.box", "Models — download / manage", enabled: model.connected, animating: model.pulling) { model.openModels() }
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
                          animating: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 16))
                .foregroundStyle(animating ? Brand.ember500 : (enabled ? Brand.bone300 : Brand.bone400))
                .symbolEffect(.pulse, isActive: animating)   // pulses while a model is downloading
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
                // Scope picker — one click to switch between regular chats and any project.
                Menu {
                    Button { model.setScope(nil) } label: {
                        Label("All Chats", systemImage: model.activeProjectID == nil ? "checkmark" : "bubble.left.and.bubble.right")
                    }
                    if !model.projects.isEmpty {
                        Divider()
                        ForEach(model.projects) { p in
                            Button { model.setScope(p.id) } label: {
                                Label(p.name, systemImage: p.id == model.activeProjectID ? "checkmark" : "folder")
                            }
                        }
                    }
                    Divider()
                    Button { model.openNewProjectSheet() } label: { Label("New project…", systemImage: "plus") }
                    Button { model.selectedProjectID = model.activeProjectID ?? model.projects.first?.id; model.projectsOpen = true } label: {
                        Label("Manage projects…", systemImage: "folder.badge.gearshape")
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: model.activeProject != nil ? "folder.fill" : "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 11)).foregroundStyle(model.activeProject != nil ? Brand.ember500 : Brand.bone300)
                        Text(model.activeProject?.name ?? "All Chats")
                            .font(Brand.mono(12, weight: .bold)).foregroundStyle(Brand.bone100).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Brand.bone400)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 9).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(model.activeProject != nil ? Brand.ember500.opacity(0.07) : Color.clear)
                Divider().overlay(Brand.line1)

                if model.visibleConversations.isEmpty {
                    Text(model.activeProject != nil ? "No threads in this project yet — tap +" : "No conversations yet")
                        .font(Brand.mono(11)).foregroundStyle(Brand.bone400)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.top, 14)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(model.visibleConversations) { c in
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
            commandPaletteButton.layoutPriority(1)
            autonomyToggle.layoutPriority(1)
            modelSelector.layoutPriority(1)
        }
    }

    /// ⌘K affordance — opens the command palette. Carries the window-wide ⌘K shortcut.
    private var commandPaletteButton: some View {
        Button { model.paletteOpen = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .semibold))
                Text("⌘K").font(Brand.mono(10.5, weight: .bold)).kerning(0.5)
            }
            .foregroundStyle(Brand.bone300)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Brand.ink850).clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Brand.line2, lineWidth: 1))
        }
        .buttonStyle(.plain).help("Command palette (⌘K)")
        .keyboardShortcut("k", modifiers: .command)
    }

    private var autonomyToggle: some View {
        Button(action: { model.autonomous.toggle() }) {
            // Box-less — just the icon + label, no border/plate (cleaner, more modern).
            HStack(spacing: 6) {
                Image(systemName: model.autonomous ? "bolt.fill" : "hand.raised.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(model.autonomous ? "AUTO" : "HITL").font(Brand.mono(10.5, weight: .bold)).kerning(1.2)
            }
            .foregroundStyle(model.autonomous ? Brand.ember500 : Brand.bone300)
            .padding(.vertical, 6).padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!model.connected)
        .help(model.autonomous
            ? "Autonomous — irreversible actions run unattended EXCEPT the hard gate (money / comms / legal / delete / exec)."
            : "Human-in-the-loop — every irreversible action asks for Touch ID.")
    }

    private var modelSelector: some View {
        Menu {
            Section("Local · Apple Silicon") {
                ForEach(model.models) { m in
                    Button(action: { model.selectedModel = m.id }) {
                        if m.id == model.selectedModel { Label(Self.modelMenuTitle(m), systemImage: "checkmark") }
                        else { Text(Self.modelMenuTitle(m)) }
                    }
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

    /// "Qwen3-30B · smart" — the model name with its routing tier (the roster id) as a suffix.
    static func modelMenuTitle(_ m: ModelOption) -> String {
        m.id == "auto" ? m.label : "\(m.label)  ·  \(m.id)"
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

    /// The opening canvas — a confident display heading + tappable starter prompts that route
    /// straight into the stream. Starter prompts are real sends (no canned answers); the research
    /// one arms Deep Research first.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 11) {
                Eyebrow(text: "Ready", color: Brand.ember500, tick: true)
                Text("What should we work on?")
                    .font(Brand.display(34, weight: .heavy)).foregroundStyle(Brand.bone50)
                    .fixedSize(horizontal: false, vertical: true)
                Text("GINEXUS runs entirely on this Mac. Ask anything, or start with one of these — you'll watch each tool work the stream.")
                    .font(Brand.body(14)).foregroundStyle(Brand.bone300)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 10) {
                ForEach(Self.starterPrompts) { s in
                    StarterCard(icon: s.icon, title: s.title, route: s.route,
                                disabled: !model.connected || model.sending) { startStarter(s) }
                }
            }
        }
        .padding(.top, 40)
    }

    struct StarterPrompt: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let route: String
        let prompt: String
        let deepResearch: Bool
    }
    static let starterPrompts: [StarterPrompt] = [
        .init(icon: "doc.text.magnifyingglass",
              title: "Research the state of local-first LLM agents",
              route: "web · deep research → cited report",
              prompt: "Research the current state of local-first, on-device LLM agents — the leading open-weight models, the runtimes (MLX, llama.cpp, Ollama), and where the field is heading. Search the web, cross-check the facts, and give me a clear report that cites its sources.",
              deepResearch: true),
        .init(icon: "terminal.fill",
              title: "Clean up my caches and free disk space",
              route: "terminal → Touch ID approval gate",
              prompt: "Survey what's taking up disk space in my user caches (~/Library/Caches and common dev-tool caches) and propose exactly what's safe to clean. Anything destructive waits for my Touch ID approval.",
              deepResearch: false),
        .init(icon: "person.3.fill",
              title: "Weigh shipping the always-on agent now vs. later",
              route: "council → parallel deliberation → synthesis",
              prompt: "Convene a council to deliberate: should GINEXUS ship the always-on background agent now, or after the v1 daily-driver lands? Argue both sides in parallel, then give me the synthesized verdict.",
              deepResearch: false),
    ]
    private func startStarter(_ s: StarterPrompt) {
        if s.deepResearch { model.deepResearchMode = true }
        model.send(s.prompt)
    }

    /// One conversation turn. Your message → a right-aligned soft bubble. GINEXUS's reply → the
    /// agent FLOW: an "Action" card per tool the agent used (the execution blocks from your reference),
    /// then the answer as clean bare prose led by the brand glyph. Plain chats (no tools) show no
    /// cards — just the prose — so it stays clean, not gimmicky.
    /// Contextual SF Symbol for what GINEXUS is doing — the live/finished tool drives the icon.
    static func activityIcon(_ tool: String) -> String {
        let t = tool.lowercased()
        switch true {
        case t.contains("image") || t.contains("photo"):              return "photo"
        case t.contains("document") || t.contains("pdf") || t.contains("docx"): return "doc.text"
        case t.contains("note"):                                       return "square.and.pencil"
        case t.contains("deep_research") || t.contains("research"):    return "doc.text.magnifyingglass"
        case t.contains("delegate") || t.contains("subagent") || t.contains("worker"): return "person.2.fill"
        case t.contains("council"):                                    return "person.3.fill"
        case t.contains("web") || t.contains("fetch") || t.contains("search"): return "globe"
        case t.contains("command") || t.contains("terminal") || t.contains("shell"): return "terminal.fill"
        case t.contains("memory") || t.contains("recall") || t.contains("remember") || t.contains("consolidate"): return "brain.head.profile"
        case t.contains("obsidian") || t.contains("vault"):            return "books.vertical.fill"
        case t.contains("ingest") || t.contains("import"):             return "tray.and.arrow.down.fill"
        case t.contains("calendar"):                                   return "calendar"
        case t.contains("shortcut"):                                   return "wand.and.rays"
        case t.contains("status") || t.contains("system"):            return "cpu"
        default:                                                       return "bolt.fill"
        }
    }

    /// Friendly label for an activity — present tense while running, neutral/past when done.
    static func activityLabel(_ tool: String, done: Bool) -> String {
        let t = tool.lowercased()
        switch true {
        case t.contains("image") || t.contains("photo"):              return done ? "Image generated" : "Generating image"
        case t.contains("document") || t.contains("pdf") || t.contains("docx"): return done ? "Document created" : "Creating document"
        case t.contains("note"):                                       return done ? "Note written" : "Writing note"
        case t.contains("deep_research") || t.contains("research"):    return done ? "Deep research" : "Researching"
        case t.contains("delegate") || t.contains("subagent") || t.contains("worker"): return done ? "Agents finished" : "Agents working"
        case t.contains("council"):                                    return done ? "Council convened" : "Consulting council"
        case t.contains("web") || t.contains("fetch") || t.contains("search"): return done ? "Web research" : "Researching the web"
        case t.contains("command") || t.contains("terminal") || t.contains("shell"): return done ? "Command run" : "Running command"
        case t.contains("memory") || t.contains("recall") || t.contains("remember") || t.contains("consolidate"): return done ? "Memory updated" : "Working memory"
        case t.contains("obsidian") || t.contains("vault"):            return done ? "Vault read" : "Reading the vault"
        case t.contains("ingest") || t.contains("import"):             return done ? "Data ingested" : "Ingesting data"
        case t.contains("calendar"):                                   return done ? "Calendar checked" : "Checking calendar"
        case t.contains("shortcut"):                                   return done ? "Shortcut run" : "Running shortcut"
        case t.contains("status") || t.contains("system"):            return done ? "System checked" : "Checking system"
        default:                                                       return tool
        }
    }

    /// The turn's activity timeline: completed steps (in order) + the one currently running, if any.
    private func activityTimeline(_ msg: ChatMsg) -> [(tool: String, done: Bool)] {
        var items: [(tool: String, done: Bool)] = msg.steps.map { (tool: $0, done: true) }
        if msg.streaming, let s = msg.status { items.append((tool: s, done: false)) }
        return items
    }

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
                // ONE timeline of activity cards: each completed step (done) plus the one currently
                // running. A running card flips to "Completed" IN PLACE (same offset → same card),
                // so it "completes from the same animation". Each shows the icon for what it is doing.
                ForEach(Array(activityTimeline(msg).enumerated()), id: \.offset) { _, item in
                    BlockCard(label: Self.activityLabel(item.tool, done: item.done),
                              icon: Self.activityIcon(item.tool), accent: Brand.ember300,
                              active: !item.done, iconAnimating: !item.done) {
                        if item.done {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Brand.success)
                                Text("Completed").font(Brand.mono(11)).foregroundStyle(Brand.bone300)
                            }
                        } else {
                            Text("Running…").font(Brand.mono(11)).foregroundStyle(Brand.ember300)
                        }
                    }
                }
                // The answer — bare, readable prose led by the brand glyph (Gemini-clean).
                HStack(alignment: .top, spacing: 12) {
                    GlyphMark(size: 22, spinning: msg.streaming)
                    VStack(alignment: .leading, spacing: 10) {
                        if msg.streaming {
                            // Render Markdown WHILE streaming too, so the user never sees raw ###/**/```.
                            if msg.text.isEmpty { StreamingText(text: msg.text) }
                            else { MarkdownReply(text: msg.text) }
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
            if let vc = model.voiceController { VoiceStatusBar(controller: vc) }
            if model.deepResearchMode { deepResearchHint }
            attachmentChip
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    plusMenu
                    TextField("Message GINEXUS…", text: $model.chatInput)
                        .textFieldStyle(.plain).font(Brand.mono(14)).foregroundStyle(Brand.bone50)
                        .onSubmit { model.send(model.chatInput) }
                }
                .padding(.horizontal, 12).padding(.vertical, 12)
                .background(Brand.cardFill).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .top) { Brand.topSheen.frame(height: 1).clipShape(RoundedRectangle(cornerRadius: 10)) }
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Brand.line1, lineWidth: 1))
                researchButton
                voiceButton
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

    /// Deep Research toggle — arm it, then send your question and the GINEXUS research team (Nexus
    /// RND/STR) searches the web, cross-checks, and returns a cited report. Always clickable when
    /// connected; lights up ember when armed; disarms after one message.
    private var researchButton: some View {
        Button(action: model.toggleDeepResearch) {
            Image(systemName: "binoculars.fill").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(model.deepResearchMode ? Brand.ink900 : Brand.bone200)
                .frame(width: 46, height: 46)
                .background(model.deepResearchMode ? AnyShapeStyle(Brand.ember500) : AnyShapeStyle(Brand.cardFill))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(model.deepResearchMode ? Brand.ember500 : Brand.line1, lineWidth: 1))
                .shadow(color: model.deepResearchMode ? Brand.ember500.opacity(0.45) : .clear, radius: 9)
        }
        .buttonStyle(.plain)
        .disabled(!model.connected)
        .help(model.deepResearchMode
              ? "Deep Research armed — your next message gets researched. Click to cancel."
              : "Deep Research — search the web and return a cited report")
    }

    /// Banner shown above the composer while Deep Research is armed, so the feature is unmistakable.
    private var deepResearchHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "binoculars.fill").font(.system(size: 11)).foregroundStyle(Brand.ember500)
            Text("Deep Research armed — your next message will be searched, cross-checked, and returned as a cited report.")
                .font(Brand.mono(10)).foregroundStyle(Brand.bone200).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { model.deepResearchMode = false } label: {
                Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(Brand.bone400)
            }.buttonStyle(.plain).help("Cancel Deep Research")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Brand.ember500.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.ember500.opacity(0.4), lineWidth: 1))
    }

    /// Mic toggle — starts/stops the hands-free voice conversation (SP-Voice). Animated waveform
    /// when live; the ring + glow pulse with the brand ember.
    private var voiceButton: some View {
        Button(action: model.toggleVoice) {
            Group {
                if let vc = model.voiceController {
                    VoiceWaveformIcon(controller: vc)
                } else {
                    Image(systemName: "mic.fill").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Brand.bone200)
                }
            }
            .frame(width: 46, height: 46)
            .background(Brand.cardFill).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(model.voiceActive ? Brand.ember500.opacity(0.75) : Brand.line1, lineWidth: 1))
            .shadow(color: model.voiceActive ? Brand.ember500.opacity(0.45) : .clear, radius: 9)
        }
        .buttonStyle(.plain)
        .disabled(!model.connected)
        .help(model.voiceActive ? "Stop voice conversation" : "Talk to GINEXUS (hands-free)")
    }

    /// The "+" menu inside the input row: capabilities that act on your message, plus attachments.
    private var plusMenu: some View {
        Menu {
            Section("Do with your message") {
                Button("Perspectives", action: model.runCouncil).disabled(!model.canQuickAction)
                Button("Research", action: model.runResearch).disabled(!model.canQuickAction)
                Button("Create image", action: model.runImage).disabled(!model.canQuickAction)
            }
            Section(model.activeProject.map { "Project: \($0.name)" } ?? "Project: none") {
                Button("New project…", action: model.openNewProjectSheet)
                if !model.projects.isEmpty {
                    Menu("Switch project") {
                        Button("None (loose chat)") { model.selectProject(nil) }
                        ForEach(model.projects) { p in
                            Button(p.name) { model.selectProject(p.id) }
                        }
                    }
                }
                if let p = model.activeProject {
                    Button("Edit “\(p.name)”…") { model.openEditProjectSheet(p.id) }
                    if p.folderPath != nil { Button("Reveal project folder", action: model.revealProjectFolder) }
                    Button("Delete “\(p.name)”", role: .destructive) { model.deleteProject(p.id) }
                }
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
                    railSection("Context Budget") {
                        ContextBudgetGauge(usage: model.lastUsage, compaction: model.lastCompaction)
                    }
                    railDivider
                    connectionsSection
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

    /// Connections summary — a single "MCP & tools" row with live counts + a MANAGE shortcut into
    /// the Connections sheet. Counts come from the real server/tool surface (see connectionServers).
    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Eyebrow(text: "Connections", color: Brand.bone300)
                Spacer()
                Button { model.connectionsOpen = true } label: {
                    Text("MANAGE").font(Brand.mono(9, weight: .bold)).kerning(1).foregroundStyle(Brand.ember500)
                }.buttonStyle(.plain).help("Manage MCP servers & tools").disabled(!model.connected)
            }
            Button { model.connectionsOpen = true } label: {
                HStack(spacing: 11) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Brand.ember500).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MCP & tools").font(Brand.body(12.5, weight: .medium)).foregroundStyle(Brand.bone100)
                        Text("\(model.connectedServerCount) connected · \(model.exposedToolCount) tools")
                            .font(Brand.mono(9.5)).foregroundStyle(Brand.bone400)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Brand.bone400)
                }
                .padding(.horizontal, 11).padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(Brand.cardFill).clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Brand.line1, lineWidth: 1))
                .contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!model.connected)
        }
    }

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
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.memBlocks.isEmpty {
                            HStack {
                                Text("Nothing learned about you yet — tap BUILD PROFILE, or")
                                    .font(Brand.mono(12)).foregroundStyle(Brand.bone300)
                                Button("WRITE ONE") { model.newProfileBlock() }
                                    .buttonStyle(.plain).font(Brand.mono(11, weight: .bold)).foregroundStyle(Brand.ember500)
                            }.fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(model.memBlocks) { b in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Eyebrow(text: b.name, color: Brand.ember500)
                                    Spacer()
                                    if model.editingBlock != b.name {
                                        Button("EDIT") { model.beginEditBlock(b.name, value: b.value) }
                                            .buttonStyle(.plain).font(Brand.mono(10, weight: .bold)).foregroundStyle(Brand.bone300)
                                    }
                                }
                                if model.editingBlock == b.name {
                                    TextEditor(text: $model.blockDraft)
                                        .font(Brand.body(13)).foregroundStyle(Brand.bone50).scrollContentBackground(.hidden)
                                        .frame(minHeight: 120)
                                        .padding(8).background(Brand.ink850).clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Brand.ember600.opacity(0.5), lineWidth: 1))
                                    HStack {
                                        Spacer()
                                        Button("CANCEL") { model.cancelEditBlock() }
                                            .buttonStyle(.plain).font(Brand.mono(11)).foregroundStyle(Brand.bone300)
                                        Button("SAVE") { model.saveBlock() }
                                            .buttonStyle(.plain).font(Brand.mono(11, weight: .bold)).foregroundStyle(Brand.ink900)
                                            .padding(.horizontal, 14).padding(.vertical, 7)
                                            .background(Brand.ember500).clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                } else {
                                    highlightedText(b.value, terms: model.memTerms, current: false)
                                        .font(Brand.body(13)).foregroundStyle(Brand.bone50).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(Brand.ink700).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        Divider().overlay(Color.white.opacity(0.08))
                        ForEach(Array(model.memResults.enumerated()), id: \.offset) { idx, f in
                            HStack(alignment: .top, spacing: 8) {
                                Text(f.origin == "untrusted" ? "DATA" : "·").font(Brand.mono(8, weight: .bold))
                                    .foregroundStyle(Brand.bone300).frame(width: 34, alignment: .leading)
                                highlightedText(f.text, terms: model.memTerms, current: idx == model.memMatchIndex)
                                    .font(Brand.body(12)).foregroundStyle(Brand.bone100).fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 4).padding(.horizontal, 6)
                            .background(idx == model.memMatchIndex && !model.memTerms.isEmpty ? Brand.ember500.opacity(0.10) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .id(idx)
                        }
                    }
                }
                .onChange(of: model.memMatchIndex) { _, new in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(new, anchor: .center) }
                }
                }   // ScrollViewReader
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("Search memory…", text: $model.memQuery)
                            .textFieldStyle(.plain).font(Brand.mono(13)).foregroundStyle(Brand.bone50)
                            .onSubmit { model.searchMemory() }
                        // Office-style match counter + prev/next, shown once there are results.
                        if !model.memResults.isEmpty {
                            Text("\(model.memMatchIndex + 1) of \(model.memResults.count)")
                                .font(Brand.mono(11)).monospacedDigit().foregroundStyle(Brand.bone300)
                            Button(action: model.memPrev) {
                                Image(systemName: "chevron.up").font(.system(size: 11, weight: .bold)).foregroundStyle(Brand.bone200)
                            }.buttonStyle(.plain).keyboardShortcut(.upArrow, modifiers: []).help("Previous match")
                            Button(action: model.memNext) {
                                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Brand.bone200)
                            }.buttonStyle(.plain).keyboardShortcut(.downArrow, modifiers: []).help("Next match")
                        }
                    }
                    .padding(10).background(Brand.ink700).clipShape(RoundedRectangle(cornerRadius: 8))
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
/// SP-Connect: manage external MCP integrations. Notion has a one-paste preset; others can be added
/// as a raw stdio command. Secrets go to the Keychain; changes apply on the next app restart.
/// Scheduled tasks (cron jobs) — routine automation that runs unattended on a cadence. Each task
/// carries its own custom instructions and optional attached files. Discoverable from the left rail.
private struct ScheduledTasksSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 12)).foregroundStyle(Brand.ember500)
                Text("SCHEDULED TASKS").font(Brand.mono(12, weight: .bold)).kerning(2).foregroundStyle(Brand.bone100)
                Spacer()
                Button(action: model.openNewScheduleSheet) {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                        Text("NEW").font(Brand.mono(10, weight: .bold)).kerning(1)
                    }.foregroundStyle(Brand.ember500)
                }.buttonStyle(.plain).help("New scheduled task")
                Button { model.schedulesOpen = false } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Brand.bone300)
                }.buttonStyle(.plain).help("Close")
            }
            .padding(.horizontal, 18).padding(.vertical, 13)
            Divider().overlay(Brand.line1)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Tasks run on their own in the background. Each one follows your instructions and can read files you attach. Read-only by default — anything irreversible waits for your approval.")
                        .font(Brand.mono(10)).foregroundStyle(Brand.bone400).fixedSize(horizontal: false, vertical: true)

                    if model.schedules.isEmpty {
                        emptyState
                    } else {
                        ForEach(model.schedules) { task in taskCard(task) }
                    }
                }
                .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 20)
            }
        }
        .frame(width: 540, height: 600)
        .background(Brand.ink850)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.badge.questionmark").font(.system(size: 30)).foregroundStyle(Brand.bone400)
            Text("No scheduled tasks yet").font(Brand.mono(13, weight: .bold)).foregroundStyle(Brand.bone200)
            Text("Create one to run routine work automatically — a morning digest, a weekly report, a recurring check.")
                .font(Brand.mono(10)).foregroundStyle(Brand.bone400).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: model.openNewScheduleSheet) {
                Text("NEW TASK").font(Brand.mono(11, weight: .bold)).kerning(1.2).foregroundStyle(Brand.ink900)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(Brand.ember500).clipShape(RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).padding(.top, 4)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    private func taskCard(_ task: ScheduledTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(task.displayTitle).font(Brand.mono(13, weight: .bold)).foregroundStyle(Brand.bone100).lineLimit(1)
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { task.enabled }, set: { model.toggleSchedule(task.id, enabled: $0) }))
                    .labelsHidden().toggleStyle(.switch).tint(Brand.ember500).help(task.enabled ? "Pause" : "Resume")
                Button(role: .destructive) { model.removeSchedule(task.id) } label: {
                    Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(Brand.bone300)
                }.buttonStyle(.plain).help("Delete task")
            }

            // Cadence · next run · run count — at-a-glance status.
            HStack(spacing: 8) {
                metaChip("clock", task.cadenceLabel)
                metaChip("calendar", task.nextRunLabel)
                if task.runs > 0 { metaChip("checkmark.circle", "\(task.runs) run\(task.runs == 1 ? "" : "s")") }
            }

            if task.prompt.trimmingCharacters(in: .whitespacesAndNewlines) != task.displayTitle {
                Text(task.prompt).font(Brand.mono(10)).foregroundStyle(Brand.bone300).lineLimit(2)
            }

            if !task.attachments.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "paperclip").font(.system(size: 9)).foregroundStyle(Brand.bone400)
                    Text(task.attachments.joined(separator: ", "))
                        .font(Brand.mono(9)).foregroundStyle(Brand.bone400).lineLimit(1)
                }
            }

            if !task.lastResult.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("LAST RESULT").font(Brand.mono(8, weight: .bold)).kerning(1).foregroundStyle(Brand.bone400)
                    Text(task.lastResult).font(Brand.mono(10)).foregroundStyle(Brand.bone300).lineLimit(4)
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.ink900).clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.cardFill).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Brand.line1, lineWidth: 1))
        .opacity(task.enabled ? 1 : 0.6)
    }

    private func metaChip(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 8))
            Text(text).font(Brand.mono(9))
        }
        .foregroundStyle(Brand.bone300)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Brand.ink900).clipShape(Capsule())
    }
}

/// Create a scheduled task: a name, the instructions GINEXUS follows each run, a cadence, and any
/// files to attach. Files are read app-side and copied to the task (the sidecar can't reach iCloud /
/// TCC folders); iCloud paths are refused.
private struct ScheduleEditorSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("NEW SCHEDULED TASK").font(Brand.mono(13, weight: .bold)).kerning(2).foregroundStyle(Brand.bone200)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(Brand.mono(11)).foregroundStyle(Brand.bone300)
                TextField("e.g. Morning news digest", text: $model.schedDraftName)
                    .textFieldStyle(.plain).font(Brand.mono(14)).foregroundStyle(Brand.bone50)
                    .padding(10).background(Brand.cardFill).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.line1, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Instructions").font(Brand.mono(11)).foregroundStyle(Brand.bone300)
                Text("What GINEXUS should do each time this runs. Be specific.")
                    .font(Brand.mono(10)).foregroundStyle(Brand.bone400)
                TextEditor(text: $model.schedDraftPrompt)
                    .font(Brand.mono(13)).foregroundStyle(Brand.bone50).scrollContentBackground(.hidden)
                    .frame(minHeight: 96)
                    .padding(8).background(Brand.cardFill).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.line1, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Runs").font(Brand.mono(11)).foregroundStyle(Brand.bone300)
                Picker("", selection: $model.schedDraftEverySecs) {
                    ForEach(ScheduleCadence.allCases) { c in Text(c.label).tag(c.rawValue) }
                }
                .labelsHidden().pickerStyle(.menu).tint(Brand.ember500)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Files").font(Brand.mono(11)).foregroundStyle(Brand.bone300)
                    Spacer()
                    Button("Add file…", action: model.addFilesToScheduleDraft)
                        .buttonStyle(.plain).font(Brand.mono(11, weight: .bold)).foregroundStyle(Brand.ember500)
                }
                if model.schedDraftFiles.isEmpty {
                    Text("Optional — attach documents the task should read each run.")
                        .font(Brand.mono(10)).foregroundStyle(Brand.bone400)
                } else {
                    VStack(spacing: 3) {
                        ForEach(model.schedDraftFiles, id: \.self) { f in
                            HStack(spacing: 8) {
                                Image(systemName: "doc").font(.system(size: 10)).foregroundStyle(Brand.bone300)
                                Text(f.lastPathComponent).font(Brand.mono(11)).foregroundStyle(Brand.bone100).lineLimit(1)
                                Spacer(minLength: 0)
                                Button { model.removeScheduleDraftFile(f) } label: {
                                    Image(systemName: "xmark").font(.system(size: 9))
                                }.buttonStyle(.plain).foregroundStyle(Brand.bone400)
                            }
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { model.scheduleSheetOpen = false }
                    .buttonStyle(.plain).font(Brand.mono(12)).foregroundStyle(Brand.bone200)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                Button(action: model.saveScheduleSheet) {
                    Text("CREATE").font(Brand.mono(12, weight: .bold)).kerning(1.4).foregroundStyle(Brand.ink900)
                        .padding(.horizontal, 22).padding(.vertical, 12)
                        .background(Brand.ember500).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(model.schedDraftPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22).frame(width: 480)
        .background(Brand.ink850)
    }
}

private struct ConnectionsSheet: View {
    @ObservedObject var model: AppModel
    @State private var showAddForm = false

    private let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 13)).foregroundStyle(Brand.ember500)
                Text("CONNECTIONS").font(Brand.mono(13, weight: .bold)).kerning(2).foregroundStyle(Brand.bone200)
                Spacer()
                Button("DONE") { model.connectionsOpen = false }
                    .buttonStyle(.plain).font(Brand.mono(11, weight: .bold)).kerning(1).foregroundStyle(Brand.ember500)
            }
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 14)
            Divider().overlay(Brand.line1)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    coreSummaryCard

                    HStack(alignment: .firstTextBaseline) {
                        Eyebrow(text: "MCP Servers & Exposed Tools", tick: true)
                        Spacer()
                        Button { withAnimation(Brand.ease) { showAddForm.toggle() } } label: {
                            HStack(spacing: 5) {
                                Image(systemName: showAddForm ? "xmark" : "plus").font(.system(size: 10, weight: .bold))
                                Text(showAddForm ? "CLOSE" : "ADD").font(Brand.mono(10, weight: .bold)).kerning(1)
                            }
                            .foregroundStyle(Brand.ember500)
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Brand.ember500.opacity(0.4), lineWidth: 1))
                        }.buttonStyle(.plain).help("Add an MCP server")
                    }

                    if showAddForm { addServerForm.transition(.opacity.combined(with: .move(edge: .top))) }

                    LazyVGrid(columns: cols, spacing: 12) {
                        ForEach(model.connectionServers) { s in
                            ServerCard(server: s,
                                       onToggle: { on in if let e = s.external { model.setMcpEnabled(e.id, on) } },
                                       onRemove: { if let e = s.external { model.removeMcpServer(e.id) } })
                        }
                    }
                }
                .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 22)
            }
        }
        .frame(width: 760, height: 660)
        .background(Brand.ink900)
    }

    /// The core itself — the always-on Rust MCP host — summarized with live connected/tool counts.
    private var coreSummaryCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "cpu").font(.system(size: 18, weight: .semibold)).foregroundStyle(Brand.ember500)
                .frame(width: 42, height: 42).background(Brand.ember500.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text("ginexus-core").font(Brand.mono(14, weight: .bold)).foregroundStyle(Brand.bone50)
                Text("Rust · MCP host · UDS + HMAC · hash-chained audit")
                    .font(Brand.mono(10)).foregroundStyle(Brand.bone400)
            }
            Spacer(minLength: 12)
            countPill("\(model.connectedServerCount)", "CONNECTED")
            countPill("\(model.exposedToolCount)", "TOOLS")
        }
        .padding(16)
        .background(Brand.cardFill).clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .top) { Brand.topSheen.frame(height: 1).clipShape(RoundedRectangle(cornerRadius: 14)) }
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.ember600.opacity(0.35), lineWidth: 1))
    }

    private func countPill(_ value: String, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value).font(Brand.display(22, weight: .heavy)).foregroundStyle(Brand.ember500)
            Text(label).font(Brand.mono(8, weight: .bold)).kerning(1).foregroundStyle(Brand.bone400)
        }
        .padding(.leading, 14)
    }

    /// The add-external-server panel (presets + generic stdio form) — collapsed behind the ADD button.
    private var addServerForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect external tools over MCP. Tool calls are approval-gated; writes need your biometric OK. Changes apply after restarting GINEXUS.")
                .font(Brand.mono(10)).foregroundStyle(Brand.bone400).fixedSize(horizontal: false, vertical: true)
            presetRow("Notion", hint: "Internal integration token (“ntn_” / “secret_”).",
                      placeholder: "Notion integration token", token: $model.notionTokenDraft, connect: model.connectNotion)
            presetRow("GitHub", hint: "Personal access token (repo / issues scopes).",
                      placeholder: "GitHub PAT (ghp_… / github_pat_…)", token: $model.githubTokenDraft, connect: model.connectGitHub)
            Divider().overlay(Brand.line1)
            VStack(alignment: .leading, spacing: 6) {
                Text("ADD A SERVER").font(Brand.mono(10, weight: .bold)).kerning(1.5).foregroundStyle(Brand.bone300)
                Text("Any MCP server with a stdio command — e.g. Shopify: npx -y @shopify/dev-mcp")
                    .font(Brand.mono(9)).foregroundStyle(Brand.bone400)
                field("Name (e.g. shopify)", $model.mcpCustomName)
                field("Command (e.g. npx -y @shopify/dev-mcp)", $model.mcpCustomCommand)
                HStack(spacing: 8) {
                    field("Token env var (optional)", $model.mcpCustomTokenEnv)
                    secure("Token (optional)", $model.mcpCustomToken)
                }
                HStack {
                    Spacer()
                    Button(action: model.addCustomMcp) {
                        Text("ADD SERVER").font(Brand.mono(11, weight: .bold)).kerning(1.2).foregroundStyle(Brand.ink900)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(Brand.ember500).clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                    .disabled(model.mcpCustomName.trimmingCharacters(in: .whitespaces).isEmpty
                              || model.mcpCustomCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(14)
        .background(Brand.ink850.opacity(0.55)).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.line1, lineWidth: 1))
    }

    private func presetRow(_ title: String, hint: String, placeholder: String,
                           token: Binding<String>, connect: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Brand.mono(12, weight: .bold)).foregroundStyle(Brand.bone100)
            Text(hint).font(Brand.mono(10)).foregroundStyle(Brand.bone400)
            HStack(spacing: 8) {
                SecureField(placeholder, text: token)
                    .textFieldStyle(.plain).font(Brand.mono(12)).foregroundStyle(Brand.bone50)
                    .padding(10).background(Brand.cardFill).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.line1, lineWidth: 1))
                Button(action: connect) {
                    Text("CONNECT").font(Brand.mono(11, weight: .bold)).kerning(1.2).foregroundStyle(Brand.ink900)
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .background(Brand.ember500).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).disabled(token.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func field(_ ph: String, _ text: Binding<String>) -> some View {
        TextField(ph, text: text)
            .textFieldStyle(.plain).font(Brand.mono(11)).foregroundStyle(Brand.bone50)
            .padding(9).background(Brand.cardFill).clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Brand.line1, lineWidth: 1))
    }
    private func secure(_ ph: String, _ text: Binding<String>) -> some View {
        SecureField(ph, text: text)
            .textFieldStyle(.plain).font(Brand.mono(11)).foregroundStyle(Brand.bone50)
            .padding(9).background(Brand.cardFill).clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Brand.line1, lineWidth: 1))
    }
}

/// One server card in the Connections grid — icon, name, subtitle, on/off, transport badge, tool
/// count, status, and the real exposed tool names as chips. Built-ins show a fixed (disabled) on
/// switch (always-on, gated per call); external servers get a live toggle + remove.
private struct ServerCard: View {
    let server: ConnServer
    let onToggle: (Bool) -> Void
    let onRemove: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: server.icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(Brand.ember500)
                    .frame(width: 30, height: 30).background(Brand.ember500.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name).font(Brand.body(13.5, weight: .semibold)).foregroundStyle(Brand.bone50).lineLimit(1)
                    Text(server.subtitle).font(Brand.mono(9.5)).foregroundStyle(Brand.bone400).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if server.builtin {
                    Toggle("", isOn: .constant(server.connected)).labelsHidden().toggleStyle(.switch).tint(Brand.ember500)
                        .disabled(true).help("Built into the core — always on, gated per call")
                } else {
                    Toggle("", isOn: Binding(get: { server.connected }, set: { onToggle($0) }))
                        .labelsHidden().toggleStyle(.switch).tint(Brand.ember500).help("Enable / disable this server")
                }
            }
            HStack(spacing: 8) {
                protoBadge(server.proto)
                Text("\(server.tools.count) tool\(server.tools.count == 1 ? "" : "s")")
                    .font(Brand.mono(9)).foregroundStyle(Brand.bone400)
                Spacer(minLength: 6)
                statusPill
                if !server.builtin {
                    Button(action: onRemove) {
                        Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(hover ? Brand.bone200 : Brand.bone400)
                    }.buttonStyle(.plain).help("Remove server")
                }
            }
            if !server.tools.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(server.tools, id: \.self) { t in
                        Text(t).font(Brand.mono(9.5)).foregroundStyle(Brand.bone200)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Brand.ink850).clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Brand.line1, lineWidth: 1))
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.cardFill).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .top) { Brand.topSheen.frame(height: 1).clipShape(RoundedRectangle(cornerRadius: 12)) }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(hover ? Brand.line2 : Brand.line1, lineWidth: 1))
        .shadow(color: .black.opacity(hover ? 0.22 : 0), radius: hover ? 12 : 0, x: 0, y: 5)
        .onHover { h in withAnimation(Brand.ease) { hover = h } }
    }

    private var statusPill: some View {
        let c = server.connected ? Brand.success : Brand.bone400
        return HStack(spacing: 4) {
            Text(server.connected ? "CONNECTED" : "OFF").font(Brand.mono(8, weight: .bold)).kerning(0.5).foregroundStyle(c)
            Circle().fill(c).frame(width: 5, height: 5)
        }
    }

    private func protoBadge(_ p: String) -> some View {
        Text(p).font(Brand.mono(8, weight: .bold)).kerning(0.8).foregroundStyle(Brand.bone300)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Brand.ink850).clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Brand.line1, lineWidth: 1))
    }
}

/// Minimal wrapping layout (macOS 14+) — lays children left→right, wrapping to a new line when the
/// row would overflow. Used for the tool chips on a server card.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { x = 0; y += lineH + lineSpacing; lineH = 0 }
            x += s.width + spacing; lineH = max(lineH, s.height)
        }
        return CGSize(width: maxW == .infinity ? x : maxW, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { x = 0; y += lineH + lineSpacing; lineH = 0 }
            v.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(s))
            x += s.width + spacing; lineH = max(lineH, s.height)
        }
    }
}

/// Create/edit a project: name + custom instructions (the per-project system prompt).
private struct ProjectEditorSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.editingProjectID == nil ? "NEW PROJECT" : "EDIT PROJECT")
                .font(Brand.mono(13, weight: .bold)).kerning(2).foregroundStyle(Brand.bone200)
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(Brand.mono(11)).foregroundStyle(Brand.bone300)
                TextField("e.g. Taxes 2026", text: $model.projectDraftName)
                    .textFieldStyle(.plain).font(Brand.mono(14)).foregroundStyle(Brand.bone50)
                    .padding(10).background(Brand.cardFill).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.line1, lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Custom instructions").font(Brand.mono(11)).foregroundStyle(Brand.bone300)
                Text("Steers every chat in this project. Files you add here ground its answers.")
                    .font(Brand.mono(10)).foregroundStyle(Brand.bone400)
                TextEditor(text: $model.projectDraftInstructions)
                    .font(Brand.mono(13)).foregroundStyle(Brand.bone50).scrollContentBackground(.hidden)
                    .frame(minHeight: 100)
                    .padding(8).background(Brand.cardFill).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.line1, lineWidth: 1))
            }
            // Files — works for a brand-new project (staged, copied on Create) and an existing one.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Files").font(Brand.mono(11)).foregroundStyle(Brand.bone300)
                    Spacer()
                    Button("Add file…") {
                        if let id = model.editingProjectID { model.addFilesToProject(id) } else { model.addFilesToDraft() }
                    }.buttonStyle(.plain).font(Brand.mono(11, weight: .bold)).foregroundStyle(Brand.ember500)
                    Button("Add folder…") {
                        if let id = model.editingProjectID { model.addFolderToProject(id) } else { model.addFolderToDraft() }
                    }.buttonStyle(.plain).font(Brand.mono(11)).foregroundStyle(Brand.bone300)
                }
                let files: [URL] = model.editingProjectID.map { model.projectFiles($0) } ?? model.projectDraftFiles
                if files.isEmpty {
                    Text("Optional — GINEXUS can read files you add in this project's chats.")
                        .font(Brand.mono(10)).foregroundStyle(Brand.bone400)
                } else {
                    VStack(spacing: 3) {
                        ForEach(files, id: \.self) { f in
                            HStack(spacing: 8) {
                                Image(systemName: "doc").font(.system(size: 10)).foregroundStyle(Brand.bone300)
                                Text(f.lastPathComponent).font(Brand.mono(11)).foregroundStyle(Brand.bone100).lineLimit(1)
                                Spacer(minLength: 0)
                                Button {
                                    if let id = model.editingProjectID { model.removeProjectFile(id, f) } else { model.removeDraftFile(f) }
                                } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                                    .buttonStyle(.plain).foregroundStyle(Brand.bone400)
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { model.projectSheetOpen = false }
                    .buttonStyle(.plain).font(Brand.mono(12)).foregroundStyle(Brand.bone200)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                Button(action: model.saveProjectSheet) {
                    Text(model.editingProjectID == nil ? "CREATE" : "SAVE")
                        .font(Brand.mono(12, weight: .bold)).kerning(1.4).foregroundStyle(Brand.ink900)
                        .padding(.horizontal, 22).padding(.vertical, 12)
                        .background(Brand.ember500).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(model.projectDraftName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22).frame(width: 460)
        .background(Brand.ink850)
    }
}

/// Projects workspace — create projects (folders), set custom instructions, and add files / local
/// paths that GINEXUS can read in that project's chats. Discoverable from the left rail (folder icon).
private struct ProjectsSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            // Top bar — title, NEW, and a clear close (no more overlap with the ACTIVE badge).
            HStack(spacing: 10) {
                Image(systemName: "folder.fill").font(.system(size: 12)).foregroundStyle(Brand.ember500)
                Text("PROJECTS").font(Brand.mono(12, weight: .bold)).kerning(2).foregroundStyle(Brand.bone100)
                Spacer()
                Button(action: model.openNewProjectSheet) {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                        Text("NEW").font(Brand.mono(10, weight: .bold)).kerning(1)
                    }.foregroundStyle(Brand.ember500)
                }.buttonStyle(.plain).help("New project")
                Button { model.projectsOpen = false } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Brand.bone300)
                }.buttonStyle(.plain).help("Close")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider().overlay(Brand.line1)

            HStack(spacing: 0) {
                // Left: project list
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(model.projects) { p in
                            Button { model.selectedProjectID = p.id } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder.fill").font(.system(size: 11))
                                        .foregroundStyle(p.id == model.activeProjectID ? Brand.ember500 : Brand.bone300)
                                    Text(p.name).font(Brand.mono(12)).foregroundStyle(Brand.bone50).lineLimit(1)
                                    Spacer(minLength: 0)
                                    if p.id == model.activeProjectID {
                                        Circle().fill(Brand.ember500).frame(width: 5, height: 5)
                                    }
                                }
                                .padding(.vertical, 8).padding(.horizontal, 10)
                                .background(p.id == model.selectedProjectID ? Brand.ink600 : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain)
                        }
                        if model.projects.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "folder.badge.plus").font(.system(size: 22)).foregroundStyle(Brand.bone400)
                                Text("No projects yet").font(Brand.mono(11)).foregroundStyle(Brand.bone400)
                            }.frame(maxWidth: .infinity).padding(.top, 28)
                        }
                    }.padding(10)
                }
                .frame(width: 200).background(Brand.ink850)

                Rectangle().fill(Brand.line1).frame(width: 1)

                // Right: detail
                Group {
                    if let pid = model.selectedProjectID, let p = model.projects.first(where: { $0.id == pid }) {
                        ProjectDetail(model: model, project: p).id(p.id)
                    } else {
                        VStack(spacing: 14) {
                            Image(systemName: "folder").font(.system(size: 34)).foregroundStyle(Brand.bone400)
                            Text("Select a project, or create one").font(Brand.mono(13)).foregroundStyle(Brand.bone300)
                            Button { model.openNewProjectSheet() } label: {
                                HStack(spacing: 6) { Image(systemName: "plus"); Text("NEW PROJECT").kerning(1) }
                                    .font(Brand.mono(11, weight: .bold)).foregroundStyle(Brand.ink900)
                                    .padding(.horizontal, 18).padding(.vertical, 10).background(Brand.ember500)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(width: 680, height: 510)
        .background(Brand.ink900)
    }
}

/// One project's editable detail: name, custom instructions, and its files.
private struct ProjectDetail: View {
    @ObservedObject var model: AppModel
    let project: Project
    @State private var name: String
    @State private var instr: String

    init(model: AppModel, project: Project) {
        self.model = model
        self.project = project
        _name = State(initialValue: project.name)
        _instr = State(initialValue: project.instructions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Name + ACTIVE pill (inline — no longer colliding with a close button).
            HStack(spacing: 8) {
                TextField("Project name", text: $name)
                    .textFieldStyle(.plain).font(Brand.display(17, weight: .bold)).foregroundStyle(Brand.bone50)
                    .onSubmit { model.updateProject(project.id, name: name) }
                if model.activeProjectID == project.id {
                    Text("• ACTIVE").font(Brand.mono(9, weight: .bold)).kerning(1).foregroundStyle(Brand.ember500)
                }
            }

            // Primary action: enter the project and start chatting.
            Button { model.openProjectAndChat(project.id) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.text.bubble.right.fill").font(.system(size: 12))
                    Text("OPEN — NEW CHAT IN THIS PROJECT").font(Brand.mono(11, weight: .bold)).kerning(1)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .foregroundStyle(Brand.ink900).background(Brand.ember500).clipShape(RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain)

            // Custom instructions
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("CUSTOM INSTRUCTIONS").font(Brand.mono(9, weight: .bold)).kerning(1.4).foregroundStyle(Brand.bone300)
                    Spacer()
                    Button("SAVE") { model.updateProject(project.id, name: name, instructions: instr) }
                        .buttonStyle(.plain).font(Brand.mono(10, weight: .bold)).foregroundStyle(Brand.ember500).help("Save instructions")
                }
                Text("Every thread in this project follows these.").font(Brand.mono(9)).foregroundStyle(Brand.bone400)
                TextEditor(text: $instr)
                    .font(Brand.body(12)).foregroundStyle(Brand.bone50).scrollContentBackground(.hidden)
                    .frame(height: 80)
                    .padding(8).background(Brand.ink850).clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Brand.line1, lineWidth: 1))
            }

            // Files
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text("FILES").font(Brand.mono(9, weight: .bold)).kerning(1.4).foregroundStyle(Brand.bone300)
                    Spacer()
                    Button("ADD FILE") { model.addFilesToProject(project.id) }
                        .buttonStyle(.plain).font(Brand.mono(10, weight: .bold)).foregroundStyle(Brand.ember500)
                    Button("ADD FOLDER") { model.addFolderToProject(project.id) }
                        .buttonStyle(.plain).font(Brand.mono(10, weight: .bold)).foregroundStyle(Brand.bone300)
                    Button { model.revealProjectFolderFor(project.id) } label: {
                        Image(systemName: "arrow.up.forward.app").font(.system(size: 12)).foregroundStyle(Brand.bone300)
                    }.buttonStyle(.plain).help("Reveal folder in Finder")
                }
                Text("GINEXUS can read these in this project's chats.").font(Brand.mono(9)).foregroundStyle(Brand.bone400)
                ScrollView {
                    VStack(spacing: 4) {
                        let files = model.projectFiles(project.id)
                        if files.isEmpty {
                            VStack(spacing: 7) {
                                Image(systemName: "tray").font(.system(size: 20)).foregroundStyle(Brand.bone400)
                                Text("No files yet — add files or a folder.").font(Brand.mono(10)).foregroundStyle(Brand.bone400)
                            }.frame(maxWidth: .infinity).padding(.vertical, 16)
                        }
                        ForEach(files, id: \.self) { f in
                            HStack(spacing: 8) {
                                Image(systemName: Self.icon(for: f)).font(.system(size: 11)).foregroundStyle(Brand.ember500.opacity(0.85))
                                Text(f.lastPathComponent).font(Brand.mono(11)).foregroundStyle(Brand.bone100).lineLimit(1)
                                Spacer(minLength: 0)
                                Button { model.removeProjectFile(project.id, f) } label: {
                                    Image(systemName: "trash").font(.system(size: 10))
                                }.buttonStyle(.plain).foregroundStyle(Brand.bone400).help("Remove from project")
                            }.padding(.vertical, 7).padding(.horizontal, 9).background(Brand.ink700).clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }.frame(maxHeight: .infinity)
            }

            HStack {
                Spacer()
                Button {
                    model.deleteProject(project.id)
                    model.selectedProjectID = model.projects.first?.id
                } label: {
                    HStack(spacing: 4) { Image(systemName: "trash"); Text("Delete project") }
                        .font(Brand.mono(10)).foregroundStyle(Brand.hi500)
                }.buttonStyle(.plain).help("Delete this project")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private static func icon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "doc", "docx": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return "photo"
        case "csv", "xlsx", "numbers", "tsv": return "tablecells"
        case "md", "markdown", "txt", "rtf": return "doc.plaintext"
        case "mp4", "mov", "m4v": return "film"
        case "zip", "tar", "gz": return "doc.zipper"
        default: return "doc"
        }
    }
}

/// Office-style match highlighting: emphasize each search term in `text`; tint the CURRENT match.
fileprivate func highlightedText(_ text: String, terms: [String], current: Bool) -> Text {
    guard !terms.isEmpty else { return Text(text) }
    var attr = AttributedString(text)
    for term in terms {
        var start = text.startIndex
        while start < text.endIndex,
              let r = text.range(of: term, options: .caseInsensitive, range: start..<text.endIndex) {
            if let ar = Range(r, in: attr) {
                attr[ar].foregroundColor = Brand.ember500
                attr[ar].inlinePresentationIntent = .stronglyEmphasized
                if current { attr[ar].backgroundColor = Brand.ember500.opacity(0.28) }
            }
            start = r.upperBound
        }
    }
    return Text(attr)
}

/// Brand-styled waveform for the live voice button that REACTS to the actual mic level — bars rise
/// with sound and sit nearly flat in silence. A faint organic shimmer (scaled by level) keeps it
/// from looking frozen, but the height is driven by the real RMS, not a canned loop.
private struct VoiceWaveformIcon: View {
    @ObservedObject var controller: VoiceConversationController
    private let bars = 5

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            // Normalize raw mic RMS (~0…0.06 for speech) to 0…1, with a soft knee.
            let level = min(1.0, CGFloat(controller.level) * 22.0)
            HStack(spacing: 2.5) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule()
                        .fill(LinearGradient(colors: [Brand.ember300, Brand.ember600],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 3, height: height(i, t, level))
                }
            }
            .frame(width: 26, height: 24)
            .animation(.easeOut(duration: 0.08), value: level)
            .drawingGroup()
        }
    }

    private func height(_ i: Int, _ t: Double, _ level: CGFloat) -> CGFloat {
        // Per-bar organic shape, but its AMPLITUDE is the live mic level → flat when silent, dancing
        // when you speak. Center bars react a touch more, like a real meter.
        let phase = Double(i) / Double(bars) * .pi * 2
        let shape = 0.45 + 0.55 * (0.5 + 0.5 * sin(t * 9.0 + phase))
        let center = 1.0 - abs(CGFloat(i) - CGFloat(bars - 1) / 2) / CGFloat(bars)  // ~0.6…1.0
        let baseline: CGFloat = 3
        return baseline + level * 17 * CGFloat(shape) * center
    }
}

/// Live voice state above the composer: pulsing dot + state + mic level + last transcript.
private struct VoiceStatusBar: View {
    @ObservedObject var controller: VoiceConversationController

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
                .shadow(color: dotColor.opacity(0.7), radius: controller.state == .listening ? 5 : 0)
            Text(label).font(Brand.mono(11, weight: .bold)).kerning(1.6).foregroundStyle(Brand.bone200)
            level
            if !controller.lastTranscript.isEmpty {
                Text("“\(controller.lastTranscript)”")
                    .font(Brand.mono(11)).foregroundStyle(Brand.bone300).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if let err = controller.errorText {
                Text(err).font(Brand.mono(10)).foregroundStyle(Brand.hi500).lineLimit(1)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Brand.cardFill).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Brand.ember600.opacity(0.4), lineWidth: 1))
    }

    /// A small 5-bar level meter driven by the mic RMS.
    private var level: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Float(i) < controller.level * 40 ? Brand.ember500 : Brand.ink500)
                    .frame(width: 3, height: 4 + CGFloat(i) * 2)
            }
        }
        .frame(height: 14)
        .opacity(controller.state == .listening ? 1 : 0.35)
    }

    private var label: String {
        switch controller.state {
        case .idle: return "VOICE OFF"
        case .listening: return "LISTENING"
        case .transcribing: return "HEARD YOU"
        case .thinking: return "THINKING"
        case .speaking: return "SPEAKING"
        }
    }

    private var dotColor: Color {
        switch controller.state {
        case .listening: return Brand.ember500
        case .speaking: return Brand.ember400
        case .thinking, .transcribing: return Brand.bone300
        case .idle: return Brand.ink500
        }
    }
}

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

/// How full the model's context window is after the last turn, plus a "trimmed" badge when the core's
/// deterministic compactor engaged. Denominator is the local-model window the core compacts against
/// (GINEXUS_CTX_WINDOW default, 32K) — a known config value, not fabricated data.
private struct ContextBudgetGauge: View {
    let usage: TokenUsage?
    let compaction: ContextCompaction?
    private let window = 32_768
    var body: some View {
        let used = usage?.prompt ?? 0
        let frac = min(1.0, Double(used) / Double(window))
        let near = frac > 0.85
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("WINDOW").font(Brand.mono(10, weight: .bold)).foregroundStyle(Brand.bone300)
                Spacer(minLength: 8)
                Text("\(window / 1024)K").font(Brand.mono(10)).foregroundStyle(Brand.bone400)
            }
            // Fullness bar: ember normally, Hinomaru red when the prompt nears the window.
            GeometryReader { geo in
                let w = min(geo.size.width, max(0, geo.size.width * CGFloat(frac)))
                ZStack(alignment: .leading) {
                    Capsule().fill(Brand.ink500.opacity(0.45))
                    Capsule().fill(near ? Brand.hi500 : Brand.ember500).frame(width: w)
                }
            }
            .frame(height: 4)
            .padding(.vertical, 1)
            HStack(spacing: 8) {
                Text("USED").font(Brand.mono(10)).foregroundStyle(Brand.bone300)
                Spacer(minLength: 8)
                Text(usage == nil ? "—" : "\(used) · \(Int(frac * 100))%")
                    .font(Brand.mono(11, weight: .medium))
                    .foregroundStyle(usage == nil ? Brand.bone400 : (near ? Brand.hi500 : Brand.bone100))
            }
            if let c = compaction {
                Divider().overlay(Brand.line1).padding(.vertical, 1)
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "scissors")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(Brand.ember500)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("TRIMMED").font(Brand.mono(10, weight: .bold)).foregroundStyle(Brand.ember500)
                        Text(c.summary).font(Brand.mono(10)).foregroundStyle(Brand.bone300)
                        Text("\(c.beforeTokens) → \(c.afterTokens) tok")
                            .font(Brand.mono(10)).foregroundStyle(Brand.bone400)
                    }
                }
            }
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
    @FocusState private var focused: Bool
    private var isRenaming: Bool { renamingID == c.id }

    var body: some View {
        if isRenaming {
            // Editable row — NOT inside a Button, so the TextField actually receives clicks + focus.
            VStack(alignment: .leading, spacing: 2) {
                TextField("Title", text: $renameText)
                    .textFieldStyle(.plain).font(Brand.mono(13)).foregroundStyle(Brand.bone50).tint(Brand.ember500)
                    .focused($focused)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Brand.ink800).clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Brand.ember500.opacity(0.6), lineWidth: 1))
                    .onSubmit(onCommitRename)
                    .onExitCommand { renamingID = nil }
                Text("Enter to save · Esc to cancel").font(Brand.mono(9)).foregroundStyle(Brand.bone400)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.ink700).clipShape(RoundedRectangle(cornerRadius: 8))
            .onAppear { DispatchQueue.main.async { focused = true } }
        } else {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title).font(Brand.mono(13)).foregroundStyle(selected ? Brand.ember500 : Brand.bone50).lineLimit(1)
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

// MARK: - ⌘K command palette — searchable quick actions, model + mode switches
private struct CommandPalette: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @FocusState private var focused: Bool

    struct Command: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let icon: String
        let run: () -> Void
    }

    private var commands: [Command] {
        var c: [Command] = [
            .init(title: "New conversation", subtitle: "Start a fresh thread", icon: "square.and.pencil") { model.newChat() },
            .init(title: "Projects", subtitle: "Folders, files, custom instructions", icon: "folder") {
                model.selectedProjectID = model.activeProjectID ?? model.projects.first?.id; model.projectsOpen = true
            },
            .init(title: "Memory", subtitle: "What GINEXUS knows about you", icon: "brain") { model.openMemory() },
            .init(title: "Models", subtitle: "Download / manage local models", icon: "cube.box") { model.openModels() },
            .init(title: "Scheduled tasks", subtitle: "Routine automation", icon: "clock.arrow.circlepath") { model.openSchedules() },
            .init(title: "Connections", subtitle: "MCP servers & exposed tools", icon: "point.3.connected.trianglepath.dotted") { model.connectionsOpen = true },
            .init(title: "Settings", subtitle: "Preferences & integrations", icon: "gearshape") { model.openSettings() },
            .init(title: model.deepResearchMode ? "Disarm Deep Research" : "Arm Deep Research",
                  subtitle: "Search the web → cited report", icon: "binoculars.fill") { model.toggleDeepResearch() },
            .init(title: model.autonomous ? "Switch to HITL (approve each action)" : "Switch to Autonomous",
                  subtitle: "Human-in-the-loop vs. unattended execution",
                  icon: model.autonomous ? "hand.raised.fill" : "bolt.fill") { model.autonomous.toggle() },
        ]
        for m in model.models {
            let on = m.id == model.selectedModel
            c.append(.init(title: "Model: \(m.label)", subtitle: on ? "Current model" : "Switch the active model",
                           icon: on ? "checkmark.circle.fill" : "cpu") { model.selectedModel = m.id })
        }
        return c
    }

    private var filtered: [Command] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return commands }
        return commands.filter { $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q) }
    }

    private func run(_ c: Command) { model.paletteOpen = false; c.run() }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { model.paletteOpen = false }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundStyle(Brand.bone400)
                    TextField("Search commands…", text: $query)
                        .textFieldStyle(.plain).font(Brand.body(15)).foregroundStyle(Brand.bone50).focused($focused)
                        .onSubmit { if let first = filtered.first { run(first) } }
                    Text("ESC").font(Brand.mono(9, weight: .bold)).kerning(1).foregroundStyle(Brand.bone400)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Brand.ink850).clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                Divider().overlay(Brand.line1)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if filtered.isEmpty {
                            Text("No matching commands").font(Brand.mono(12)).foregroundStyle(Brand.bone400)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 18)
                        }
                        ForEach(filtered) { c in CommandRow(c: c) { run(c) } }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 360)
            }
            .frame(width: 540)
            .background(Brand.panelFill)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(alignment: .top) { Brand.topSheen.frame(height: 1).clipShape(RoundedRectangle(cornerRadius: 16)) }
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 16)
            .padding(.top, 116)
        }
        .onExitCommand { model.paletteOpen = false }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

private struct CommandRow: View {
    let c: CommandPalette.Command
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: c.icon).font(.system(size: 13, weight: .medium)).foregroundStyle(Brand.ember500).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title).font(Brand.body(13.5, weight: .medium)).foregroundStyle(Brand.bone50).lineLimit(1)
                    Text(c.subtitle).font(Brand.mono(10)).foregroundStyle(Brand.bone400).lineLimit(1)
                }
                Spacer(minLength: 6)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hover ? Brand.ink600 : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { h in hover = h }
    }
}

// MARK: - starter-prompt card (empty-state) — icon tile + title + route, hover-lift
private struct StarterCard: View {
    let icon: String
    let title: String
    let route: String
    let disabled: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.ember500).frame(width: 32, height: 32)
                    .background(Brand.ember500.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Brand.body(14, weight: .medium)).foregroundStyle(Brand.bone50)
                        .lineLimit(1).truncationMode(.tail)
                    Text(route).font(Brand.mono(10.5)).foregroundStyle(Brand.bone400)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.forward").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hover ? Brand.ember500 : Brand.bone400)
            }
            .padding(.horizontal, 15).padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.cardFill).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .top) { Brand.topSheen.frame(height: 1).clipShape(RoundedRectangle(cornerRadius: 12)) }
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(hover ? Brand.ember500.opacity(0.45) : Brand.line1, lineWidth: 1))
            .shadow(color: .black.opacity(hover ? 0.28 : 0), radius: hover ? 12 : 0, x: 0, y: 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.55 : 1)
        .onHover { h in withAnimation(Brand.ease) { hover = h } }
    }
}

// MARK: - Connections model — the core's built-in MCP host surface + user-added external servers.
/// One card in the Connections grid. Built-ins are always-on (gated per call); external servers can
/// be toggled / removed. `tools` are the real exposed tool names (a capability map, not a metric);
/// `connected` reflects real state (built-in flags / a server's enabled bit), never a hardcoded count.
struct ConnServer: Identifiable {
    let id: String
    let icon: String
    let name: String
    let subtitle: String
    let proto: String          // STDIO | HTTP | UDS
    let tools: [String]
    let connected: Bool
    let builtin: Bool
    var external: McpServerConfig? = nil   // set for user-added servers (drives toggle + remove)
}

extension AppModel {
    /// The Connections surface: the core's six built-in servers (state from real flags) followed by
    /// any user-added external MCP servers.
    var connectionServers: [ConnServer] {
        var list: [ConnServer] = [
            ConnServer(id: "fs", icon: "folder", name: "Filesystem",
                       subtitle: "Sandboxed read/write · ~/ confined", proto: "STDIO",
                       tools: ["read_file", "write_file", "search", "move"], connected: true, builtin: true),
            ConnServer(id: "web", icon: "globe", name: "Web & Search",
                       subtitle: "Fetch + search the open web", proto: "HTTP",
                       tools: ["search", "fetch", "extract"], connected: true, builtin: true),
            ConnServer(id: "term", icon: "terminal", name: "Safe Terminal",
                       subtitle: "Allow-listed · gated mutations", proto: "STDIO",
                       tools: ["run", "which", "env"], connected: true, builtin: true),
            ConnServer(id: "mem", icon: "brain.head.profile", name: "Memory",
                       subtitle: "Two-tier · semantic recall", proto: "UDS",
                       tools: ["recall", "remember", "consolidate"], connected: true, builtin: true),
            ConnServer(id: "obsidian", icon: "books.vertical.fill", name: "Obsidian Vault",
                       subtitle: "Read/search · write-gated", proto: "STDIO",
                       tools: ["read_note", "search_vault", "write_note"], connected: obsidianAvailable, builtin: true),
            ConnServer(id: "forge", icon: "sparkles", name: "NexusForge",
                       subtitle: "Image & video generation", proto: "HTTP",
                       tools: ["image", "video"], connected: settings.settings.mediaSidecarEnabled, builtin: true),
        ]
        for s in mcpServers {
            list.append(ConnServer(id: s.id.uuidString, icon: "puzzlepiece.extension.fill", name: s.name,
                                   subtitle: s.command, proto: "STDIO", tools: [],
                                   connected: s.enabled, builtin: false, external: s))
        }
        return list
    }
    /// Servers reporting connected (built-in available + external enabled).
    var connectedServerCount: Int { connectionServers.filter { $0.connected }.count }
    /// Total exposed tools across connected servers — derived from the capability map, not invented.
    var exposedToolCount: Int { connectionServers.filter { $0.connected }.reduce(0) { $0 + $1.tools.count } }
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
