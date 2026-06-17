// SettingsStore.swift — the app-side, observable owner of GinexusSettings (settings.json).
//
// This is the SINGLE writer of ~/Library/Application Support/GINEXUS/settings.json. AppModel
// persists last-used model/mode through it (defaultModel/defaultMode); the Settings screen binds
// the rest. The pure disk I/O lives in GinexusCore.SettingsFile so SpineController.boot() can
// read the same file before any View exists.
import Foundation
import Combine
import GinexusCore

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var settings: GinexusSettings {
        didSet {
            guard settings != oldValue else { return }
            try? SettingsFile.save(settings)
        }
    }

    private init() {
        settings = SettingsFile.load()
    }

    /// Mutate a copy then assign, so the single didSet fires once and writes through.
    func update(_ mutate: (inout GinexusSettings) -> Void) {
        var s = settings
        mutate(&s)
        settings = s
    }
}
