// GinexusSettings.swift — the app's persisted configuration, and the SINGLE owner of
// ~/Library/Application Support/GINEXUS/settings.json.
//
// Two consumers read this file:
//   (a) SpineController.boot() reads it via SettingsFile.load() — a nonisolated, pure-Foundation
//       disk read — BEFORE any View exists, so core-config defaults (Ollama base, vault, media)
//       are honored from the first launch.
//   (b) the app's SettingsStore (@MainActor ObservableObject) binds it for live editing.
//
// Every field is defaulted and decoded with decodeIfPresent so an older/partial settings.json
// still loads (forward/back compatible); a fully corrupt file fails safe to all-defaults in
// SettingsFile.load(). Defaults describe the local, commercial-clean Ollama setup — never a
// remote host — so a missing or hostile file can never make boot() build an egressing env.
import Foundation

/// SP-Connect: one external MCP server GINEXUS launches over stdio. `command` is the full launch
/// line (e.g. "npx -y @notionhq/notion-mcp-server"). If `tokenEnv` + `credentialRef` are set, the
/// app injects Keychain[credentialRef] into the child as env[tokenEnv] (the secret never touches
/// settings.json). Imported tools are prefixed `mcp.<name>.` and stay default-deny (HITL).
public struct McpServerConfig: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String          // short slug, used as the tool prefix
    public var command: String       // stdio launch command line
    public var enabled: Bool
    public var tokenEnv: String?     // env var the command reads for its credential
    public var credentialRef: String? // Keychain account holding the secret

    public init(id: UUID = UUID(), name: String, command: String, enabled: Bool = true,
                tokenEnv: String? = nil, credentialRef: String? = nil) {
        self.id = id
        self.name = name
        self.command = command
        self.enabled = enabled
        self.tokenEnv = tokenEnv
        self.credentialRef = credentialRef
    }
}

public struct GinexusSettings: Codable, Sendable, Equatable {
    public var defaultModel: String          // picker default: "auto" | a roster tier id
    public var defaultMode: String           // "hitl" | "autonomous"
    public var ollamaBase: String            // OpenAI-compatible base, must end in /v1
    public var obsidianVaultPath: String?    // nil → auto-detect the open vault
    public var mediaSidecarEnabled: Bool     // gate the local image-generation sidecar + tool
    public var voiceEnabled: Bool            // gate the local voice (audio) sidecar + conversation loop
    public var mcpServers: [McpServerConfig] // SP-Connect: external MCP integrations (Notion, etc.)
    public var importIncludeAssistant: Bool  // include assistant turns when importing AI data
    public var persistTranscript: Bool       // keep conversation history on disk across launches
    public var schemaVersion: Int

    public static let defaultOllamaBase = "http://127.0.0.1:11434/v1"

    public init(defaultModel: String = "auto",
                defaultMode: String = "hitl",
                ollamaBase: String = GinexusSettings.defaultOllamaBase,
                obsidianVaultPath: String? = nil,
                mediaSidecarEnabled: Bool = true,
                voiceEnabled: Bool = true,
                mcpServers: [McpServerConfig] = [],
                importIncludeAssistant: Bool = false,
                persistTranscript: Bool = true,
                schemaVersion: Int = 2) {
        self.defaultModel = defaultModel
        self.defaultMode = defaultMode
        self.ollamaBase = ollamaBase
        self.obsidianVaultPath = obsidianVaultPath
        self.mediaSidecarEnabled = mediaSidecarEnabled
        self.voiceEnabled = voiceEnabled
        self.mcpServers = mcpServers
        self.importIncludeAssistant = importIncludeAssistant
        self.persistTranscript = persistTranscript
        self.schemaVersion = schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GinexusSettings()
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel) ?? d.defaultModel
        defaultMode = try c.decodeIfPresent(String.self, forKey: .defaultMode) ?? d.defaultMode
        ollamaBase = try c.decodeIfPresent(String.self, forKey: .ollamaBase) ?? d.ollamaBase
        obsidianVaultPath = try c.decodeIfPresent(String.self, forKey: .obsidianVaultPath)
        mediaSidecarEnabled = try c.decodeIfPresent(Bool.self, forKey: .mediaSidecarEnabled) ?? d.mediaSidecarEnabled
        voiceEnabled = try c.decodeIfPresent(Bool.self, forKey: .voiceEnabled) ?? d.voiceEnabled
        mcpServers = try c.decodeIfPresent([McpServerConfig].self, forKey: .mcpServers) ?? d.mcpServers
        importIncludeAssistant = try c.decodeIfPresent(Bool.self, forKey: .importIncludeAssistant) ?? d.importIncludeAssistant
        persistTranscript = try c.decodeIfPresent(Bool.self, forKey: .persistTranscript) ?? d.persistTranscript
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? d.schemaVersion
    }

    /// True when ollamaBase points at the loopback host (the only egress GINEXUS assumes).
    public var ollamaBaseIsLoopback: Bool {
        guard let u = URL(string: ollamaBase), let host = u.host else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// True when ollamaBase is a well-formed http(s) URL ending in /v1 (ollama_root strips /v1 to
    /// derive the native /api root used by model management — a malformed base breaks pulls/tags).
    public var ollamaBaseIsValid: Bool {
        guard let u = URL(string: ollamaBase), let scheme = u.scheme,
              scheme == "http" || scheme == "https", u.host != nil else { return false }
        return ollamaBase.hasSuffix("/v1")
    }

    /// Host-level SSRF guard for the model endpoint: loopback and ordinary LAN hosts are allowed (a
    /// user may run Ollama on another Mac), but cloud-metadata / link-local / wildcard targets are
    /// refused so a typo or a bad value can't turn the core into an SSRF pivot. Only loopback/allowed
    /// hosts are ever injected as GINEXUS_OLLAMA_BASE.
    public var ollamaBaseHostAllowed: Bool {
        guard let host = URL(string: ollamaBase)?.host else { return false }
        if host == "0.0.0.0" || host == "::" { return false }
        if host.hasPrefix("169.254.") { return false }   // link-local incl. 169.254.169.254 metadata
        if host == "metadata" || host.hasSuffix(".internal") { return false }
        return true
    }
}

/// Pure-Foundation disk access for settings.json. Nonisolated so SpineController.boot() can read
/// it before the UI exists. Writes are atomic; reads fail safe to defaults.
public enum SettingsFile {
    public static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GINEXUS", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("settings.json")
    }

    public static func load(from fileURL: URL? = nil) -> GinexusSettings {
        let u = fileURL ?? url
        guard let data = try? Data(contentsOf: u),
              let s = try? JSONDecoder().decode(GinexusSettings.self, from: data) else {
            return GinexusSettings()   // missing or corrupt → known-good local defaults
        }
        return s
    }

    public static func save(_ settings: GinexusSettings, to fileURL: URL? = nil) throws {
        let u = fileURL ?? url
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(settings)
        try data.write(to: u, options: .atomic)
        // Owner-only: stores the vault path + endpoint (not secrets, but keep it off other local users).
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
    }
}
