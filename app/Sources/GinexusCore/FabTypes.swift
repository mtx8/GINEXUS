// FabTypes.swift — SP-FAB models: what the app knows about printers and fabrication jobs.
// Parsed from the core's /v1/fab/* JSON. Pure data + parsing → unit-testable in GinexusCore.
import Foundation

/// A labeled live telemetry reading (NOZZLE → "210 °C").
public struct FabTelemetry: Equatable, Sendable, Identifiable {
    public let label: String
    public let value: String
    public var id: String { label }
    public init(label: String, value: String) { self.label = label; self.value = value }
}

/// One configured printer with its latest live status snapshot.
public struct FabPrinter: Identifiable, Equatable, Sendable {
    public let id: String            // printer_id (registry slug)
    public var name: String
    public var kind: String          // sdcp | octoprint | moonraker | mock
    public var host: String
    public var mainboardID: String
    public var model: String
    public var state: String         // idle|printing|paused|error|offline|…
    public var progress: Double?     // 0…1
    public var currentLayer: Int?
    public var totalLayers: Int?
    public var timeLeftSecs: Int?
    public var elapsedSecs: Int?
    public var jobName: String?
    public var detail: String?
    public var extra: [FabTelemetry]  // granular live readings (temps, Z, release-film…)

    public init(id: String, name: String, kind: String, host: String, mainboardID: String = "",
                model: String, state: String, progress: Double? = nil, currentLayer: Int? = nil,
                totalLayers: Int? = nil, timeLeftSecs: Int? = nil, elapsedSecs: Int? = nil,
                jobName: String? = nil, detail: String? = nil, extra: [FabTelemetry] = []) {
        self.id = id; self.name = name; self.kind = kind; self.host = host
        self.mainboardID = mainboardID; self.model = model
        self.state = state; self.progress = progress; self.currentLayer = currentLayer
        self.totalLayers = totalLayers; self.timeLeftSecs = timeLeftSecs; self.elapsedSecs = elapsedSecs
        self.jobName = jobName; self.detail = detail; self.extra = extra
    }

    public static func parse(_ o: [String: Any]) -> FabPrinter? {
        guard let id = o["printer_id"] as? String, !id.isEmpty else { return nil }
        func i(_ k: String) -> Int? { (o[k] as? Int) ?? (o[k] as? NSNumber)?.intValue }
        let extra = (o["extra"] as? [[String: Any]])?.compactMap { row -> FabTelemetry? in
            guard let l = row["label"] as? String, let v = row["value"] as? String else { return nil }
            return FabTelemetry(label: l, value: v)
        } ?? []
        return FabPrinter(
            id: id,
            name: (o["name"] as? String) ?? id,
            kind: (o["kind"] as? String) ?? "",
            host: (o["host"] as? String) ?? "",
            mainboardID: (o["mainboard_id"] as? String) ?? "",
            model: (o["model"] as? String) ?? "",
            state: (o["state"] as? String) ?? "unknown",
            progress: o["progress"] as? Double,
            currentLayer: i("current_layer"), totalLayers: i("total_layers"),
            timeLeftSecs: i("time_left_secs"), elapsedSecs: i("elapsed_secs"),
            jobName: o["job_name"] as? String, detail: o["detail"] as? String, extra: extra
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

/// Mesh-gate result for a model (the Rust ModelReport). Drives the Prepare panel.
public struct FabModelReport: Equatable, Sendable {
    public let file: String
    public let triangles: Int
    public let vertices: Int
    public let watertight: Bool
    public let boundaryEdges: Int
    public let nonManifoldEdges: Int
    public let bboxMM: [Double]        // [x, y, z]
    public let volumeMM3: Double
    public let surfaceAreaMM2: Double
    public let overhangFraction: Double
    public let notes: [String]

    public init(file: String, triangles: Int, vertices: Int, watertight: Bool,
                boundaryEdges: Int, nonManifoldEdges: Int, bboxMM: [Double], volumeMM3: Double,
                surfaceAreaMM2: Double, overhangFraction: Double, notes: [String]) {
        self.file = file; self.triangles = triangles; self.vertices = vertices
        self.watertight = watertight; self.boundaryEdges = boundaryEdges
        self.nonManifoldEdges = nonManifoldEdges; self.bboxMM = bboxMM
        self.volumeMM3 = volumeMM3; self.surfaceAreaMM2 = surfaceAreaMM2
        self.overhangFraction = overhangFraction; self.notes = notes
    }

    public static func parse(_ o: [String: Any]) -> FabModelReport? {
        guard o["triangles"] != nil else { return nil }
        func d(_ k: String) -> Double { (o[k] as? Double) ?? (o[k] as? NSNumber)?.doubleValue ?? 0 }
        func i(_ k: String) -> Int { (o[k] as? Int) ?? (o[k] as? NSNumber)?.intValue ?? 0 }
        let bbox = (o["bbox_mm"] as? [Any])?.compactMap { ($0 as? Double) ?? ($0 as? NSNumber)?.doubleValue } ?? []
        return FabModelReport(
            file: (o["file"] as? String) ?? "",
            triangles: i("triangles"), vertices: i("vertices"),
            watertight: (o["watertight"] as? Bool) ?? false,
            boundaryEdges: i("boundary_edges"), nonManifoldEdges: i("non_manifold_edges"),
            bboxMM: bbox, volumeMM3: d("volume_mm3"), surfaceAreaMM2: d("surface_area_mm2"),
            overhangFraction: d("overhang_area_fraction"),
            notes: (o["notes"] as? [String]) ?? []
        )
    }

    /// Sliceable solid?
    public var passes: Bool { watertight && volumeMM3 > 0 && triangles > 0 }
    /// Volume in cm³ (mm³/1000) — the human-friendly unit for resin/filament estimation.
    public var volumeCM3: Double { volumeMM3 / 1000.0 }
    public var dims: String {
        guard bboxMM.count == 3 else { return "—" }
        return String(format: "%.1f × %.1f × %.1f mm", bboxMM[0], bboxMM[1], bboxMM[2])
    }
}

/// A printer camera descriptor from /v1/fab/camera.
public struct FabCamera: Equatable, Sendable {
    public let kind: String     // mjpeg_url | rtsp_url | snapshot_url | none
    public let url: String
    public init(kind: String, url: String) { self.kind = kind; self.url = url }
    public static func parse(_ o: [String: Any]) -> FabCamera {
        FabCamera(kind: (o["kind"] as? String) ?? "none", url: (o["url"] as? String) ?? "")
    }
    public var hasStream: Bool { kind != "none" && !url.isEmpty }
}

/// "just now" / "3m ago" / "2h ago" / "5d ago" — relative time from an epoch-ms timestamp.
public func fabRelTime(_ ms: Int64, now: Date = Date()) -> String {
    guard ms > 0 else { return "—" }
    let secs = Int(now.timeIntervalSince1970 - Double(ms) / 1000.0)
    if secs < 10 { return "just now" }
    if secs < 60 { return "\(secs)s ago" }
    let m = secs / 60
    if m < 60 { return "\(m)m ago" }
    let h = m / 60
    if h < 24 { return "\(h)h ago" }
    return "\(h / 24)d ago"
}

/// Duration grammar WITH seconds for the live-ticking readouts: "2h 14m 03s" / "1m 03s" / "45s".
public func fabETADuration(_ secs: Int) -> String {
    let s = secs % 60, m = (secs / 60) % 60, h = secs / 3600
    if h > 0 { return String(format: "%dh %02dm %02ds", h, m, s) }
    if m > 0 { return String(format: "%dm %02ds", m, s) }
    return "\(s)s"
}

/// "2h 14m" / "14m" / "45s" — the ETA grammar used across the Fabrication console.
public func fabETA(_ secs: Int) -> String {
    if secs < 60 { return "\(secs)s" }
    let m = secs / 60
    if m < 60 { return "\(m)m" }
    return "\(m / 60)h \(m % 60)m"
}
