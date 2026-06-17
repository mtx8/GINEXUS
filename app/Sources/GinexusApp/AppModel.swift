// AppModel.swift (SP2) — boots/attaches the real hardened spine, polls /healthz over the
// native UDS client, and runs a chat turn end-to-end (app → UDS → gateway → local LLM).
import Foundation
import SwiftUI
import AppKit
import EventKit
import LocalAuthentication
import PDFKit
import GinexusCore

struct ChatMsg: Identifiable, Sendable {
    let id = UUID()
    let role: String   // "user" | "assistant"
    var text: String                 // mutable: assistant text grows as tokens stream in
    var imagePath: String? = nil      // a generated image under the media dir, rendered inline
    var streaming: Bool = false       // true while tokens are still arriving (render plain + cursor)
    var status: String? = nil         // transient activity line (e.g., "deep_research · running…")
}

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
    let messages: [[String: String]]   // the conversation to re-run once approved
}

@MainActor
final class AppModel: ObservableObject {
    @Published var bundleId = Bundle.main.bundleIdentifier ?? "(unbundled)"
    @Published var spineStatus = "booting…"
    @Published var connected = false
    @Published var chat: [ChatMsg] = []
    @Published var chatInput = ""
    @Published var sending = false
    /// Model picker: "auto" + the roster from GET /v1/models. Default "auto" → the 30B for chat/agent.
    @Published var models: [ModelOption] = [ModelOption(id: "auto", label: "Auto (smart by default)")]
    @Published var selectedModel = "auto"

    /// Autonomy mode. false = human-in-the-loop (every irreversible action asks for Touch ID).
    /// true = autonomous: irreversible tools run unattended EXCEPT hard-gated ones (money / external
    /// comms / legal / irreversible delete / arbitrary execution), which ALWAYS require approval —
    /// the non-overridable hard gate. Sent to /v1/agent as `mode`.
    @Published var autonomous = false
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
    /// The core's current boot id (binds approval tokens to this server launch). Fetched on connect.
    private var bootId = ""

    private let spine = SpineController()
    private var pollTimer: Timer?
    private var autoDemoSent = false

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

    private func pollHealth() async {
        let sock = spine.socketPath
        let res = await Task.detached { UDSClient.request(socketPath: sock, path: "/healthz") }.value
        guard case .success(let r) = res, r.status == 200 else { return }
        if !connected {
            connected = true
            spineStatus = "CONNECTED · live spine over UDS"
            await fetchModels()
            await fetchBootId()
            renderSnapshot()
            // Auto-demo once: prove the app gets a real model answer through the spine.
            let tok = currentToken()
            dbg("connected; keychainToken len=\(tok?.count ?? -1)")
            if !autoDemoSent, tok != nil {
                autoDemoSent = true
                dbg("auto-demo: sending")
                send("Use the system_status tool to report this Mac's macOS version and uptime in one short line.")
            } else {
                dbg("auto-demo SKIPPED (token nil=\(tok == nil), alreadySent=\(autoDemoSent))")
            }
        }
    }

    /// Populate the picker from the core's roster: "auto" first, then each tier (id + label).
    func fetchModels() async {
        let sock = spine.socketPath
        let tok = currentToken()
        let res = await Task.detached {
            UDSClient.request(socketPath: sock, method: "GET", path: "/v1/models", token: tok, jsonBody: nil)
        }.value
        guard case .success(let r) = res, r.status == 200,
              let data = r.body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["models"] as? [[String: Any]] else { return }
        var opts = [ModelOption(id: "auto", label: "Auto (smart by default)")]
        for m in arr {
            if let id = m["id"] as? String {
                opts.append(ModelOption(id: id, label: (m["label"] as? String) ?? id))
            }
        }
        models = opts
        dbg("models: \(opts.map { $0.id })")
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
            "include_assistant": false,
        ])
        chat.append(ChatMsg(role: "user", text: "Import \(url.lastPathComponent) into memory"))
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
        if let att {
            switch att.kind {
            case "file":
                let body = att.text ?? ""
                sendText = "[Attached file: \(att.name)]\n\(body)\n\n---\n\n"
                    + (text.isEmpty ? "Please review the attached file." : text)
                displayText = (text.isEmpty ? "" : text + "\n\n") + "(attached: \(att.name))"
            case "image":
                userImage = att.imagePath
                sendText = (text.isEmpty ? "Take a look at this image." : text)
                    + "\n\n[The user attached an image: \(att.name). If you don't have a vision model active, briefly say you can't view images yet.]"
                displayText = text
            default: break
            }
        }

        chat.append(ChatMsg(role: "user", text: displayText, imagePath: userImage))
        chatInput = ""
        attachment = nil
        renderSnapshot()
        // Send the full content for the LAST user turn; earlier turns keep their displayed text.
        var msgs = chat.map { ["role": $0.role, "content": $0.text] }
        if let last = msgs.indices.last { msgs[last]["content"] = sendText }
        let body = try? JSONSerialization.data(withJSONObject: ["model": selectedModel, "messages": msgs, "mode": modeString])
        Task { await postAgent(body: body, contextMessages: msgs) }
    }

    // MARK: attachments (via the + menu)
    func clearAttachment() { attachment = nil }

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
            attachment = Attachment(kind: "image", name: name, text: nil, imagePath: url.path)
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
    private func postAgent(body: Data?, contextMessages: [[String: String]]) async {
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
        renderSnapshot()
    }

    /// Apply one SSE frame to the streaming assistant bubble (runs on the main actor, in order).
    private func handleSSE(event: String, data: String, msgId: UUID, context: [[String: String]]) {
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
                    chat[i].status = "\(name) · running…"
                    chat[i].text = ""   // the final answer streams AFTER the tool; drop any preamble
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
                        self.pending = nil; self.renderSnapshot()
                    }
                }
            }
        } else {
            // No biometrics/password policy available on this Mac — fail safe: do NOT auto-approve.
            chat.append(ChatMsg(role: "assistant", text: "Cannot authenticate on this Mac — action not run."))
            pending = nil; renderSnapshot()
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
