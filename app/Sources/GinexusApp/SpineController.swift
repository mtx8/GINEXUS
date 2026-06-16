// SpineController.swift — launches the EMBEDDED Rust core engine (ginexus-server) from inside
// the app bundle (Contents/MacOS). The app mints the per-launch secrets and injects them via env
// (the server fails closed without them), so the app is self-contained: no external launcher, no
// keychain dependency, and no ~/Desktop access (the binary is in the bundle, so Desktop-TCC is moot).
import Foundation
import Security

@MainActor
final class SpineController {
    private var process: Process?
    let socketPath: String

    /// Per-launch secrets the app minted + injected (also used to authenticate / mint approvals).
    private(set) var token: String?
    private(set) var approvalKey: String?

    /// SP5: the app-hosted OS-tool server (Calendar/Shortcuts/system) the core calls back into.
    private let appHostSocketPath: String
    private var appHost: AppToolHost?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        socketPath = "\(home)/Library/Application Support/GINEXUS/run/ginexus.sock"
        appHostSocketPath = "\(home)/Library/Application Support/GINEXUS/run/ginexus-app.sock"
    }

    /// The embedded Rust core binary inside the app bundle.
    private var embeddedBinary: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ginexus-server")
    }

    var available: Bool { FileManager.default.isExecutableFile(atPath: embeddedBinary.path) }

    var logURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GINEXUS", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("core.log")
    }

    private func randomHex(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func boot() {
        guard available else { return }
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: logURL)

        let tok = randomHex(32)
        let approval = randomHex(32)
        token = tok
        approvalKey = approval

        // SP5: start the app-hosted OS-tool server (TCC-attributed to this signed app) BEFORE the
        // core spawns, and hand the core its socket + a per-launch token so OS tools are registered.
        let appHostToken = randomHex(32)
        let host = AppToolHost(socketPath: appHostSocketPath, token: appHostToken)
        host.start()
        appHost = host

        let p = Process()
        p.executableURL = embeddedBinary
        p.arguments = ["--uds", socketPath]
        var env = ProcessInfo.processInfo.environment
        env["GINEXUS_TOKEN"] = tok
        env["GINEXUS_AUDIT_KEY"] = randomHex(32)
        env["GINEXUS_APPROVAL_KEY"] = approval
        env["GINEXUS_APP_HOST_SOCK"] = appHostSocketPath
        env["GINEXUS_APP_HOST_TOKEN"] = appHostToken
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

    func shutdown() { process?.terminate(); appHost?.stop() }
}
