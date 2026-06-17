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

    /// SP6: the local image-generation sidecar (mflux/Z-Image-Turbo). Launched as a sibling of the
    /// core; the core gets its base URL via env and exposes the image_generate tool.
    private let mediaPort = 8765
    private var mediaProcess: Process?

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

        // SP6: best-effort launch the media sidecar (dev: from the project dir via uv). If it's
        // already running (or can't be launched), the core still points at the base URL and the
        // image_generate tool simply errors until a sidecar answers.
        startMediaSidecar()

        let p = Process()
        p.executableURL = embeddedBinary
        p.arguments = ["--uds", socketPath]
        var env = ProcessInfo.processInfo.environment
        env["GINEXUS_TOKEN"] = tok
        env["GINEXUS_AUDIT_KEY"] = randomHex(32)
        env["GINEXUS_APPROVAL_KEY"] = approval
        env["GINEXUS_APP_HOST_SOCK"] = appHostSocketPath
        env["GINEXUS_APP_HOST_TOKEN"] = appHostToken
        env["GINEXUS_MEDIA_BASE"] = "http://127.0.0.1:\(mediaPort)"
        // Obsidian: auto-detect the operator's open vault so the core's vault tools light up with no
        // config. Skipped if the vault lives in iCloud (hard rule: never touch ~/Library/Mobile Documents).
        if let vault = Self.detectObsidianVault() {
            env["GINEXUS_OBSIDIAN_VAULT"] = vault
        }
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

    /// Launch the uv media sidecar from the project dir (dev). Best-effort: needs `uv` + the
    /// sidecar sources; if the port is taken (already running) uvicorn just exits — harmless.
    private func startMediaSidecar() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = ProcessInfo.processInfo.environment["GINEXUS_MEDIA_SIDECAR_DIR"]
            ?? "\(home)/Desktop/GINEXUS/app/media-sidecar"
        let uv = "\(home)/.local/bin/uv"
        guard FileManager.default.fileExists(atPath: "\(dir)/server.py"),
              FileManager.default.isExecutableFile(atPath: uv) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: uv)
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.arguments = ["run", "uvicorn", "server:app", "--host", "127.0.0.1", "--port", "\(mediaPort)"]
        var env = ProcessInfo.processInfo.environment
        env["GINEXUS_MEDIA_PRELOAD"] = "1"
        p.environment = env
        let mediaLog = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GINEXUS/media.log")
        FileManager.default.createFile(atPath: mediaLog.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: mediaLog) { p.standardOutput = h; p.standardError = h }
        do { try p.run(); mediaProcess = p } catch { /* sidecar optional */ }
    }

    func shutdown() { process?.terminate(); appHost?.stop(); mediaProcess?.terminate() }

    /// Best-effort discovery of the operator's Obsidian vault from Obsidian's own registry
    /// (~/Library/Application Support/obsidian/obsidian.json). Prefers the currently-open vault, else
    /// the most-recently-used. Returns nil if none, the dir is missing, or it lives in iCloud
    /// (~/Library/Mobile Documents) — which GINEXUS must never touch (global hard rule).
    static func detectObsidianVault() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cfg = "\(home)/Library/Application Support/obsidian/obsidian.json"
        guard let data = FileManager.default.contents(atPath: cfg),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = root["vaults"] as? [String: [String: Any]] else { return nil }
        // Sort candidates: open vault first, then by recency (ts).
        let sorted = vaults.values.sorted { a, b in
            let ao = (a["open"] as? Bool) ?? false, bo = (b["open"] as? Bool) ?? false
            if ao != bo { return ao }
            return ((a["ts"] as? Double) ?? 0) > ((b["ts"] as? Double) ?? 0)
        }
        for v in sorted {
            guard let path = v["path"] as? String else { continue }
            if path.contains("Mobile Documents") || path.contains("com~apple~CloudDocs") { continue } // iCloud → skip
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return path
            }
        }
        return nil
    }
}
