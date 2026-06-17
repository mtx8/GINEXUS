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

/// One archival memory fact surfaced in the memory browser.
struct MemFact: Identifiable, Sendable {
    let id = UUID()
    let text: String
    let origin: String   // "trusted" | "untrusted"
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
    /// HITL: when set, an irreversible/OS action is waiting on the biometric approval sheet.
    @Published var pending: PendingAction?

    /// Memory browser ("what GINEXUS knows about you"): core blocks + searchable archival facts.
    @Published var memoryOpen = false
    @Published var memBlocks: [BlockKV] = []
    @Published var memFactsCount = 0
    @Published var memResults: [MemFact] = []
    @Published var memQuery = ""
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
        chat = conv.messages
        attachment = nil
        pending = nil
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
                                updatedAt: Date(), messages: chat)
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
    func runResearch() { quick("Do deep research on this and produce a clear, cited report:") }
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
        }
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
        if let i = chat.firstIndex(where: { $0.id == msgId }) {
            chat[i].streaming = false
            chat[i].status = nil
        }
        sending = false
        persistActive()   // the only safe "message is final" point (text is authoritative now)
        renderSnapshot()
    }

    /// Apply one SSE frame to the streaming assistant bubble (runs on the main actor, in order).
    private func handleSSE(event: String, data: String, msgId: UUID, context: [[String: Any]]) {
        guard let i = chat.firstIndex(where: { $0.id == msgId }) else { return }
        switch event {
        case "token":
            // data is a JSON-encoded string (handles newlines/escapes).
            if let tok = try? JSONDecoder().decode(String.self, from: Data(data.utf8)) {
                if chat[i].status != nil { chat[i].status = nil }
                chat[i].text += tok
            }
        case "tool":
            if let d = data.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                let name = (o["name"] as? String) ?? "tool"
                if (o["phase"] as? String) == "start" {
                    chat[i].status = name   // the live "Action · <tool>" card shows "Running…"
                    chat[i].text = ""        // the final answer streams AFTER the tool; drop any preamble
                }
            }
        case "done", "message":
            if data == "[DONE]" { return }
            guard let d = data.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            chat[i].status = nil
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
                var img = Self.extractImagePath(answer)
                if img == nil, didGenerate { img = Self.newestMediaImage() }
                if !answer.isEmpty { chat[i].text = answer }      // authoritative (think-stripped/trimmed)
                chat[i].imagePath = img
                chat[i].steps = trace.compactMap { $0.first as? String }   // agent-flow Action cards
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
        let prefix = "\(home)/Library/Application Support/GINEXUS/media/"
        guard let start = text.range(of: prefix) else { return nil }
        let rest = text[start.lowerBound...]
        guard let png = rest.range(of: ".png") else { return nil }
        return String(rest[..<png.upperBound])
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
