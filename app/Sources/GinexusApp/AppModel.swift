// AppModel.swift (SP2) — boots/attaches the real hardened spine, polls /healthz over the
// native UDS client, and runs a chat turn end-to-end (app → UDS → gateway → local LLM).
import Foundation
import SwiftUI
import AppKit
import EventKit
import GinexusCore

struct ChatMsg: Identifiable, Sendable {
    let id = UUID()
    let role: String   // "user" | "assistant"
    let text: String
}

/// A selectable model: "auto" (policy-routed) plus each roster tier from GET /v1/models.
struct ModelOption: Identifiable, Sendable, Hashable {
    let id: String      // "auto" | "fast" | "smart" | …  (sent as the request's `model`)
    let label: String
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

    // MARK: chat
    func send(_ prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        chat.append(ChatMsg(role: "user", text: text))
        chatInput = ""
        renderSnapshot()
        let sock = spine.socketPath
        let tok = currentToken()
        let msgs = chat.map { ["role": $0.role, "content": $0.text] }
        let body = try? JSONSerialization.data(withJSONObject: ["model": selectedModel, "messages": msgs])
        Task {
            // Route through the agent loop so tools work (system_status, calendar, recall, web_fetch…).
            let res = await Task.detached {
                UDSClient.request(socketPath: sock, method: "POST", path: "/v1/agent", token: tok, jsonBody: body)
            }.value
            sending = false
            switch res {
            case .success(let r):
                let reply = Self.parseAgent(r.body, status: r.status)
                dbg("agent HTTP \(r.status); reply=\(reply.prefix(100))")
                chat.append(ChatMsg(role: "assistant", text: reply))
            case .failure(let e):
                dbg("agent failure: \(e)")
                chat.append(ChatMsg(role: "assistant", text: "error: \(e)"))
            }
            renderSnapshot()
        }
    }

    /// Parse a /v1/agent JSON reply. Read-only tools resolve to a final answer; irreversible tools
    /// return pending_approval (biometric approval sheet is the SP2 tail).
    static func parseAgent(_ body: String, status: Int) -> String {
        guard let d = body.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return "(no content · HTTP \(status))"
        }
        let st = (o["status"] as? String) ?? "?"
        let answer = (o["answer"] as? String) ?? ""
        if st == "pending_approval" {
            let action = (o["pending"] as? [String: Any])?["action"] as? String ?? "that action"
            return "GINEXUS needs your approval to \(action). Biometric approval is coming (SP2 tail); read-only actions work now."
        }
        return answer.isEmpty ? "(\(st))" : answer
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
