// AppModel.swift (SP2) — boots/attaches the real hardened spine, polls /healthz over the
// native UDS client, and runs a chat turn end-to-end (app → UDS → gateway → local LLM).
import Foundation
import SwiftUI
import AppKit
import EventKit
import LocalAuthentication
import GinexusCore

struct ChatMsg: Identifiable, Sendable {
    let id = UUID()
    let role: String   // "user" | "assistant"
    let text: String
    var imagePath: String? = nil   // a generated image under the media dir, rendered inline
}

/// A selectable model: "auto" (policy-routed) plus each roster tier from GET /v1/models.
struct ModelOption: Identifiable, Sendable, Hashable {
    let id: String      // "auto" | "fast" | "smart" | …  (sent as the request's `model`)
    let label: String
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
    /// HITL: when set, an irreversible/OS action is waiting on the biometric approval sheet.
    @Published var pending: PendingAction?
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
        guard !text.isEmpty, !sending else { return }
        sending = true
        chat.append(ChatMsg(role: "user", text: text))
        chatInput = ""
        renderSnapshot()
        let msgs = chat.map { ["role": $0.role, "content": $0.text] }
        let body = try? JSONSerialization.data(withJSONObject: ["model": selectedModel, "messages": msgs])
        Task { await postAgent(body: body, contextMessages: msgs) }
    }

    /// One /v1/agent round-trip. Read-only tools → final answer; an irreversible tool with no
    /// matching grant → pending_approval, which raises the biometric sheet. After approval the
    /// SAME messages re-run carrying the grant (temperature 0 reproduces the identical tool call).
    /// `body` is pre-serialized (Sendable) so no `[String: Any]` crosses the Task boundary.
    private func postAgent(body: Data?, contextMessages: [[String: String]]) async {
        let sock = spine.socketPath, tok = currentToken()
        let res = await Task.detached {
            UDSClient.request(socketPath: sock, method: "POST", path: "/v1/agent", token: tok, jsonBody: body)
        }.value
        sending = false
        switch res {
        case .success(let r):
            guard let d = r.body.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                chat.append(ChatMsg(role: "assistant", text: "(no content · HTTP \(r.status))"))
                renderSnapshot(); return
            }
            let st = (o["status"] as? String) ?? "?"
            if st == "pending_approval", let p = o["pending"] as? [String: Any] {
                let tool = (p["tool"] as? String) ?? "?"
                let args = (p["arguments"] as? [String: Any]) ?? [:]
                pending = PendingAction(
                    tool: tool, args: args,
                    target: (p["target"] as? String) ?? Approval.target(forTool: tool, args: args),
                    preview: (p["preview"] as? String) ?? tool,
                    messages: contextMessages)
                dbg("pending approval: \(pending?.preview ?? "")")
            } else {
                let answer = (o["answer"] as? String) ?? ""
                dbg("agent HTTP \(r.status); status=\(st)")
                // SP6: if the agent generated an image, render it inline. Prefer the path echoed in
                // the answer; fall back to the newest media PNG when the trace shows a generation.
                let trace = (o["trace"] as? [[Any]]) ?? []
                let didGenerate = trace.contains {
                    ($0.first as? String) == "image_generate" && ($0.count > 1 ? (($0[1] as? Bool) ?? false) : false)
                }
                var img = Self.extractImagePath(answer)
                if img == nil, didGenerate { img = Self.newestMediaImage() }
                chat.append(ChatMsg(role: "assistant", text: answer.isEmpty ? "(\(st))" : answer, imagePath: img))
            }
        case .failure(let e):
            dbg("agent failure: \(e)")
            chat.append(ChatMsg(role: "assistant", text: "error: \(e)"))
        }
        renderSnapshot()
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
        let body = try? JSONSerialization.data(withJSONObject: ["model": selectedModel, "messages": msgs, "grants": [grant]])
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
