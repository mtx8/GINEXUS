// FabTypes.swift — SP-FAB models: what the app knows about printers and fabrication jobs.
// Parsed from the core's /v1/fab/* JSON. Pure data + parsing → unit-testable in GinexusCore.
import Foundation

/// One configured printer with its latest live status snapshot.
public struct FabPrinter: Identifiable, Equatable, Sendable {
    public let id: String            // printer_id (registry slug)
    public var name: String
    public var kind: String          // sdcp | octoprint | moonraker | mock
    public var host: String
    public var model: String
    public var state: String         // idle|printing|paused|error|offline|…
    public var progress: Double?     // 0…1
    public var currentLayer: Int?
    public var totalLayers: Int?
    public var timeLeftSecs: Int?
    public var jobName: String?
    public var detail: String?

    public init(id: String, name: String, kind: String, host: String, model: String,
                state: String, progress: Double? = nil, currentLayer: Int? = nil,
                totalLayers: Int? = nil, timeLeftSecs: Int? = nil,
                jobName: String? = nil, detail: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.host = host; self.model = model
        self.state = state; self.progress = progress; self.currentLayer = currentLayer
        self.totalLayers = totalLayers; self.timeLeftSecs = timeLeftSecs
        self.jobName = jobName; self.detail = detail
    }

    public static func parse(_ o: [String: Any]) -> FabPrinter? {
        guard let id = o["printer_id"] as? String, !id.isEmpty else { return nil }
        return FabPrinter(
            id: id,
            name: (o["name"] as? String) ?? id,
            kind: (o["kind"] as? String) ?? "",
            host: (o["host"] as? String) ?? "",
            model: (o["model"] as? String) ?? "",
            state: (o["state"] as? String) ?? "unknown",
            progress: o["progress"] as? Double,
            currentLayer: (o["current_layer"] as? Int) ?? (o["current_layer"] as? NSNumber)?.intValue,
            totalLayers: (o["total_layers"] as? Int) ?? (o["total_layers"] as? NSNumber)?.intValue,
            timeLeftSecs: (o["time_left_secs"] as? Int) ?? (o["time_left_secs"] as? NSNumber)?.intValue,
            jobName: o["job_name"] as? String,
            detail: o["detail"] as? String
        )
    }

    /// True while the printer is doing something a human may need to watch.
    public var isActive: Bool { state == "printing" || state == "paused" || state == "busy" }
}

/// One fabrication job from the core's queue.
public struct FabJobItem: Identifiable, Equatable, Sendable {
    public let id: String            // job_id
    public var name: String
    public var printerID: String
    public var state: String         // draft|sliced|uploaded|printing|complete|failed|cancelled
    public var slicedPath: String
    public var validation: String
    public var updatedMs: Int64

    public init(id: String, name: String, printerID: String, state: String,
                slicedPath: String, validation: String, updatedMs: Int64) {
        self.id = id; self.name = name; self.printerID = printerID; self.state = state
        self.slicedPath = slicedPath; self.validation = validation; self.updatedMs = updatedMs
    }

    public static func parse(_ o: [String: Any]) -> FabJobItem? {
        guard let id = o["job_id"] as? String, !id.isEmpty else { return nil }
        return FabJobItem(
            id: id,
            name: (o["name"] as? String) ?? id,
            printerID: (o["printer_id"] as? String) ?? "",
            state: (o["state"] as? String) ?? "draft",
            slicedPath: (o["sliced_path"] as? String) ?? "",
            validation: (o["validation"] as? String) ?? "",
            updatedMs: (o["updated_ms"] as? Int64) ?? Int64((o["updated_ms"] as? Int) ?? 0)
        )
    }

    /// A finished plate must be cleared by a human before the printer takes the next job.
    public var awaitsClearance: Bool { state == "complete" }
}

/// "2h 14m" / "14m" / "45s" — the ETA grammar used across the Fabrication console.
public func fabETA(_ secs: Int) -> String {
    if secs < 60 { return "\(secs)s" }
    let m = secs / 60
    if m < 60 { return "\(m)m" }
    return "\(m / 60)h \(m % 60)m"
}
