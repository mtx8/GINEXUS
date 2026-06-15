// GinexusIntents.swift — one App Intent + an AppShortcutsProvider. Being present in the
// signed bundle is what registers it with the system (Shortcuts / Spotlight / Siri).
// This is the SP1.5 proof that the App Intents surface works; the real tool-backed intents
// arrive in SP4/SP5.
import AppIntents

struct AskGinexusIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask GINEXUS"
    static let description = IntentDescription("Send a prompt to the local GINEXUS agent.")

    @Parameter(title: "Prompt")
    var prompt: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // SP1.5 stub: the SP2 kernel routes this over the UDS sidecar to the agent loop.
        return .result(value: "GINEXUS received: \(prompt)")
    }
}

struct GinexusShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskGinexusIntent(),
            phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) something"],
            shortTitle: "Ask GINEXUS",
            systemImageName: "brain.head.profile"
        )
    }
}
