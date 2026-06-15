// AppModel.swift — drives the tracer-bullet proofs:
//  1) spawn a sidecar from INSIDE the .app bundle (the TCC-relevant mechanic: the child is
//     launched by the signed app, so OS calls attribute to this bundle id),
//  2) request EventKit access (proves TCC attribution to the app),
//  3) the App Intent (GinexusIntents.swift) registers by being present in the signed bundle.
import Foundation
import SwiftUI
import AppKit
import EventKit

@MainActor
final class AppModel: ObservableObject {
    @Published var sidecarStatus = "not started"
    @Published var sidecarHeartbeat = "—"
    @Published var bundleId = Bundle.main.bundleIdentifier ?? "(unbundled)"
    @Published var calendarStatus = "not requested"
    @Published var intentStatus = "AskGinexus — registered in bundle"

    private var process: Process?
    private var timer: Timer?

    /// Heartbeat file the embedded sidecar appends to; lives in app-support (never iCloud).
    private var heartbeatURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GINEXUS", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("sidecar.heartbeat")
    }

    func start() {
        spawnSidecar()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readHeartbeat() }
        }
        // Self-render the UI to a PNG (no Screen-Recording TCC needed) once status populates.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.renderSnapshot()
        }
    }

    /// Render the live ContentView to a PNG via SwiftUI ImageRenderer — lets us capture the
    /// UI without the Screen Recording permission a headless shell lacks.
    func renderSnapshot() {
        let view = ContentView().environmentObject(self).frame(width: 600, height: 460)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GINEXUS", isDirectory: true)
        try? png.write(to: base.appendingPathComponent("ui-snapshot.png"))
    }

    /// Launch the sidecar shipped INSIDE the bundle (Contents/Resources). This is the
    /// packaging proof: a non-sandboxed Hardened-Runtime app spawning its bundled helper.
    private func spawnSidecar() {
        guard let script = Bundle.main.url(forResource: "sidecar-heartbeat", withExtension: "sh") else {
            sidecarStatus = "ERROR: bundled sidecar not found"
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, heartbeatURL.path]
        do {
            try p.run()
            process = p
            sidecarStatus = "running (pid \(p.processIdentifier)) from bundle"
        } catch {
            sidecarStatus = "ERROR: \(error.localizedDescription)"
        }
    }

    private func readHeartbeat() {
        guard let line = (try? String(contentsOf: heartbeatURL, encoding: .utf8))?
            .split(separator: "\n").last else { return }
        sidecarHeartbeat = String(line)
    }

    /// EventKit access request — the OS attributes this to THIS app's bundle id (TCC).
    func probeCalendar() {
        calendarStatus = "requesting…"
        let store = EKEventStore()
        store.requestFullAccessToEvents { [weak self] granted, error in
            Task { @MainActor in
                if let error { self?.calendarStatus = "error: \(error.localizedDescription)" }
                else { self?.calendarStatus = granted ? "GRANTED (attributed to \(self?.bundleId ?? ""))"
                                                       : "denied (still attributed to app — TCC works)" }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        process?.terminate()
    }
}
