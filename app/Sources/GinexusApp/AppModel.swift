// AppModel.swift (SP2) — boots/attaches the real hardened spine, polls /healthz over the
// native UDS client, and runs a chat turn end-to-end (app → UDS → gateway → local LLM).
import Foundation
import SwiftUI
import AppKit
import EventKit
import LocalAuthentication
import PDFKit
import ImageIO
import GinexusCore

// ChatMsg now lives in GinexusCore (testable; the persisted unit inside a Conversation).

/// A selectable model: "auto" (policy-routed) plus each roster tier from GET /v1/models.
struct ModelOption: Identifiable, Sendable, Hashable {
    let id: String      // "auto" | "fast" | "smart" | …  (sent as the request's `model`)
    let label: String
}

/// A core-memory block (name → value), e.g. the consolidated "profile".
struct BlockKV: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let value: String
}

/// Real token usage for one agent turn (from the core's SSE done event). Total is server-provided.
struct TokenUsage: Sendable, Equatable {
    let prompt: Int
    let completion: Int
    let total: Int
}

/// One archival memory fact surfaced in the memory browser.
struct MemFact: Identifiable, Sendable {
    let id = UUID()
    let text: String
    let origin: String   // "trusted" | "untrusted"
}

/// A scheduled task (cron job) that runs unattended on a cadence. Mirrors the core's `/v1/schedule`
/// record. `attachments` are the basenames of files the task reads each run.
struct ScheduledTask: Identifiable, Sendable {
    let id: String
    var name: String
    var prompt: String
    var everySecs: Int
    var enabled: Bool
    var attachments: [String]
    var runs: Int
    var lastRunMs: Int64
    var nextRunMs: Int64
    var lastResult: String

    /// Friendly title — the task's name, or the first line of its instructions if unnamed.
    var displayTitle: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { return n }
        let firstLine = prompt.split(separator: "\n").first.map(String.init) ?? prompt
        return firstLine.isEmpty ? "Untitled task" : String(firstLine.prefix(60))
    }

    /// Human cadence label from the interval (e.g. "Every hour", "Daily").
    var cadenceLabel: String { ScheduleCadence.label(forSeconds: everySecs) }

    var lastRunLabel: String {
        guard lastRunMs > 0 else { return "Never run" }
        let d = Date(timeIntervalSince1970: Double(lastRunMs) / 1000)
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return "Ran \(f.localizedString(for: d, relativeTo: Date()))"
    }

    var nextRunLabel: String {
        guard enabled else { return "Paused" }
        let d = Date(timeIntervalSince1970: Double(nextRunMs) / 1000)
        if d <= Date() { return "Due now" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return "Next \(f.localizedString(for: d, relativeTo: Date()))"
    }
}

/// The preset cadences offered in the editor — clean, intuitive choices mapped to the core's
/// interval engine. (The core floors anything below 30s.)
enum ScheduleCadence: Int, CaseIterable, Identifiable {
    case every15min = 900
    case hourly = 3600
    case every6h = 21600
    case daily = 86400
    case weekly = 604800

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .every15min: return "Every 15 minutes"
        case .hourly: return "Every hour"
        case .every6h: return "Every 6 hours"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        }
    }

    /// Shorter label for list rows.
    static func label(forSeconds s: Int) -> String {
        switch s {
        case ..<60: return "Every \(s)s"
        case ..<3600: return "Every \(s / 60) min"
        case 3600: return "Every hour"
        case ..<86400: return "Every \(s / 3600) h"
        case 86400: return "Daily"
        case 604800: return "Weekly"
        default: return "Every \(s / 86400) days"
        }
    }
}

/// A model actually installed in the local runtime (from Ollama /api/tags).
struct InstalledModel: Identifiable, Sendable {
    let id: String      // model name (e.g. "qwen3-vl:30b-a3b-instruct")
    let size: Int       // bytes on disk
    let detail: String  // "8B · Q4_K_M" (params · quant), may be empty
    var name: String { id }
}

/// A Hugging Face model repo surfaced by type-ahead search (GGUF, pullable via Ollama hf.co).
struct HFModel: Identifiable, Sendable {
    let id: String        // "<org>/<repo>"
    let downloads: Int
    let gated: Bool
}

/// A file or image attached to the NEXT message via the "+" menu.
struct Attachment: Identifiable, Sendable {
    let id = UUID()
    let kind: String        // "file" | "image"
    let name: String
    let text: String?       // file content (capped) — kind == "file"
    let imagePath: String?  // local path — kind == "image"
}

/// An irreversible/OS action the agent paused on, awaiting biometric approval before it runs.
struct PendingAction: Identifiable {
    let id = UUID()
    let tool: String
    let args: [String: Any]
    let target: String
    let preview: String
    let messages: [[String: Any]]   // the conversation to re-run once approved (content may be multimodal)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var bundleId = Bundle.main.bundleIdentifier ?? "(unbundled)"
    @Published var spineStatus = "booting…"
    @Published var connected = false
    @Published var chat: [ChatMsg] = []
    @Published var chatInput = ""
    @Published var sending = false

    /// Conversation history (persisted app-side; see ConversationStore). The sidebar lists `conversations`;
    /// `chat` holds the active transcript. activeConversationID + the active createdAt/title are the bits
    /// needed to rebuild a Conversation on save.
    @Published var conversations: [ConversationMeta] = []
    @Published var activeConversationID: UUID?
    @Published var sidebarColumn: NavigationSplitViewVisibility = .all
    private var activeCreatedAt = Date()
    private var activeTitle = "New chat"
    /// SP-Projects: which project the active thread belongs to (nil = loose chat). New chats inherit it.
    @Published var activeProjectID: UUID?
    private let convStore: ConversationStoring = DiskConversationStore()
    let settings = SettingsStore.shared
    /// Conversations shown in the sidebar but not yet written to disk (empty "New chat" tiles). They
    /// appear immediately on ＋ but are excluded from the persisted index until they have content.
    private var unsavedIDs: Set<UUID> = []

    /// Model picker: "auto" + the roster from GET /v1/models. Default "auto" → the 30B for chat/agent.
    @Published var models: [ModelOption] = [ModelOption(id: "auto", label: "Auto (smart by default)")]
    @Published var selectedModel = "auto" {
        didSet { if selectedModel != oldValue { settings.update { $0.defaultModel = selectedModel } } }
    }

    /// Autonomy mode. false = human-in-the-loop (every irreversible action asks for Touch ID).
    /// true = autonomous: irreversible tools run unattended EXCEPT hard-gated ones (money / external
    /// comms / legal / irreversible delete / arbitrary execution), which ALWAYS require approval —
    /// the non-overridable hard gate. Sent to /v1/agent as `mode`.
    @Published var autonomous = false {
        didSet { if autonomous != oldValue { settings.update { $0.defaultMode = autonomous ? "autonomous" : "hitl" } } }
    }
    private var modeString: String { autonomous ? "autonomous" : "hitl" }

    /// Injected for typed chat turns: clean, brand-correct formatting (no emoji).
    static let chatFormatPrompt = """
    Format replies cleanly for a chat interface: clear prose in short paragraphs; use a heading or a \
    list ONLY when it genuinely aids scanning (don't over-structure a simple answer); keep code in \
    fenced code blocks. Never use emoji. Don't restate the user's question before answering.
    """

    /// Injected only for voice turns so GINEXUS speaks like a human in conversation.
    static let voiceSystemPrompt = """
    You are in a live VOICE conversation — your reply will be spoken aloud. Talk like a real person, \
    not like you are reading a document. Be natural, warm, and brief: usually one to three sentences. \
    Do NOT use markdown, headings, bullet points, numbered lists, code blocks, tables, or emoji. Do not \
    restate or repeat the user's question back to them. Just answer conversationally and get to the \
    point. Only give a longer, structured answer if the user explicitly asks for detail or a list.
    """
    /// HITL: when set, an irreversible/OS action is waiting on the biometric approval sheet.
    @Published var pending: PendingAction?

    /// Token usage from the most recent agent turn (nil until one completes with real counts).
    @Published var lastUsage: TokenUsage?

    /// Memory browser ("what GINEXUS knows about you"): core blocks + searchable archival facts.
    @Published var memoryOpen = false
    @Published var memBlocks: [BlockKV] = []
    @Published var memFactsCount = 0
    @Published var memResults: [MemFact] = []
    @Published var memQuery = ""
    @Published var memMatchIndex = 0   // Office-style find: which result is "current"

    /// The active search terms (≥2 chars) used to highlight matches in the memory browser.
    var memTerms: [String] {
        memQuery.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 2 }
    }
    func memNext() { guard !memResults.isEmpty else { return }; memMatchIndex = (memMatchIndex + 1) % memResults.count }
    func memPrev() { guard !memResults.isEmpty else { return }; memMatchIndex = (memMatchIndex - 1 + memResults.count) % memResults.count }
    @Published var memLoading = false

    /// File/image attached to the next message via the "+" menu (nil when none).
    @Published var attachment: Attachment?
    /// A small thumbnail of an attached image, decoded ONCE at pick time (the chip must not re-decode
    /// the full image from disk on every keystroke/streamed token).
    @Published var attachmentThumb: NSImage?

    /// Model manager ("download models from Hugging Face / Ollama"): installed list, version, pull.
    @Published var modelsOpen = false
    @Published var installed: [InstalledModel] = []
    @Published var ollamaVersion = ""
    @Published var pullInput = ""
    @Published var pullStatus = ""
    @Published var pullProgress: Double = 0
    @Published var pulling = false
    /// Live Hugging Face type-ahead results for the pull field.
    @Published var hfResults: [HFModel] = []
    private var hfSearchTask: Task<Void, Never>?
    /// qwen3-vl (vision) needs Ollama ≥ 0.12.7; surface an upgrade prompt when older.
    var ollamaNeedsUpgradeForVision: Bool {
        !ollamaVersion.isEmpty && versionLess(ollamaVersion, "0.12.7")
    }
    /// True when a vision-capable model is actually installed (cross-checked in fetchModels).
    @Published var vlmInstalled = false
    /// Vision is usable only with a new-enough Ollama AND a VLM pulled. Until then, image attachments
    /// degrade to a text note (the model says it can't view images).
    var visionAvailable: Bool { !ollamaNeedsUpgradeForVision && vlmInstalled }
    /// Short, ALL-CAPS guidance shown on an image chip when vision isn't ready.
    var visionStatus: String {
        if ollamaNeedsUpgradeForVision { return "UPDATE OLLAMA 0.12.7+ FOR VISION" }
        if !vlmInstalled { return "PULL A VISION MODEL" }
        return ""
    }
    /// Real: an Obsidian vault is available to the core (explicit setting or auto-detected; never iCloud).
    var obsidianAvailable: Bool { SpineController.resolveVault(settings.settings.obsidianVaultPath) != nil }
    /// The active model's human label for the context rail.
    var activeModelLabel: String { models.first { $0.id == selectedModel }?.label ?? selectedModel }
    /// The core's current boot id (binds approval tokens to this server launch). Fetched on connect.
    private var bootId = ""
    /// During a core restart, the pre-restart boot id; pollHealth must not re-latch CONNECTED until it
    /// sees a DIFFERENT (freshly-booted) id, so we never bind to the dying old core.
    private var restartPreviousBootId: String?

    /// Settings screen (defaults, paths, runtime). Backed by SettingsStore (settings.json).
    @Published var settingsOpen = false

    private let spine = SpineController()

    /// SP-Projects: workspaces (folder + custom instructions + threads). `activeProjectID` selects the
    /// one new chats join and whose instructions are injected.
    @Published var projects: [Project] = []
    private let projectStore: ProjectStoring = DiskProjectStore()
    var activeProject: Project? { projects.first { $0.id == activeProjectID } }

    /// Create a project (with a local folder; iCloud refused) and make it active.
    func createProject(name: String, instructions: String = "") {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var p = Project(name: trimmed, instructions: instructions)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folder = "\(home)/GINEXUS-Projects/\(p.slug)"
        if !SpineController.isICloudPath(folder) {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            p.folderPath = folder
        }
        projects.insert(p, at: 0)
        activeProjectID = p.id
        selectedProjectID = p.id   // so the Projects sheet opens straight into the new project
        projectStore.save(projects)
    }

    /// Enter a project and start chatting in it: make it active, open a fresh thread, close the sheet.
    func openProjectAndChat(_ id: UUID) {
        selectProject(id)
        newChat()
        projectsOpen = false
    }

    /// The sidebar shows the active project's threads when inside one, else the loose (no-project) chats.
    var visibleConversations: [ConversationMeta] {
        if let pid = activeProjectID { return conversations.filter { $0.projectID == pid } }
        return conversations.filter { $0.projectID == nil }
    }

    /// Switch the sidebar scope (nil = regular/non-project chats, else a project). Does NOT create a
    /// chat or change the open conversation — just changes which thread list you're browsing. New
    /// chats started afterward join this scope.
    func setScope(_ id: UUID?) { activeProjectID = id }

    func updateProject(_ id: UUID, name: String? = nil, instructions: String? = nil) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { projects[i].name = name }
        if let instructions { projects[i].instructions = instructions }
        projects[i].updatedAt = Date()
        projectStore.save(projects)
    }

    func deleteProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        if activeProjectID == id { activeProjectID = nil }
        projectStore.save(projects)
    }

    /// Switch the active project; new chats join it. Does not move existing threads.
    func selectProject(_ id: UUID?) { activeProjectID = id }

    // MARK: project files — add files / local paths so GINEXUS's project threads can use them
    @Published var projectsOpen = false
    @Published var selectedProjectID: UUID?   // which project the Projects sheet is viewing

    /// Files currently in a project's folder (the documents GINEXUS can read for that project).
    func projectFiles(_ id: UUID) -> [URL] {
        guard let p = projects.first(where: { $0.id == id }), let path = p.folderPath else { return [] }
        let url = URL(fileURLWithPath: path)
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return items.filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Pick file(s) and COPY them into the project's folder (so they live with the project).
    func addFilesToProject(_ id: UUID) {
        guard let p = projects.first(where: { $0.id == id }), let folder = p.folderPath else { return }
        if SpineController.isICloudPath(folder) { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        for src in panel.urls {
            if SpineController.isICloudPath(src.path) { continue }   // never pull from iCloud
            let dest = URL(fileURLWithPath: folder).appendingPathComponent(src.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: src, to: dest)
        }
        touchProject(id)
    }

    /// Add a whole local folder's files into the project (copies them in). iCloud refused.
    func addFolderToProject(_ id: UUID) {
        guard let p = projects.first(where: { $0.id == id }), let folder = p.folderPath else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let dir = panel.url, !SpineController.isICloudPath(dir.path) else { return }
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for src in items where !src.hasDirectoryPath {
            let dest = URL(fileURLWithPath: folder).appendingPathComponent(src.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: src, to: dest)
        }
        touchProject(id)
    }

    func removeProjectFile(_ id: UUID, _ url: URL) {
        try? FileManager.default.removeItem(at: url)
        touchProject(id)
    }

    func revealProjectFolderFor(_ id: UUID) {
        guard let path = projects.first(where: { $0.id == id })?.folderPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func touchProject(_ id: UUID) {
        if let i = projects.firstIndex(where: { $0.id == id }) { projects[i].updatedAt = Date(); projectStore.save(projects) }
        objectWillChange.send()
    }

    // Project editor sheet (create / edit name + instructions).
    @Published var projectSheetOpen = false
    @Published var projectDraftName = ""
    @Published var projectDraftInstructions = ""
    @Published var projectDraftFiles: [URL] = []   // files staged for a NEW project (copied on create)
    @Published var editingProjectID: UUID?

    func openNewProjectSheet() {
        editingProjectID = nil
        projectDraftName = ""
        projectDraftInstructions = ""
        projectDraftFiles = []
        projectSheetOpen = true
    }

    func openEditProjectSheet(_ id: UUID) {
        guard let p = projects.first(where: { $0.id == id }) else { return }
        editingProjectID = id
        projectDraftName = p.name
        projectDraftInstructions = p.instructions
        projectDraftFiles = []
        projectSheetOpen = true
    }

    /// Stage file(s) for a project being created (copied into its folder once it exists).
    func addFilesToDraft() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseFiles = true; panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for u in panel.urls where !SpineController.isICloudPath(u.path) {
            if !projectDraftFiles.contains(u) { projectDraftFiles.append(u) }
        }
    }

    func addFolderToDraft() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let dir = panel.url, !SpineController.isICloudPath(dir.path) else { return }
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for u in items where !u.hasDirectoryPath && !projectDraftFiles.contains(u) { projectDraftFiles.append(u) }
    }

    func removeDraftFile(_ u: URL) { projectDraftFiles.removeAll { $0 == u } }

    func saveProjectSheet() {
        let name = projectDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { projectSheetOpen = false; return }
        if let id = editingProjectID {
            updateProject(id, name: name, instructions: projectDraftInstructions)
        } else {
            createProject(name: name, instructions: projectDraftInstructions)
            // copy the staged files into the new project's folder
            if let folder = activeProject?.folderPath {
                for src in projectDraftFiles where !SpineController.isICloudPath(src.path) {
                    let dest = URL(fileURLWithPath: folder).appendingPathComponent(src.lastPathComponent)
                    try? FileManager.default.removeItem(at: dest)
                    try? FileManager.default.copyItem(at: src, to: dest)
                }
            }
        }
        projectDraftFiles = []
        projectSheetOpen = false
    }

    /// Open the active project's folder in Finder (where its files live).
    func revealProjectFolder() {
        guard let path = activeProject?.folderPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: SP-Connect — external MCP integrations (Notion, Shopify, …)
    @Published var connectionsOpen = false
    @Published var notionTokenDraft = ""

    var mcpServers: [McpServerConfig] { settings.settings.mcpServers }

    /// Register (or replace) an MCP server; the secret goes to the Keychain, never settings.json.
    /// Takes effect on the next spine restart (servers are spawned at boot).
    func addMcpServer(name: String, command: String, tokenEnv: String?, token: String?) {
        let slug = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty, !command.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var ref: String?
        if let tokenEnv, !tokenEnv.isEmpty, let token, !token.isEmpty {
            let r = "mcp.\(slug).token"
            Keychain.set(token, for: r)
            ref = r
        }
        settings.update { s in
            s.mcpServers.removeAll { $0.name == slug }
            s.mcpServers.append(McpServerConfig(name: slug, command: command, enabled: true,
                                                tokenEnv: tokenEnv, credentialRef: ref))
        }
    }

    func removeMcpServer(_ id: UUID) {
        if let s = mcpServers.first(where: { $0.id == id }), let ref = s.credentialRef { Keychain.delete(ref) }
        settings.update { $0.mcpServers.removeAll { $0.id == id } }
    }

    func setMcpEnabled(_ id: UUID, _ on: Bool) {
        settings.update { s in if let i = s.mcpServers.firstIndex(where: { $0.id == id }) { s.mcpServers[i].enabled = on } }
    }

    /// Preset: Notion's official stdio MCP server with an integration token.
    func connectNotion() {
        let tok = notionTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tok.isEmpty else { return }
        addMcpServer(name: "notion", command: "npx -y @notionhq/notion-mcp-server",
                     tokenEnv: "NOTION_TOKEN", token: tok)
        notionTokenDraft = ""
    }

    @Published var githubTokenDraft = ""
    /// Preset: GitHub's official MCP server with a personal access token.
    func connectGitHub() {
        let tok = githubTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tok.isEmpty else { return }
        addMcpServer(name: "github", command: "npx -y @modelcontextprotocol/server-github",
                     tokenEnv: "GITHUB_PERSONAL_ACCESS_TOKEN", token: tok)
        githubTokenDraft = ""
    }

    // Generic "add any MCP server" form — covers Shopify and anything with a stdio MCP server.
    @Published var mcpCustomName = ""
    @Published var mcpCustomCommand = ""
    @Published var mcpCustomTokenEnv = ""
    @Published var mcpCustomToken = ""
    func addCustomMcp() {
        let name = mcpCustomName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cmd = mcpCustomCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !cmd.isEmpty else { return }
        let env = mcpCustomTokenEnv.trimmingCharacters(in: .whitespacesAndNewlines)
        addMcpServer(name: name, command: cmd, tokenEnv: env.isEmpty ? nil : env,
                     token: mcpCustomToken.isEmpty ? nil : mcpCustomToken)
        mcpCustomName = ""; mcpCustomCommand = ""; mcpCustomTokenEnv = ""; mcpCustomToken = ""
    }

    /// SP-Voice: the hands-free conversation loop. Non-nil while voice mode is active; the overlay
    /// observes it for live state (listening / thinking / speaking) and the mic level.
    @Published var voiceController: VoiceConversationController?
    var voiceActive: Bool { voiceController != nil }

    /// Toggle hands-free voice. Starts mic → STT → agent → TTS with barge-in, or stops it.
    func toggleVoice() {
        if let vc = voiceController {
            vc.stop()
            voiceController = nil
            return
        }
        guard let vc = VoiceConversationController(app: self, audioBase: spine.audioBase) else { return }
        voiceController = vc
        Task { await vc.start() }
    }

    private var pollTimer: Timer?
    private var autoDemoSent = false
    private var didRestoreSession = false   // transcript/settings restore runs once per launch, not per reconnect

    private func dbg(_ s: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GINEXUS", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("app-debug.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data((s + "\n").utf8)); try? h.close() }
        else { try? (s + "\n").data(using: .utf8)?.write(to: url) }
    }

    // MARK: lifecycle
    func start() {
        projects = projectStore.load()   // SP-Projects: restore workspaces
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { await self?.pollHealth() }
        }
        // ATTACH_ONLY never spawns (avoids double-spawn socket churn when a spine is already
        // managed externally / by a LaunchAgent — the production model once the spine lives
        // outside ~/Desktop). Otherwise: spawn only if nothing is already serving.
        let attachOnly = ProcessInfo.processInfo.environment["GINEXUS_ATTACH_ONLY"] != nil
        Task {
            let sock = spine.socketPath
            let pre = await Task.detached { UDSClient.request(socketPath: sock, path: "/healthz") }.value
            if case .success(let r) = pre, r.status == 200 {
                spineStatus = "attaching to running spine…"
            } else if attachOnly {
                spineStatus = "attach-only: waiting for an external spine…"
            } else if spine.available {
                // No live spine answered. A previous run that wasn't cleanly quit leaves a STALE
                // socket file behind (the core unlinks on bind, not on exit), which otherwise breaks
                // the next launch — so remove it before spawning a fresh core that binds cleanly.
                try? FileManager.default.removeItem(atPath: sock)
                spine.boot(); spineStatus = "spawned sidecar; waiting…"
            } else {
                spineStatus = "no spine (boot it / grant Desktop access / embed in bundle)"
            }
        }
    }

    func stop() { pollTimer?.invalidate(); spine.shutdown() }

    // MARK: conversation history (app-side persistence + sidebar)

    /// On first connect: seed picker/mode from saved settings, then load saved conversations and the
    /// most-recent transcript (when persistence is on). Runs BEFORE the auto-demo so a restored chat
    /// suppresses it. When persistence is off, nothing is read and the chat stays in-memory only.
    private func restoreSession() async {
        guard !didRestoreSession else { return }   // once per launch; a core restart must not reset the view
        didRestoreSession = true
        selectedModel = settings.settings.defaultModel
        autonomous = (settings.settings.defaultMode == "autonomous")
        guard settings.settings.persistTranscript else { return }
        let store = convStore
        let index = await Task.detached { store.loadIndex() }.value
        conversations = index.sorted { $0.updatedAt > $1.updatedAt }
        if let recent = conversations.first,
           let conv = await Task.detached(operation: { store.load(id: recent.id) }).value {
            adopt(conv)
        } else {
            newChat()   // fresh active conversation so the first turn persists
        }
    }

    /// Make `conv` the active transcript (no disk read).
    private func adopt(_ conv: Conversation) {
        activeConversationID = conv.id
        activeCreatedAt = conv.createdAt
        activeTitle = conv.title
        activeProjectID = conv.projectID
        chat = conv.messages
        attachment = nil
        pending = nil
        lastUsage = nil   // token gauge reflects the ACTIVE conversation; clear on switch
    }

    /// Start a fresh chat. Blocked mid-stream so the streaming bubble lookup can't be orphaned.
    /// Drops a "New chat" tile into the sidebar IMMEDIATELY (before the first message); the tile is
    /// tracked as unsaved so it isn't written to disk until it has content.
    func newChat() {
        guard !sending else { return }
        // Already on a fresh, empty, unsaved chat → stay put (don't spawn duplicate empty tiles).
        if let id = activeConversationID, chat.isEmpty, unsavedIDs.contains(id) { return }
        let id = UUID()
        activeConversationID = id
        activeCreatedAt = Date()
        activeTitle = "New chat"
        chat = []
        attachment = nil
        attachmentThumb = nil
        pending = nil
        lastUsage = nil   // fresh chat starts with no token usage shown
        chatInput = ""
        unsavedIDs.insert(id)
        conversations.insert(ConversationMeta(id: id, title: "New chat", updatedAt: Date(), messageCount: 0), at: 0)
        renderSnapshot()
    }

    /// Remove the active conversation's sidebar tile if it's an unsaved, empty "New chat" — so
    /// navigating away (or deleting) doesn't leave empty tiles behind.
    private func dropActiveIfEmpty() {
        guard let id = activeConversationID, chat.isEmpty, unsavedIDs.contains(id) else { return }
        unsavedIDs.remove(id)
        conversations.removeAll { $0.id == id }
    }

    /// Switch to a saved conversation. Blocked mid-stream (postAgent finds its bubble by id in `chat`;
    /// swapping `chat` underneath it would drop the streamed reply into the wrong conversation).
    func selectConversation(_ id: UUID) {
        guard !sending, id != activeConversationID else { return }
        dropActiveIfEmpty()   // clean up the empty "New chat" tile we're leaving
        let store = convStore
        Task {
            let conv = await Task.detached(operation: { store.load(id: id) }).value
            // Re-validate after the disk read: if a turn started meanwhile, don't clobber it.
            guard !sending else { return }
            guard let conv else { newChat(); return }   // corrupt/missing → don't strand the UI
            adopt(conv)
            renderSnapshot()
        }
    }

    func renameConversation(_ id: UUID, to newTitle: String) {
        let t = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let i = conversations.firstIndex(where: { $0.id == id }) { conversations[i].title = t }
        if id == activeConversationID {
            // The live in-memory `chat` is authoritative for the active conversation — write it
            // (with the new title) rather than round-tripping a possibly-stale disk copy.
            activeTitle = t
            persistActive()
            return
        }
        // Inactive: load → retitle → save, handing the store the current authoritative index.
        let store = convStore
        let snapshot = conversations
        Task {
            guard var conv = await Task.detached(operation: { store.load(id: id) }).value else { return }
            conv.title = t
            conv.updatedAt = Date()
            let saved = conv
            store.save(saved, index: snapshot)
        }
    }

    func deleteConversation(_ id: UUID) {
        guard !sending else { return }
        unsavedIDs.remove(id)
        conversations.removeAll { $0.id == id }
        convStore.delete(id: id, index: conversations.filter { !unsavedIDs.contains($0.id) })
        guard id == activeConversationID else { return }
        if let next = conversations.first {
            activeConversationID = nil   // clear so selectConversation's guard doesn't no-op
            chat = []                    // don't leave the deleted transcript on screen if load fails
            selectConversation(next.id)
        } else {
            newChat()
        }
    }

    /// Persist the active transcript. No-op when persistence is off or the chat is empty. Called at
    /// the user-append point and again at each turn's finalization (the only "text is final" moments).
    /// The in-memory `conversations` array is the single source of truth for the index: we update it
    /// here on the main actor, then hand the store the full snapshot to write verbatim (no read-modify-
    /// write on disk → no lost updates, and the serial store preserves call order).
    private func persistActive() {
        guard settings.settings.persistTranscript, !chat.isEmpty else { return }
        if activeConversationID == nil {   // ensure an active conversation exists
            activeConversationID = UUID(); activeCreatedAt = Date(); activeTitle = "New chat"
        }
        guard let id = activeConversationID else { return }
        // Fallback title for assistant-initiated chats (import / build-profile) that never went
        // through send()'s auto-title — use the first message so the sidebar isn't all "New chat".
        if activeTitle == "New chat", let first = chat.first?.text {
            let line = first.split(separator: "\n").first.map(String.init) ?? first
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { activeTitle = String(t.prefix(48)) }
        }
        let conv = Conversation(id: id, title: activeTitle, createdAt: activeCreatedAt,
                                updatedAt: Date(), messages: chat, projectID: activeProjectID)
        let meta = conv.meta
        unsavedIDs.remove(id)   // it now has content → a real, persisted conversation
        if let i = conversations.firstIndex(where: { $0.id == id }) { conversations[i] = meta }
        else { conversations.insert(meta, at: 0) }
        conversations.sort { $0.updatedAt > $1.updatedAt }
        // Persist only conversations with real content (empty "New chat" tiles stay session-only).
        convStore.save(conv, index: conversations.filter { !unsavedIDs.contains($0.id) })
    }

    /// Set the conversation title from the first user message (truncated, single line).
    private func autoTitleIfNeeded(_ firstUserText: String) {
        guard activeTitle == "New chat" else { return }
        let line = firstUserText.split(separator: "\n").first.map(String.init) ?? firstUserText
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { activeTitle = String(t.prefix(48)) }
    }

    private func pollHealth() async {
        let sock = spine.socketPath
        let res = await Task.detached { UDSClient.request(socketPath: sock, path: "/healthz") }.value
        guard case .success(let r) = res, r.status == 200 else { return }
        if !connected {
            await fetchBootId()
            // During a restart, only latch onto a core whose boot id is NEW — never the dying old one.
            if let prev = restartPreviousBootId {
                guard !bootId.isEmpty, bootId != prev else { return }
                restartPreviousBootId = nil
            }
            connected = true
            spineStatus = "CONNECTED · live spine over UDS"
            await fetchModels()
            await restoreSession()   // settings defaults + saved conversations (BEFORE the auto-demo)
            refreshSessionStats()    // real memory fact count for the Context rail
            renderSnapshot()
            // Auto-demo once: prove the app gets a real model answer through the spine. Skipped when a
            // transcript was restored (chat non-empty) so a saved conversation isn't polluted.
            let tok = currentToken()
            dbg("connected; keychainToken len=\(tok?.count ?? -1)")
            if !autoDemoSent, tok != nil, chat.isEmpty {
                autoDemoSent = true
                dbg("auto-demo: sending")
                send("Use the system_status tool to report this Mac's macOS version and uptime in one short line.")
            } else {
                dbg("auto-demo SKIPPED (token nil=\(tok == nil), alreadySent=\(autoDemoSent), chatEmpty=\(chat.isEmpty))")
            }
        }
    }

    /// Populate the picker from the core's roster: "auto" first, then each tier (id + label).
    /// Refresh BOTH the top-right picker and the MODELS-manager installed list. The picker shows
    /// "auto" + the curated roster tiers + every installed model (so a freshly-pulled model is
    /// selectable immediately); the manager shows installed models with size/quant for uninstall.
    func fetchModels() async {
        let sock = spine.socketPath, tok = currentToken()
        async let rosterT = Task.detached {
            UDSClient.request(socketPath: sock, method: "GET", path: "/v1/models", token: tok, jsonBody: nil)
        }.value
        async let instT = Task.detached {
            UDSClient.request(socketPath: sock, method: "GET", path: "/v1/models/installed", token: tok, jsonBody: nil)
        }.value
        async let verT = Task.detached {
            UDSClient.request(socketPath: sock, method: "GET", path: "/v1/ollama/version", token: tok, jsonBody: nil)
        }.value
        let (rosterRes, instRes, verRes) = await (rosterT, instT, verT)

        func base(_ s: String) -> String { s.hasSuffix(":latest") ? String(s.dropLast(7)) : s }
        var opts = [ModelOption(id: "auto", label: "Auto (smart by default)")]
        var rosterUnderlying = Set<String>()
        var vlmModel = ""   // the vlm tier's underlying model id, to detect an installed VLM
        if case .success(let r) = rosterRes, let d = r.body.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let arr = o["models"] as? [[String: Any]] {
            for m in arr {
                guard let id = m["id"] as? String else { continue }
                opts.append(ModelOption(id: id, label: (m["label"] as? String) ?? id))
                if let u = m["model"] as? String {
                    rosterUnderlying.insert(base(u))
                    if id == "vlm" { vlmModel = base(u) }
                }
            }
        }
        if case .success(let r) = instRes, let d = r.body.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let arr = o["models"] as? [[String: Any]] {
            var inst: [InstalledModel] = []
            var foundVLM = false
            for m in arr {
                guard let name = m["name"] as? String else { continue }
                let det = m["details"] as? [String: Any]
                let param = (det?["parameter_size"] as? String) ?? ""
                let quant = (det?["quantization_level"] as? String) ?? ""
                inst.append(InstalledModel(id: name, size: (m["size"] as? Int) ?? 0,
                                           detail: [param, quant].filter { !$0.isEmpty }.joined(separator: " · ")))
                // Add raw installed models to the picker unless a roster tier already wraps them.
                if !rosterUnderlying.contains(base(name)) && !opts.contains(where: { $0.id == name }) {
                    opts.append(ModelOption(id: name, label: name))
                }
                if isVisionModel(base(name), vlmBase: vlmModel) { foundVLM = true }
            }
            installed = inst.sorted { $0.name < $1.name }
            vlmInstalled = foundVLM
        }
        if case .success(let r) = verRes, let d = r.body.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            ollamaVersion = (o["version"] as? String) ?? ollamaVersion
        }
        models = opts
        dbg("models: \(opts.map { $0.id }); vlmInstalled=\(vlmInstalled); ollama=\(ollamaVersion)")
    }

    /// Heuristic: is an installed model vision-capable? Primary signal is matching the roster vlm
    /// tier's base; the substring markers catch common VLMs pulled under a different tag form.
    private func isVisionModel(_ name: String, vlmBase: String) -> Bool {
        if !vlmBase.isEmpty && name == vlmBase { return true }
        let n = name.lowercased()
        return n.contains("-vl") || n.contains("vl:") || n.contains("llava") || n.contains("vision")
    }

    /// Import a sanitized personal-data export (ChatGPT/Claude/generic JSON). The app reads the
    /// user-picked file (NSOpenPanel grants access — no extra TCC prompt) and POSTs the bytes to
    /// the core's /v1/ingest, which loads them as quarantined (untrusted) memory.
    func importExport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a SANITIZED chat export (e.g. ChatGPT/Claude conversations.json)"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let sock = spine.socketPath
        let tok = currentToken()
        let body = try? JSONSerialization.data(withJSONObject: [
            "data": String(data: data, encoding: .utf8) ?? "",
            "include_assistant": settings.settings.importIncludeAssistant,
        ])
        chat.append(ChatMsg(role: "user", text: "Import \(url.lastPathComponent) into memory"))
        persistActive()   // save the user turn at append time (matches send())
        renderSnapshot()
        Task {
            let res = await Task.detached {
                UDSClient.request(socketPath: sock, method: "POST", path: "/v1/ingest", token: tok, jsonBody: body)
            }.value
            switch res {
            case .success(let r):
                var msg = "Imported (HTTP \(r.status))."
                if let d = r.body.data(using: .utf8),
                   let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let n = o["facts_loaded"] as? Int {
                    let src = (o["source"] as? String) ?? "export"
                    msg = "Imported \(n) facts from your \(src) export — stored as quarantined memory. Ask me to recall anything from it."
                }
                chat.append(ChatMsg(role: "assistant", text: msg))
            case .failure(let e):
                chat.append(ChatMsg(role: "assistant", text: "import failed: \(e)"))
            }
            persistActive()
            renderSnapshot()
        }
    }

    /// The core's boot id (needed to mint approval tokens bound to this server launch).
    func fetchBootId() async {
        let sock = spine.socketPath, tok = currentToken()
        let res = await Task.detached {
            UDSClient.request(socketPath: sock, method: "GET", path: "/v1/admin/killswitch", token: tok, jsonBody: nil)
        }.value
        if case .success(let r) = res, let d = r.body.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let bid = o["boot_id"] as? String {
            bootId = bid
            dbg("bootId=\(bid)")
        }
    }

    // MARK: chat
    func send(_ prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let att = attachment
        guard (!text.isEmpty || att != nil), !sending else { return }
        sending = true

        // An attachment is shown cleanly in the bubble but its full content (file text, or an
        // image note) is what the model receives for that turn.
        var displayText = text
        var sendText = text
        var userImage: String?
        var imageName: String?
        if let att {
            switch att.kind {
            case "file":
                let body = att.text ?? ""
                sendText = "[Attached file: \(att.name)]\n\(body)\n\n---\n\n"
                    + (text.isEmpty ? "Please review the attached file." : text)
                displayText = (text.isEmpty ? "" : text + "\n\n") + "(attached: \(att.name))"
            case "image":
                userImage = att.imagePath
                imageName = att.name
                sendText = text.isEmpty ? "Take a look at this image." : text
                displayText = text
            default: break
            }
        }

        // Deep Research mode (one-shot): hand the next message to the research team — search the web,
        // cross-check, and return a cited report. Wrap what the MODEL sees; tag the user's bubble.
        if deepResearchMode, !text.isEmpty {
            sendText = "Run a DEEP RESEARCH investigation with the research team: use deep_research to "
                + "search the web for current, reputable sources, cross-check the facts, and produce a "
                + "clear, well-structured report that cites the source URLs.\n\nTopic: " + sendText
            displayText = (displayText.isEmpty ? text : displayText) + "  · deep research"
            deepResearchMode = false
        }

        chat.append(ChatMsg(role: "user", text: displayText, imagePath: userImage))
        chatInput = ""
        attachment = nil
        attachmentThumb = nil
        autoTitleIfNeeded(displayText)
        persistActive()   // never lose a user turn even if streaming is interrupted
        renderSnapshot()
        // Build the outbound messages. Each turn's content is its displayed text, except the LAST
        // user turn carries the full send text — and, when an image is attached AND a vision model is
        // ready, an OpenAI multimodal content array (text + image_url data URL). Otherwise it degrades
        // to a text note so the model can clearly say it can't view images yet.
        var msgs: [[String: Any]] = chat.map { ["role": $0.role, "content": $0.text] }
        if let last = msgs.indices.last {
            if let img = userImage, visionAvailable, let dataURL = imageDataURL(img) {
                msgs[last]["content"] = [
                    ["type": "text", "text": sendText],
                    ["type": "image_url", "image_url": ["url": dataURL]],
                ]
            } else {
                var content = sendText
                if userImage != nil {
                    let named = imageName.map { ": \($0)" } ?? ""
                    content += "\n\n[The user attached an image\(named), but no vision model is active. "
                        + "Briefly say you can't view images yet — they can enable vision from the Models manager.]"
                }
                msgs[last]["content"] = content
            }
        }
        // SP-Voice: when speaking aloud, GINEXUS must TALK like a person, not read a formatted
        // document. Steer to short, natural, spoken replies — no markdown, lists, or restating the
        // question. (This also keeps replies short → snappier voice.)
        if voiceActive {
            msgs.insert(["role": "system", "content": Self.voiceSystemPrompt], at: 0)
        } else {
            msgs.insert(["role": "system", "content": Self.chatFormatPrompt], at: 0)
        }
        // SP-Projects: prepend the active project's custom instructions as a system message so every
        // thread in the project is steered by them (user-authored → trusted).
        if let proj = activeProject {
            var ctx = "Project: \(proj.name)"
            let instr = proj.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            if !instr.isEmpty { ctx += "\nProject instructions:\n\(instr)" }
            let files = projectFiles(proj.id)
            if !files.isEmpty, let folder = proj.folderPath {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let tildeFolder = folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder
                let list = files.map { "- \(tildeFolder)/\($0.lastPathComponent)" }.joined(separator: "\n")
                ctx += "\nThis project has these files. Use the read_document tool with the path to read any you need:\n\(list)"
            }
            if !instr.isEmpty || !files.isEmpty {
                msgs.insert(["role": "system", "content": ctx], at: 0)
            }
        }
        let body = try? JSONSerialization.data(withJSONObject: ["model": selectedModel, "messages": msgs, "mode": modeString])
        Task { await postAgent(body: body, contextMessages: msgs) }
    }

    // MARK: model manager (download from Ollama registry / Hugging Face GGUF)
    func openModels() {
        modelsOpen = true
        Task { await fetchModels() }
        let sock = spine.socketPath, tok = currentToken()
        Task {
            let res = await Task.detached {
                UDSClient.request(socketPath: sock, method: "GET", path: "/v1/ollama/version", token: tok, jsonBody: nil)
            }.value
            if case .success(let r) = res, let d = r.body.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                ollamaVersion = (o["version"] as? String) ?? ""
            }
        }
    }
    /// Refresh button: re-fetch picker + installed list.
    func refreshModels() { Task { await fetchModels() } }

    /// Silently refresh the memory fact count for the Context rail SESSION panel (no sheet opened).
    func refreshSessionStats() {
        let sock = spine.socketPath, tok = currentToken()
        Task {
            let res = await Task.detached {
                UDSClient.request(socketPath: sock, method: "GET", path: "/v1/memory", token: tok, jsonBody: nil)
            }.value
            if case .success(let r) = res, let d = r.body.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                memFactsCount = (o["facts_count"] as? Int) ?? memFactsCount
            }
        }
    }

    // MARK: settings
    func openSettings() { settingsOpen = true }

    /// Apply core-config settings (Ollama endpoint / vault / image generation) by respawning the
    /// embedded core — these are read once in the core's env at boot. Live settings (default model /
    /// mode) need no restart. Approval tokens are bound to the core's boot id, so any in-flight
    /// pending approval is invalidated here (it can't be replayed against the new boot).
    func restartCore() {
        guard !sending else {   // don't tear down the core mid-reply (matches every other mutator)
            spineStatus = "finish or stop the current reply before restarting the core"
            return
        }
        pending = nil            // approval tokens are bootId-bound; invalidate any in-flight grant
        connected = false
        restartPreviousBootId = bootId   // require a DIFFERENT bootId before re-latching CONNECTED
        bootId = ""
        spineStatus = "restarting core…"
        let sock = spine.socketPath
        spine.shutdown()
        // Remove the stale socket so the fresh core binds cleanly (it unlinks on bind, not on exit).
        try? FileManager.default.removeItem(atPath: sock)
        spine.boot()
        // Watchdog: the new core's first token differs from the old, so the dying core rejects it and
        // pollHealth won't latch onto it. If nothing healthy answers in time, surface an actionable error.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self, !self.connected else { return }
            self.spineStatus = "core didn't start — check the Ollama endpoint in Settings, then restart"
        }
        // pollHealth() re-fetches roster + boot id and re-latches CONNECTED once a NEW core answers
        // (didRestoreSession keeps the transcript/view from resetting).
    }

    /// Fully uninstall a model and its artifacts (Ollama DELETE /api/delete), then refresh.
    func deleteModel(_ name: String) {
        let m = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else { return }
        let sock = spine.socketPath, tok = currentToken()
        let body = try? JSONSerialization.data(withJSONObject: ["model": m])
        Task {
            _ = await Task.detached {
                UDSClient.request(socketPath: sock, method: "POST", path: "/v1/models/delete", token: tok, jsonBody: body)
            }.value
            await fetchModels()
        }
    }
    /// Stream a pull (Ollama /api/pull — registry tag OR hf.co/<repo>:<quant>) with live progress.
    func pullModel(_ name: String) {
        let m = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty, !pulling else { return }
        pulling = true; pullProgress = 0; pullStatus = "starting \(m)…"
        let sock = spine.socketPath, tok = currentToken()
        let body = try? JSONSerialization.data(withJSONObject: ["model": m])
        let events = AsyncStream<(String, String)> { cont in
            let task = Task.detached {
                _ = UDSClient.stream(socketPath: sock, path: "/v1/models/pull", token: tok, jsonBody: body) { ev, data in
                    cont.yield((ev, data))
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
        Task {
            for await (ev, data) in events {
                switch ev {
                case "progress":
                    if let d = data.data(using: .utf8),
                       let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        pullStatus = (o["status"] as? String) ?? pullStatus
                        if let total = o["total"] as? Double, let done = o["completed"] as? Double, total > 0 {
                            pullProgress = done / total
                        }
                    }
                case "done":
                    pullStatus = "installed \(m)"; pullProgress = 1
                case "error":
                    pullStatus = "failed: \(data)"
                default: break
                }
            }
            pulling = false
            await fetchModels()   // refresh installed list + add the new model to the picker
        }
    }
    private func versionLess(_ a: String, _ b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    /// Debounced Hugging Face type-ahead for the pull field. Skips when the user has already typed a
    /// concrete ref (registry tag with ':' or an hf.co/ path).
    func scheduleHFSearch() {
        hfSearchTask?.cancel()
        let q = pullInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.count < 2 || q.hasPrefix("hf.co/") || q.contains(":") {
            hfResults = []
            return
        }
        hfSearchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            await self?.searchHF(q)
        }
    }
    private func searchHF(_ q: String) async {
        let sock = spine.socketPath, tok = currentToken()
        let body = try? JSONSerialization.data(withJSONObject: ["query": q])
        let res = await Task.detached {
            UDSClient.request(socketPath: sock, method: "POST", path: "/v1/hf/search", token: tok, jsonBody: body)
        }.value
        if Task.isCancelled { return }
        guard case .success(let r) = res, let d = r.body.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        let arr = (o["results"] as? [[String: Any]]) ?? []
        hfResults = arr.compactMap { m in
            guard let id = m["id"] as? String, !id.isEmpty else { return nil }
            return HFModel(id: id, downloads: (m["downloads"] as? Int) ?? 0, gated: (m["gated"] as? Bool) ?? false)
        }
    }
    /// Pick an HF result → set the pull field to its Ollama hf.co ref (Ollama picks a default quant).
    func pickHF(_ m: HFModel) {
        pullInput = "hf.co/\(m.id)"
        hfResults = []
    }

    // MARK: attachments (via the + menu)
    func clearAttachment() { attachment = nil; attachmentThumb = nil }

    /// Set an image attachment + decode its chip thumbnail once (off the hot render path).
    private func setImageAttachment(name: String, path: String) {
        attachment = Attachment(kind: "image", name: name, text: nil, imagePath: path)
        attachmentThumb = Self.thumbnailImage(path, maxPixel: 48)
    }

    /// A vision-bound thumbnail capped to an exact PIXEL size (deterministic regardless of source DPI
    /// or display backing scale), EXIF-stripped and orientation-corrected. Used for both the vision
    /// payload and the attachment chip so a large image is decoded/downsampled ONCE.
    static func thumbnailImage(_ path: String, maxPixel: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honor EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Encode an attached image as an OpenAI `image_url` data URL for the vision path. Downsamples to
    /// an exact 1536px max edge (via ImageIO — deterministic, no backing-scale surprises) and JPEG-
    /// recompresses; returns nil (→ text-note fallback) on failure or above a hard 12MB ceiling.
    func imageDataURL(_ path: String) -> String? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1536,
              ] as CFDictionary) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return nil }
        guard jpeg.count <= 12 * 1024 * 1024 else { return nil }   // ~16MB base64; never blow the cap
        return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
    }

    /// Attach an image specifically (image-filtered picker). Goes to the vision path when a VLM is
    /// ready; otherwise the model is told it can't view it yet.
    func attachImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = "Attach an image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setImageAttachment(name: url.lastPathComponent, path: url.path)
    }

    /// Smart attach: accept ANY file, detect its type, and extract content the model can work with —
    /// PDFs (PDFKit) and Word/RTF/HTML docs (NSAttributedString) become text; text/code is read as
    /// UTF-8; images go to the vision path; video is noted (needs vision+audio models). No cloud, no
    /// extra models for documents — all extraction is on-device.
    func attachAny() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        panel.message = "Attach a file — PDF, document, spreadsheet, text/code, or image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent

        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tiff", "tif"]
        let videoExts: Set<String> = ["mp4", "mov", "m4v", "webm", "avi", "mkv"]
        let docExts: Set<String> = ["doc", "docx", "rtf", "rtfd", "html", "htm", "odt", "pages"]

        if imageExts.contains(ext) {
            setImageAttachment(name: name, path: url.path)
            return
        }
        if videoExts.contains(ext) {
            attachment = Attachment(kind: "file", name: name,
                text: "(The user attached a video: \(name). Video understanding needs a vision + audio model, which isn't installed yet — say so briefly.)",
                imagePath: nil)
            return
        }

        var text = ""
        if ext == "pdf" {
            text = PDFDocument(url: url)?.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = "(This PDF has no extractable text — it may be scanned images.)"
            }
        } else if docExts.contains(ext) {
            text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string ?? ""
            if text.isEmpty { text = "(Could not extract text from \(name).)" }
        } else if let data = try? Data(contentsOf: url), let s = String(data: data, encoding: .utf8), !s.isEmpty {
            text = s   // txt / md / json / csv / code / etc.
        } else {
            // last resort: macOS rich-text reader handles many formats; else mark unsupported.
            text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
                ?? "(Couldn't read \(name) as text — unsupported binary file.)"
        }
        if text.count > 16000 { text = String(text.prefix(16000)) + "\n…[truncated]" }
        attachment = Attachment(kind: "file", name: name, text: text, imagePath: nil)
    }

    // MARK: capability quick-actions (wrap the current input → invoke a specific capability)
    var canQuickAction: Bool { !chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending }
    private func quick(_ directive: String) {
        let t = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        send("\(directive)\n\n\(t)")
    }
    func runCouncil()  { quick("Convene a council to deliberate on this, then give me the synthesized verdict:") }
    /// Deep Research — route to the GINEXUS research team (Nexus RND/STR) via deep_research: search the
    /// web for current, reputable sources, cross-check, and produce a clear report with cited URLs.
    func runResearch() { quick("Run a DEEP RESEARCH investigation with the research team: use deep_research to search the web for current, reputable sources, cross-check the facts, and produce a clear, well-structured report that cites the source URLs. Topic:") }
    func runImage()    { quick("Generate an image:") }

    /// Build/refresh the durable self-model from long-term memory (POST /v1/consolidate). Appends the
    /// saved profile to the chat and refreshes the memory browser if open.
    func buildProfile() {
        guard !sending else { return }
        sending = true
        chat.append(ChatMsg(role: "assistant", text: "", streaming: true, status: "building your profile from memory…"))
        guard let id = chat.last?.id else { sending = false; return }
        let sock = spine.socketPath, tok = currentToken()
        let body = try? JSONSerialization.data(withJSONObject: ["block": "profile"])
        Task {
            let res = await Task.detached {
                UDSClient.request(socketPath: sock, method: "POST", path: "/v1/consolidate", token: tok, jsonBody: body)
            }.value
            if let i = chat.firstIndex(where: { $0.id == id }) {
                if case .success(let r) = res, let d = r.body.data(using: .utf8),
                   let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    let answer = (o["answer"] as? String) ?? "(no profile)"
                    chat[i].text = "**Profile** (saved to memory):\n\n\(answer)"
                } else {
                    chat[i].text = "Profile build failed."
                }
                chat[i].streaming = false
                chat[i].status = nil
            }
            sending = false
            persistActive()
            renderSnapshot()
            if memoryOpen { openMemory() }
        }
    }

    // MARK: memory browser
    // Editing a core memory block (the custom profile is the main one). User-authored → trusted.
    @Published var editingBlock: String?
    @Published var blockDraft = ""

    func beginEditBlock(_ name: String, value: String) { editingBlock = name; blockDraft = value }
    func cancelEditBlock() { editingBlock = nil; blockDraft = "" }

    /// Start authoring a profile from scratch (when none exists yet).
    func newProfileBlock() {
        editingBlock = "profile"
        blockDraft = memBlocks.first(where: { $0.name == "profile" })?.value ?? ""
    }

    /// Persist the edited core block to the core (and reflect it locally). Always available — the
    /// profile is meant to be hand-editable, not only auto-generated.
    func saveBlock() {
        guard let name = editingBlock else { return }
        let value = blockDraft
        let sock = spine.socketPath, tok = currentToken()
        Task {
            let body = try? JSONSerialization.data(withJSONObject: ["block": name, "value": value])
            _ = await Task.detached {
                UDSClient.request(socketPath: sock, method: "POST", path: "/v1/memory/block", token: tok, jsonBody: body)
            }.value
            if let i = memBlocks.firstIndex(where: { $0.name == name }) {
                if value.isEmpty { memBlocks.remove(at: i) } else { memBlocks[i] = BlockKV(name: name, value: value) }
            } else if !value.isEmpty {
                memBlocks.append(BlockKV(name: name, value: value)); memBlocks.sort { $0.name < $1.name }
            }
            editingBlock = nil; blockDraft = ""
        }
    }

    func openMemory() {
        memoryOpen = true
        memLoading = true
        let sock = spine.socketPath, tok = currentToken()
        Task {
            let res = await Task.detached {
                UDSClient.request(socketPath: sock, method: "GET", path: "/v1/memory", token: tok, jsonBody: nil)
            }.value
            memLoading = false
            guard case .success(let r) = res, let d = r.body.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            memFactsCount = (o["facts_count"] as? Int) ?? 0
            let blocks = (o["blocks"] as? [String: String]) ?? [:]
            memBlocks = blocks.map { BlockKV(name: $0.key, value: $0.value) }.sorted { $0.name < $1.name }
            let recent = (o["recent"] as? [[String: Any]]) ?? []
            memResults = recent.map { MemFact(text: ($0["text"] as? String) ?? "", origin: ($0["origin"] as? String) ?? "") }
        }
    }
    func searchMemory() {
        let q = memQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        memLoading = true
        let sock = spine.socketPath, tok = currentToken()
        let body = try? JSONSerialization.data(withJSONObject: ["query": q])
        Task {
            let res = await Task.detached {
                UDSClient.request(socketPath: sock, method: "POST", path: "/v1/memory/search", token: tok, jsonBody: body)
            }.value
            memLoading = false
            guard case .success(let r) = res, let d = r.body.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            let facts = (o["facts"] as? [[String: Any]]) ?? []
            memResults = facts.map { MemFact(text: ($0["text"] as? String) ?? "", origin: ($0["origin"] as? String) ?? "") }
            memMatchIndex = 0   // Office-style find: reset to the first match
        }
    }

    /// Deep Research mode: when armed, the next message you send is routed to the research team
    /// (web search → cross-check → cited report). One-shot — it disarms after firing.
    @Published var deepResearchMode = false
    func toggleDeepResearch() { deepResearchMode.toggle() }

    // MARK: scheduled tasks (cron jobs) — routine automation that runs unattended on a cadence
    @Published var schedulesOpen = false
    @Published var schedules: [ScheduledTask] = []
    @Published var schedLoading = false

    /// Open the Scheduled Tasks sheet and load the current tasks from the core.
    func openSchedules() {
        schedulesOpen = true
        refreshSchedules()
    }

    func refreshSchedules() {
        schedLoading = true
        let sock = spine.socketPath, tok = currentToken()
        Task {
            let res = await Task.detached {
                UDSClient.request(socketPath: sock, method: "GET", path: "/v1/schedule", token: tok, jsonBody: nil)
            }.value
            schedLoading = false
            guard case .success(let r) = res, let d = r.body.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let arr = o["schedules"] as? [[String: Any]] else { return }
            schedules = arr.map { Self.parseSchedule($0) }
                .sorted { $0.nextRunMs < $1.nextRunMs }
        }
    }

    private static func parseSchedule(_ o: [String: Any]) -> ScheduledTask {
        ScheduledTask(
            id: (o["id"] as? String) ?? "",
            name: (o["name"] as? String) ?? "",
            prompt: (o["prompt"] as? String) ?? "",
            everySecs: (o["every_secs"] as? Int) ?? 3600,
            enabled: (o["enabled"] as? Bool) ?? true,
            attachments: (o["attachments"] as? [String]) ?? [],
            runs: (o["runs"] as? Int) ?? 0,
            lastRunMs: (o["last_run_ms"] as? Int64) ?? Int64((o["last_run_ms"] as? Int) ?? 0),
            nextRunMs: (o["next_run_ms"] as? Int64) ?? Int64((o["next_run_ms"] as? Int) ?? 0),
            lastResult: (o["last_result"] as? String) ?? ""
        )
    }

    /// Create a scheduled task. Files are read on the APP side (the sidecar can't reach TCC-protected
    /// folders) and sent as base64 — the core stores a copy this task owns. iCloud paths are refused.
    func createSchedule(name: String, prompt: String, everySecs: Int, files: [URL]) {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        var attachments: [[String: String]] = []
        for url in files {
            if SpineController.isICloudPath(url.path) { continue } // HARD RULE #1: never touch iCloud
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            attachments.append(["filename": url.lastPathComponent, "content_b64": data.base64EncodedString()])
        }
        let sock = spine.socketPath, tok = currentToken()
        let body = try? JSONSerialization.data(withJSONObject: [
            "name": name, "prompt": p, "every_secs": everySecs, "attachments": attachments,
        ])
        Task {
            _ = await Task.detached {
                UDSClient.request(socketPath: sock, method: "POST", path: "/v1/schedule", token: tok, jsonBody: body)
            }.value
            refreshSchedules()
        }
    }

    /// Pause or resume a task (optimistic local update, then persist to the core).
    func toggleSchedule(_ id: String, enabled: Bool) {
        if let i = schedules.firstIndex(where: { $0.id == id }) { schedules[i].enabled = enabled }
        let sock = spine.socketPath, tok = currentToken()
        let body = try? JSONSerialization.data(withJSONObject: ["id": id, "enabled": enabled])
        Task {
            _ = await Task.detached {
                UDSClient.request(socketPath: sock, method: "POST", path: "/v1/schedule/toggle", token: tok, jsonBody: body)
            }.value
            refreshSchedules()
        }
    }

    func removeSchedule(_ id: String) {
        schedules.removeAll { $0.id == id }
        let sock = spine.socketPath, tok = currentToken()
        let body = try? JSONSerialization.data(withJSONObject: ["id": id])
        Task {
            _ = await Task.detached {
                UDSClient.request(socketPath: sock, method: "POST", path: "/v1/schedule/remove", token: tok, jsonBody: body)
            }.value
            refreshSchedules()
        }
    }

    // The "New task" editor's draft state.
    @Published var scheduleSheetOpen = false
    @Published var schedDraftName = ""
    @Published var schedDraftPrompt = ""
    @Published var schedDraftEverySecs = ScheduleCadence.daily.rawValue
    @Published var schedDraftFiles: [URL] = []

    func openNewScheduleSheet() {
        schedDraftName = ""; schedDraftPrompt = ""
        schedDraftEverySecs = ScheduleCadence.daily.rawValue; schedDraftFiles = []
        scheduleSheetOpen = true
    }

    func addFilesToScheduleDraft() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseFiles = true; panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for u in panel.urls where !SpineController.isICloudPath(u.path) {
            if !schedDraftFiles.contains(u) { schedDraftFiles.append(u) }
        }
    }

    func removeScheduleDraftFile(_ u: URL) { schedDraftFiles.removeAll { $0 == u } }

    func saveScheduleSheet() {
        let p = schedDraftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        createSchedule(name: schedDraftName, prompt: p, everySecs: schedDraftEverySecs, files: schedDraftFiles)
        scheduleSheetOpen = false
    }

    /// Streaming /v1/agent/stream round-trip. A placeholder assistant bubble is appended and grows
    /// token-by-token; tool/council/research activity shows a status line; an irreversible tool with
    /// no grant ends in pending_approval → the biometric sheet (re-run carries the grant). The SSE
    /// reader runs on a detached task and only Sendable values cross the boundary (an AsyncStream
    /// continuation), so tokens apply IN ORDER on the main actor.
    private func postAgent(body: Data?, contextMessages: [[String: Any]]) async {
        let sock = spine.socketPath, tok = currentToken()
        let placeholder = ChatMsg(role: "assistant", text: "", streaming: true)
        let msgId = placeholder.id
        chat.append(placeholder)

        let events = AsyncStream<(String, String)> { continuation in
            let task = Task.detached {
                let res = UDSClient.stream(socketPath: sock, path: "/v1/agent/stream", token: tok, jsonBody: body) { ev, data in
                    continuation.yield((ev, data))
                }
                if case .failure(let e) = res { continuation.yield(("error", "\(e)")) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        for await (event, data) in events {
            handleSSE(event: event, data: data, msgId: msgId, context: contextMessages)
        }
        // Stream closed: make sure the bubble is finalized + input re-enabled.
        var finalText = ""
        if let i = chat.firstIndex(where: { $0.id == msgId }) {
            flushActivity(i)   // finalize any activity whose min-display timer is still pending
            chat[i].streaming = false
            chat[i].status = nil
            finalText = chat[i].text
        }
        sending = false
        persistActive()   // the only safe "message is final" point (text is authoritative now)
        renderSnapshot()
        // SP-Voice: let the conversation loop speak the finished reply (no-op in text mode).
        onTurnComplete?(finalText)
        onAssistantText?(finalText, true)   // final flush for streaming-TTS (speaks the tail)
    }

    /// SP-Voice: fired with the GROWING assistant text on every token (final=false) and once more at
    /// turn end (final=true). The voice controller speaks each sentence as it completes so audio
    /// starts well before the full reply is done. nil in text mode.
    var onAssistantText: ((String, Bool) -> Void)?

    /// SP-Voice: fired with the final assistant text when an agent turn finishes streaming. The voice
    /// controller sets this to drive TTS; nil in normal typed use.
    var onTurnComplete: ((String) -> Void)?

    /// Apply one SSE frame to the streaming assistant bubble (runs on the main actor, in order).
    /// When the current live activity started — drives the live card's minimum visible window.
    private var activityStartedAt = Date()

    /// Finalize any still-running activity into the completed timeline (no double, no loss).
    private func flushActivity(_ i: Int) {
        if let s = chat[i].status {
            chat[i].steps.append(s)
            chat[i].status = nil
        }
    }

    private func handleSSE(event: String, data: String, msgId: UUID, context: [[String: Any]]) {
        guard let i = chat.firstIndex(where: { $0.id == msgId }) else { return }
        switch event {
        case "token":
            // data is a JSON-encoded string (handles newlines/escapes). Don't clear the live
            // activity card here — its minimum-visible timer (below) owns when it completes.
            if let tok = try? JSONDecoder().decode(String.self, from: Data(data.utf8)) {
                chat[i].text += tok
                onAssistantText?(chat[i].text, false)   // stream to voice as it grows
            }
        case "tool":
            if let d = data.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                let name = (o["name"] as? String) ?? "tool"
                switch (o["phase"] as? String) {
                case "intent", "start":
                    // "intent" = the model is ABOUT to call this tool (fires as soon as its name is
                    // known, so the card shows during the slow compose); "start" = now executing.
                    // Same tool → keep the one card (don't double); finalize only a DIFFERENT prior one.
                    if let prev = chat[i].status, prev != name { flushActivity(i) }
                    if chat[i].status != name { activityStartedAt = Date() }
                    chat[i].status = name    // the live card animates this activity ("Running…")
                    chat[i].text = ""        // the final answer streams AFTER the tool; drop any preamble
                case "done":
                    // Document tools finish in ~1ms, so the live card would never be seen. Keep it up
                    // for a minimum window, THEN flip it to "Completed" in place (progressive timeline).
                    let started = activityStartedAt
                    let mid = msgId
                    Task { @MainActor in
                        let remaining = 0.9 - Date().timeIntervalSince(started)
                        if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
                        guard let j = self.chat.firstIndex(where: { $0.id == mid }) else { return }
                        if self.chat[j].status == name {       // not already superseded/flushed
                            self.chat[j].steps.append(name)
                            self.chat[j].status = nil
                        }
                    }
                default:
                    break
                }
            }
        case "done", "message":
            if data == "[DONE]" { return }
            guard let d = data.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            flushActivity(i)   // finalize any still-running activity into the completed timeline
            // Real token usage for this turn (omitted by the core when the model server reported none).
            if let u = o["usage"] as? [String: Any] {
                let p = max(0, (u["prompt_tokens"] as? Int) ?? 0)
                let c = max(0, (u["completion_tokens"] as? Int) ?? 0)
                // Keep header + bar coherent even if a server reports an inconsistent total.
                let t = max((u["total_tokens"] as? Int) ?? 0, p + c)
                if t > 0 { lastUsage = TokenUsage(prompt: p, completion: c, total: t) }
            }
            let st = (o["status"] as? String) ?? "final"
            if st == "pending_approval", let p = o["pending"] as? [String: Any] {
                chat.remove(at: i)   // drop the empty placeholder; the approval sheet drives the re-run
                let tool = (p["tool"] as? String) ?? "?"
                let args = (p["arguments"] as? [String: Any]) ?? [:]
                pending = PendingAction(
                    tool: tool, args: args,
                    target: (p["target"] as? String) ?? Approval.target(forTool: tool, args: args),
                    preview: (p["preview"] as? String) ?? tool, messages: context)
                dbg("pending approval: \(pending?.preview ?? "")")
            } else {
                let answer = (o["answer"] as? String) ?? ""
                let trace = (o["trace"] as? [[Any]]) ?? []
                let didGenerate = trace.contains {
                    ($0.first as? String) == "image_generate" && ($0.count > 1 ? (($0[1] as? Bool) ?? false) : false)
                }
                let didDoc = trace.contains {
                    ($0.first as? String) == "write_document" && ($0.count > 1 ? (($0[1] as? Bool) ?? false) : false)
                }
                var img = Self.extractImagePath(answer)
                if img == nil, didGenerate { img = Self.newestMediaImage() }
                if !answer.isEmpty { chat[i].text = answer }      // authoritative (think-stripped/trimmed)
                chat[i].imagePath = img
                if didDoc { chat[i].docPath = Self.newestDocument() }   // Final Output card
                // Steps are accumulated live (running → completed in place); fall back to the trace
                // only if no per-tool events arrived, so the order/identity stays stable.
                if chat[i].steps.isEmpty { chat[i].steps = trace.compactMap { $0.first as? String } }
                chat[i].streaming = false
                dbg("agent stream done; status=\(st)")
            }
        case "error":
            chat[i].text = "error: \(data)"
            chat[i].streaming = false
        default:
            break
        }
    }

    /// Pull a generated image path (…/GINEXUS/media/*.png) out of the assistant's reply. The media
    /// dir contains a space ("Application Support"), so match the known prefix, not whitespace tokens.
    static func extractImagePath(_ text: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sub = "/Library/Application Support/GINEXUS/media/"
        // Accept either the absolute path or the privacy-friendly ~ form, then resolve ~ back to home.
        for prefix in ["\(home)\(sub)", "~\(sub)"] {
            guard let start = text.range(of: prefix) else { continue }
            let rest = text[start.lowerBound...]
            guard let png = rest.range(of: ".png") else { continue }
            let p = String(rest[..<png.upperBound])
            return p.hasPrefix("~") ? home + p.dropFirst() : p
        }
        return nil
    }

    /// Newest generated document (PDF/Word) — surfaced as a Final Output card after write_document.
    static func newestDocument() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/Library/Application Support/GINEXUS/documents"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        let docs = files.filter { $0.hasSuffix(".pdf") || $0.hasSuffix(".docx") }.map { "\(dir)/\($0)" }
        return docs.max { a, b in
            let da = (try? FileManager.default.attributesOfItem(atPath: a))?[.modificationDate] as? Date
            let db = (try? FileManager.default.attributesOfItem(atPath: b))?[.modificationDate] as? Date
            return (da ?? .distantPast) < (db ?? .distantPast)
        }
    }

    /// Newest PNG in the media dir — fallback when the model didn't echo the exact path.
    static func newestMediaImage() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/Library/Application Support/GINEXUS/media"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        let pngs = files.filter { $0.hasSuffix(".png") }.map { "\(dir)/\($0)" }
        return pngs.max { a, b in
            let da = (try? FileManager.default.attributesOfItem(atPath: a))?[.modificationDate] as? Date
            let db = (try? FileManager.default.attributesOfItem(atPath: b))?[.modificationDate] as? Date
            return (da ?? .distantPast) < (db ?? .distantPast)
        }
    }

    // MARK: HITL — biometric approval
    /// Approve the pending action: Touch ID / password → mint the single-use HMAC token (byte-parity
    /// with the core) → re-run carrying the grant. Read-only actions never reach here.
    func approve() {
        guard let p = pending else { return }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use password"
        var authError: NSError?
        let reason = "Approve: \(p.preview)"
        if ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) {
            ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] ok, _ in
                Task { @MainActor in
                    guard let self else { return }
                    if ok { self.mintAndRun() }
                    else {
                        self.chat.append(ChatMsg(role: "assistant", text: "Approval cancelled."))
                        self.pending = nil; self.persistActive(); self.renderSnapshot()
                    }
                }
            }
        } else {
            // No biometrics/password policy available on this Mac — fail safe: do NOT auto-approve.
            chat.append(ChatMsg(role: "assistant", text: "Cannot authenticate on this Mac — action not run."))
            pending = nil; persistActive(); renderSnapshot()
        }
    }

    private func mintAndRun() {
        guard let p = pending, let key = spine.approvalKey, !bootId.isEmpty else {
            chat.append(ChatMsg(role: "assistant", text: "Cannot mint approval (missing key or boot id)."))
            pending = nil; renderSnapshot(); return
        }
        let nonce = Approval.freshNonce()
        let expiry = Int64(Date().timeIntervalSince1970 * 1000) + Approval.defaultTTLms
        guard let token = Approval.mint(approvalKeyHex: key, action: p.tool, args: p.args,
                                        target: p.target, nonce: nonce, expiryMs: expiry, bootId: bootId) else {
            chat.append(ChatMsg(role: "assistant", text: "Approval mint failed."))
            pending = nil; renderSnapshot(); return
        }
        let grant: [String: Any] = [
            "action": p.tool, "args": p.args, "target": p.target,
            "token": token, "nonce": nonce, "expiry_ms": expiry, "boot_id": bootId,
        ]
        let msgs = p.messages
        // Serialize here (in @MainActor scope) so only Sendable Data crosses the Task boundary.
        let body = try? JSONSerialization.data(withJSONObject: ["model": selectedModel, "messages": msgs, "grants": [grant], "mode": modeString])
        pending = nil
        sending = true
        renderSnapshot()
        Task { await postAgent(body: body, contextMessages: msgs) }
    }

    func deny() {
        if let p = pending { chat.append(ChatMsg(role: "assistant", text: "Denied: \(p.tool).")) }
        pending = nil
        persistActive()
        renderSnapshot()
    }

    /// Concatenate SSE `data:` payloads (preserving token spacing) and drop <think> reasoning.
    static func parseSSE(_ body: String) -> String {
        var out = ""
        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.hasPrefix("data: ") {
                let payload = String(line.dropFirst(6))
                if payload == "[DONE]" || payload.isEmpty { continue }
                out += payload
            }
        }
        if let r = out.range(of: "</think>") { out = String(out[r.upperBound...]) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The bearer token: the app-minted secret (embedded-core spawn mode) if present, else the
    /// Keychain (attach-only / external-core mode).
    func currentToken() -> String? {
        spine.token ?? keychainToken()
    }

    /// Read the per-launch bearer token from the Keychain via the signed keychainstore tool
    /// (attach-only / external-core fallback; the embedded-core path uses the minted token).
    func keychainToken() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let bin = ProcessInfo.processInfo.environment["GINEXUS_KEYCHAINSTORE"]
            ?? "\(home)/Desktop/MTX-NEXUS/swift/GinexusKeychain/.build/release/keychainstore"
        guard FileManager.default.isExecutableFile(atPath: bin) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["read", "ginexus.core.token"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let d = out.fileHandleForReading.readDataToEndOfFile()
        let t = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty == false) ? t : nil
    }

    // MARK: self-render (no Screen-Recording TCC needed)
    func renderSnapshot() {
        let renderer = ImageRenderer(content: SnapshotView(model: self))
        renderer.scale = 2
        guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GINEXUS", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? png.write(to: base.appendingPathComponent("ui-snapshot.png"))
    }
}
