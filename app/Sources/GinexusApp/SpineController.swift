// SpineController.swift (SP2) — boots the REAL MTX-NEXUS hardened sidecar and exposes its
// UDS socket path. Replaces the SP1.5 heartbeat stub. The sidecar is the sibling spine repo
// (GINEXUS depends on MTX-NEXUS, ADR/topology); SP2+ embeds a signed copy in the bundle.
import Foundation

@MainActor
final class SpineController {
    private var process: Process?
    let spineDir: String
    let socketPath: String

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        spineDir = ProcessInfo.processInfo.environment["GINEXUS_SPINE_DIR"]
            ?? "\(home)/Desktop/MTX-NEXUS/backend"
        socketPath = "\(home)/Library/Application Support/NEXUSBrainstem/run/brainstem.sock"
    }

    var available: Bool { FileManager.default.fileExists(atPath: "\(spineDir)/scripts/run_sandboxed.sh") }

    /// Where the sidecar's stdout/stderr is captured (for diagnosis from the app context).
    var logURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GINEXUS", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("spine.log")
    }

    func boot() {
        // Always create the log and record what the app can actually see (TCC diagnosis).
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let script = "\(spineDir)/scripts/run_sandboxed.sh"
        var diag = "spineDir=\(spineDir)\n"
        diag += "fileExists(script)=\(FileManager.default.fileExists(atPath: script))\n"
        diag += "isReadable(script)=\(FileManager.default.isReadableFile(atPath: script))\n"
        let contents = try? String(contentsOfFile: script, encoding: .utf8)
        diag += "canReadScriptContents=\(contents != nil) (len=\(contents?.count ?? -1))\n"
        do {
            let items = try FileManager.default.contentsOfDirectory(atPath: spineDir)
            diag += "listDir OK: \(items.prefix(6).joined(separator: ","))\n"
        } catch {
            diag += "listDir FAILED: \(error)\n"  // TCC denial surfaces here
        }
        try? diag.data(using: .utf8)?.write(to: logURL)

        guard available else { return }
        let logHandle = try? FileHandle(forWritingTo: logURL)
        logHandle?.seekToEndOfFile()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["scripts/run_sandboxed.sh"]
        p.currentDirectoryURL = URL(fileURLWithPath: spineDir)
        // GUI apps inherit a minimal PATH; the launcher needs uv (homebrew / ~/.local).
        var env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "/opt/homebrew/bin:\(home)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
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
