// AppModel.swift (SP2) — boots the REAL hardened spine and polls its /healthz over the UDS
// via the native Swift UDSClient (GinexusCore). The SP1.5 heartbeat stub is gone; this is the
// app actually talking to the MTX-NEXUS backend. EventKit + App Intent proofs remain.
import Foundation
import SwiftUI
import AppKit
import EventKit
import GinexusCore

@MainActor
final class AppModel: ObservableObject {
    @Published var bundleId = Bundle.main.bundleIdentifier ?? "(unbundled)"
    @Published var spineStatus = "booting…"
    @Published var spineDetail = "—"
    @Published var calendarStatus = "not requested"
    @Published var intentStatus = "AskGinexus — registered in bundle"

    private let spine = SpineController()
    private var pollTimer: Timer?
    private var renderedOnce = false

    func start() {
        // Always poll /healthz; spawn a spine ONLY if none is already serving (don't clobber
        // a running sidecar's socket). This also lets the app attach to an operator-launched
        // or LaunchAgent-managed spine — the right model once the spine lives outside ~/Desktop.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { await self?.pollHealth() }
        }
        Task {
            let sock = spine.socketPath
            let pre = await Task.detached { UDSClient.request(socketPath: sock, path: "/healthz") }.value
            if case .success(let r) = pre, r.status == 200 {
                spineStatus = "attaching to running spine…"
            } else if spine.available {
                spine.boot()
                spineStatus = "spawned sidecar; waiting for /healthz…"
            } else {
                spineStatus = "no spine available"
                spineDetail = "boot the spine, or grant Desktop access / embed it in the bundle"
            }
        }
        scheduleRender()
    }

    private func pollHealth() async {
        let sock = spine.socketPath
        // UDSClient.request is blocking → run off the main actor.
        let result = await Task.detached { UDSClient.request(socketPath: sock, path: "/healthz") }.value
        switch result {
        case .success(let r) where r.status == 200:
            spineStatus = "CONNECTED · live spine over UDS"
            if let data = r.body.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let v = obj["version"] as? String ?? "?"
                let s = obj["status"] as? String ?? "?"
                spineDetail = "status=\(s) version=\(v) (HTTP 200 /healthz)"
            } else {
                spineDetail = r.body
            }
            renderSnapshot()  // capture the CONNECTED state
        case .success(let r):
            spineDetail = "HTTP \(r.status)"
        case .failure:
            spineDetail = "waiting for sidecar to serve…"  // socket exists at bind before serving
        }
    }

    func probeCalendar() {
        calendarStatus = "requesting…"
        EKEventStore().requestFullAccessToEvents { [weak self] granted, error in
            Task { @MainActor in
                if let error { self?.calendarStatus = "error: \(error.localizedDescription)" }
                else { self?.calendarStatus = granted
                    ? "GRANTED (attributed to \(self?.bundleId ?? ""))"
                    : "denied (still attributed to app — TCC works)" }
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        spine.shutdown()
    }

    // MARK: - self-render (no Screen-Recording TCC needed)
    private func scheduleRender() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in self?.renderSnapshot() }
    }

    func renderSnapshot() {
        let view = ContentView().environmentObject(self).frame(width: 600, height: 460)
        let renderer = ImageRenderer(content: view)
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
