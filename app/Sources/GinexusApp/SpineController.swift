// SpineController.swift — launches the EMBEDDED Rust core engine (ginexus-server) from inside
// the app bundle (Contents/MacOS). The app mints the per-launch secrets and injects them via env
// (the server fails closed without them), so the app is self-contained: no external launcher, no
// keychain dependency, and no ~/Desktop access (the binary is in the bundle, so Desktop-TCC is moot).
import Foundation
import Security
import GinexusCore

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

    /// SP-Voice: the local audio sidecar (Chatterbox TTS + Parakeet STT on Apple MLX). Launched as a
    /// sibling of the core; the core gets its base URL via env (the `speak` tool) and the Swift voice
    /// loop calls it directly over loopback for low-latency synth/transcribe.
    let audioPort = 8764
    private var audioProcess: Process?
    var audioBase: String { "http://127.0.0.1:\(audioPort)" }

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

        // Settings own core-config defaults; read the file directly (no View needed at boot time).
        let settings = SettingsFile.load()

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

        // SP6: best-effort launch the media sidecar (dev: from the project dir via uv). Gated by the
        // "Local image generation" setting; if it's already running (or can't be launched), the core
        // still points at the base URL and the image_generate tool simply errors until one answers.
        if settings.mediaSidecarEnabled { startMediaSidecar() }

        // SP-Voice: best-effort launch the audio sidecar (Chatterbox TTS + Parakeet STT). Gated by the
        // "Voice" setting; preloads both models so the first turn is warm.
        if settings.voiceEnabled { startAudioSidecar() }

        let p = Process()
        p.executableURL = embeddedBinary
        p.arguments = ["--uds", socketPath]
        var env = ProcessInfo.processInfo.environment
        env["GINEXUS_TOKEN"] = tok
        env["GINEXUS_AUDIT_KEY"] = randomHex(32)
        env["GINEXUS_APPROVAL_KEY"] = approval
        env["GINEXUS_APP_HOST_SOCK"] = appHostSocketPath
        env["GINEXUS_APP_HOST_TOKEN"] = appHostToken
        // Image generation: only advertise the media base (which registers the tool) when enabled.
        if settings.mediaSidecarEnabled {
            env["GINEXUS_MEDIA_BASE"] = "http://127.0.0.1:\(mediaPort)"
        } else {
            env.removeValue(forKey: "GINEXUS_MEDIA_BASE")
        }
        // Voice: advertise the audio base (registers the `speak` tool) only when voice is enabled.
        if settings.voiceEnabled {
            env["GINEXUS_AUDIO_BASE"] = audioBase
        } else {
            env.removeValue(forKey: "GINEXUS_AUDIO_BASE")
        }
        // Ollama endpoint override: only inject when the user set a non-default, valid, host-allowed
        // base (every tier + model management derive from it). Loopback default OR a blocked host
        // (metadata/link-local/wildcard) → leave unset so the core uses the safe loopback default.
        if settings.ollamaBase != GinexusSettings.defaultOllamaBase,
           settings.ollamaBaseIsValid, settings.ollamaBaseHostAllowed {
            env["GINEXUS_OLLAMA_BASE"] = settings.ollamaBase
        }
        // Obsidian: explicit setting wins (rejecting iCloud); else auto-detect the open vault. Skipped
        // entirely if it lands in iCloud (hard rule: never touch ~/Library/Mobile Documents).
        if let vault = Self.resolveVault(settings.obsidianVaultPath) {
            env["GINEXUS_OBSIDIAN_VAULT"] = vault
        }
        // SP-Connect: configure enabled external MCP servers + inject their secrets from the Keychain
        // into the core's env (the spawned MCP children inherit it). Secrets never land in settings.json.
        let enabledMCP = settings.mcpServers.filter { $0.enabled }
        if !enabledMCP.isEmpty {
            let arr = enabledMCP.map { ["name": $0.name, "command": $0.command] }
            if let data = try? JSONSerialization.data(withJSONObject: arr),
               let json = String(data: data, encoding: .utf8) {
                env["GINEXUS_MCP_SERVERS"] = json
            }
            for s in enabledMCP {
                if let te = s.tokenEnv, !te.isEmpty, let ref = s.credentialRef, let secret = Keychain.get(ref) {
                    env[te] = secret
                }
            }
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

    /// Launch a Python sidecar (media or audio) from its project dir. ROBUST under a Finder/`open`
    /// launch: it runs the project's OWN venv interpreter (`.venv/bin/python -m uvicorn`) so it does
    /// NOT depend on `uv` resolving a Python in the minimal GUI environment — that resolution hangs
    /// when launched from Finder (no shell PATH), which silently leaves the sidecar down. Falls back
    /// to `uv run` only if the venv is missing. Best-effort; if the port is taken uvicorn just exits.
    private func launchSidecar(dir: String, port: Int, preloadKey: String, logName: String) -> Process? {
        guard FileManager.default.fileExists(atPath: "\(dir)/server.py") else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let venvPython = "\(dir)/.venv/bin/python"
        let uv = "\(home)/.local/bin/uv"
        let p = Process()
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        let venvOK = FileManager.default.isExecutableFile(atPath: venvPython)
        let uvOK = FileManager.default.isExecutableFile(atPath: uv)
        VoiceLog.log("launchSidecar \(logName): dir=\(dir) venvPython=\(venvOK) uv=\(uvOK)")
        if venvOK {
            p.executableURL = URL(fileURLWithPath: venvPython)
            p.arguments = ["-m", "uvicorn", "server:app", "--host", "127.0.0.1", "--port", "\(port)"]
        } else if uvOK {
            p.executableURL = URL(fileURLWithPath: uv)
            p.arguments = ["run", "uvicorn", "server:app", "--host", "127.0.0.1", "--port", "\(port)"]
        } else {
            VoiceLog.log("launchSidecar \(logName): no launcher found")
            return nil
        }
        var env = ProcessInfo.processInfo.environment
        env[preloadKey] = "1"
        // Finder/`open` launches inherit a minimal PATH; give subprocesses the usual locations.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(home)/.local/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let log = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GINEXUS/\(logName)")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: log) { p.standardOutput = h; p.standardError = h }
        do {
            try p.run()
            VoiceLog.log("launchSidecar \(logName): launched pid=\(p.processIdentifier)")
            return p
        } catch {
            VoiceLog.log("launchSidecar \(logName): run() THREW: \(error)")
            return nil
        }
    }

    /// Sidecars run from App Support, NOT ~/Desktop. A Finder-launched app has no TCC permission for
    /// the Desktop, so a child Python whose venv lives under ~/Desktop hangs forever in an open()
    /// during interpreter startup (getpath) waiting on a TCC gate it can't present. App Support is not
    /// TCC-protected, so the sidecar's venv loads cleanly. (build_app.sh stages the sidecars here.)
    private func sidecarDir(_ name: String, env: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ProcessInfo.processInfo.environment[env]
            ?? "\(home)/Library/Application Support/GINEXUS/\(name)"
    }

    private func startMediaSidecar() {
        let dir = sidecarDir("media-sidecar", env: "GINEXUS_MEDIA_SIDECAR_DIR")
        mediaProcess = launchSidecar(dir: dir, port: mediaPort, preloadKey: "GINEXUS_MEDIA_PRELOAD", logName: "media.log")
    }

    /// Preloads TTS + STT so the first conversational turn is warm.
    private func startAudioSidecar() {
        let dir = sidecarDir("audio-sidecar", env: "GINEXUS_AUDIO_SIDECAR_DIR")
        audioProcess = launchSidecar(dir: dir, port: audioPort, preloadKey: "GINEXUS_AUDIO_PRELOAD", logName: "audio.log")
    }

    func shutdown() { process?.terminate(); appHost?.stop(); mediaProcess?.terminate(); audioProcess?.terminate() }

    /// Resolve the vault to inject: a user-chosen path (canonicalized, so a symlink into iCloud can't
    /// sneak past the check) if it's a real directory and NOT in iCloud, else fall back to auto-detect.
    static func resolveVault(_ chosen: String?) -> String? {
        if let path = chosen, !path.isEmpty {
            let real = canonical(path)
            var isDir: ObjCBool = false
            if !isICloudPath(real),
               FileManager.default.fileExists(atPath: real, isDirectory: &isDir), isDir.boolValue {
                return real
            }
        }
        return detectObsidianVault()
    }

    /// Resolve symlinks so an iCloud target can't hide behind a non-iCloud path string.
    /// `nonisolated` so the app-host (background thread) can reuse it for the PDF iCloud guard.
    nonisolated static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// True if a (preferably canonicalized) path lives under iCloud (hard rule #1: never touch
    /// ~/Library/Mobile Documents). Callers should pass a symlink-resolved path.
    nonisolated static func isICloudPath(_ path: String) -> Bool {
        let p = canonical(path)
        return p.contains("Mobile Documents") || p.contains("com~apple~CloudDocs")
    }

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
            guard let raw = v["path"] as? String else { continue }
            let path = canonical(raw)
            if isICloudPath(path) { continue }   // iCloud → skip (symlink-resolved)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return path
            }
        }
        return nil
    }
}
