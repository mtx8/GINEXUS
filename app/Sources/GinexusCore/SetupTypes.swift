// SetupTypes.swift — the Setup Assistant's data model, parsed from /v1/setup/probe. Pure data +
// parsing so it's unit-testable in GinexusCore. Drives the onboarding wizard: what the machine is,
// what's installed, and which model to recommend (Mac-mini-aware).
import Foundation

public struct SetupHardware: Sendable, Equatable {
    public let chip: String
    public let appleSilicon: Bool
    public let ramGB: Double
    public let usableRamGB: Double
    public let freeStorageGB: Double
    public let cpuCores: Int
    public let perfCores: Int

    public static func parse(_ o: [String: Any]) -> SetupHardware {
        func d(_ k: String) -> Double { (o[k] as? Double) ?? (o[k] as? NSNumber)?.doubleValue ?? 0 }
        func i(_ k: String) -> Int { (o[k] as? Int) ?? (o[k] as? NSNumber)?.intValue ?? 0 }
        return SetupHardware(
            chip: (o["chip"] as? String) ?? "Unknown",
            appleSilicon: (o["apple_silicon"] as? Bool) ?? false,
            ramGB: d("ram_gb"), usableRamGB: d("usable_ram_gb"), freeStorageGB: d("free_storage_gb"),
            cpuCores: i("cpu_cores"), perfCores: i("perf_cores"))
    }
    public var ramLabel: String { "\(Int(ramGB.rounded())) GB" }
    public var usableLabel: String { String(format: "%.0f GB usable", usableRamGB) }
    public var storageLabel: String {
        freeStorageGB >= 1000 ? String(format: "%.1f TB free", freeStorageGB / 1000) : String(format: "%.0f GB free", freeStorageGB)
    }
}

public struct SetupDeps: Sendable, Equatable {
    public let ollamaInstalled: Bool
    public let ollamaRunning: Bool
    public let ollamaVersion: String?
    public let homebrew: Bool
    public let prusaslicer: Bool
    public let uvtools: Bool
    public let openscad: Bool

    public static func parse(_ o: [String: Any]) -> SetupDeps {
        func b(_ k: String) -> Bool { (o[k] as? Bool) ?? false }
        return SetupDeps(
            ollamaInstalled: b("ollama_installed"), ollamaRunning: b("ollama_running"),
            ollamaVersion: o["ollama_version"] as? String, homebrew: b("homebrew"),
            prusaslicer: b("prusaslicer"), uvtools: b("uvtools"), openscad: b("openscad"))
    }
    /// The runtime is fully ready to pull + serve models.
    public var ollamaReady: Bool { ollamaRunning }
}

public struct SetupModelInfo: Sendable, Equatable, Identifiable {
    public let id: String        // Ollama tag
    public let label: String
    public let role: String
    public let params: String
    public let note: String
    public let fit: String       // comfortable | tight | wont_fit
    public let sizeGB: Double
    public let minRamGB: Double
    public let installed: Bool
    public let recommended: Bool

    public static func parse(_ o: [String: Any]) -> SetupModelInfo? {
        guard let id = o["id"] as? String else { return nil }
        func d(_ k: String) -> Double { (o[k] as? Double) ?? (o[k] as? NSNumber)?.doubleValue ?? 0 }
        return SetupModelInfo(
            id: id, label: (o["label"] as? String) ?? id, role: (o["role"] as? String) ?? "",
            params: (o["params"] as? String) ?? "", note: (o["note"] as? String) ?? "",
            fit: (o["fit"] as? String) ?? "wont_fit", sizeGB: d("size_gb"), minRamGB: d("min_ram_gb"),
            installed: (o["installed"] as? Bool) ?? false, recommended: (o["recommended"] as? Bool) ?? false)
    }
    public var sizeLabel: String { sizeGB >= 1 ? String(format: "%.1f GB", sizeGB) : String(format: "%.0f MB", sizeGB * 1000) }
    public var fitsAtAll: Bool { fit != "wont_fit" }
}

public struct SetupProbe: Sendable, Equatable {
    public let hardware: SetupHardware
    public let deps: SetupDeps
    public let models: [SetupModelInfo]
    public let recommendedDailyDriver: String
    public let verdict: String

    public static func parse(_ o: [String: Any]) -> SetupProbe? {
        guard let hw = o["hardware"] as? [String: Any], let dp = o["dependencies"] as? [String: Any] else { return nil }
        let models = (o["models"] as? [[String: Any]])?.compactMap { SetupModelInfo.parse($0) } ?? []
        return SetupProbe(
            hardware: SetupHardware.parse(hw), deps: SetupDeps.parse(dp), models: models,
            recommendedDailyDriver: (o["recommended_daily_driver"] as? String) ?? "",
            verdict: (o["verdict"] as? String) ?? "")
    }
    public var recommendedModel: SetupModelInfo? { models.first { $0.recommended } }
    /// Chat/reasoning models the user can pick as a daily driver (excludes embed/utility/vision).
    public var chatModels: [SetupModelInfo] { models.filter { $0.role == "chat" || $0.role == "reasoning" } }
}
