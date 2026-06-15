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

@MainActor
final class AppModel: ObservableObject {
    @Published var bundleId = Bundle.main.bundleIdentifier ?? "(unbundled)"
    @Published var spineStatus = "booting…"
    @Published var connected = false
    @Published var chat: [ChatMsg] = []
    @Published var chatInput = ""
    @Published var sending = false

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
            renderSnapshot()
            // Auto-demo once: prove the app gets a real model answer through the spine.
            let tok = keychainToken()
            dbg("connected; keychainToken len=\(tok?.count ?? -1)")
            if !autoDemoSent, tok != nil {
                autoDemoSent = true
                dbg("auto-demo: sending")
                send("What is 89 times 7? And in what year did Apollo 11 land on the Moon? One short line.")
            } else {
                dbg("auto-demo SKIPPED (token nil=\(tok == nil), alreadySent=\(autoDemoSent))")
            }
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
        let tok = keychainToken()
        let msgs = chat.map { ["role": $0.role, "content": $0.text] }
        let body = try? JSONSerialization.data(withJSONObject: ["model": "fast", "messages": msgs])
        Task {
            let res = await Task.detached {
                UDSClient.request(socketPath: sock, method: "POST", path: "/v1/chat", token: tok, jsonBody: body)
            }.value
            sending = false
            switch res {
            case .success(let r):
                let ans = Self.parseSSE(r.body)
                dbg("chat HTTP \(r.status); bodyLen=\(r.body.count); ansLen=\(ans.count)")
                chat.append(ChatMsg(role: "assistant", text: ans.isEmpty ? "(no content · HTTP \(r.status))" : ans))
            case .failure(let e):
                dbg("chat failure: \(e)")
                chat.append(ChatMsg(role: "assistant", text: "error: \(e)"))
            }
            renderSnapshot()
        }
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

    /// Read the per-launch bearer token from the Keychain via the signed keychainstore tool.
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
