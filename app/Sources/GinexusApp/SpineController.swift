// SpineController.swift — boots the RUST GINEXUS core engine (ADR 0003) and exposes its UDS
// socket. The Swift UDSClient protocol is unchanged; only the socket + launcher moved from the
// Python reference spine to the Rust core. (Python is retired from the runtime path.)
import Foundation

@MainActor
final class SpineController {
    private var process: Process?
    let spineDir: String   // GINEXUS/core
    let socketPath: String

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        spineDir = ProcessInfo.processInfo.environment["GINEXUS_SPINE_DIR"]
            ?? "\(home)/Desktop/GINEXUS/core"
        socketPath = "\(home)/Library/Application Support/GINEXUS/run/ginexus.sock"
    }

    var available: Bool { FileManager.default.fileExists(atPath: "\(spineDir)/scripts/run_core.sh") }

    /// Rust core stdout/stderr, captured for diagnosis from the app context.
    var logURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GINEXUS", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("core.log")
    }

    func boot() {
        guard available else { return }
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: logURL)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["scripts/run_core.sh"]
        p.currentDirectoryURL = URL(fileURLWithPath: spineDir)
        // GUI apps inherit a minimal PATH; run_core.sh needs cargo/openssl (homebrew / ~/.cargo).
        var env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "/opt/homebrew/bin:\(home)/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        if let logHandle {
            p.standardOutput = logHandle
            p.standardError = logHandle
        }
        do { try p.run() } catch {
            try? "spawn failed: \(error)\n".data(using: .utf8)?.write(to: logURL)
        }
        process = p
    }

    func shutdown() { process?.terminate() }
}
