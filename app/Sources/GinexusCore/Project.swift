// Project.swift — SP-Projects. A workspace that groups a folder of files, custom instructions, and
// its own chat threads (Conversations carry projectID). Projects are few, so the whole set lives in
// one projects.json (unlike per-file transcripts).
//
// folderPath is a real LOCAL directory (default ~/GINEXUS-Projects/<slug>); iCloud is refused at the
// app layer (hard rule #1). Files added to a project are read via read_document and chunked into
// memory tagged with the projectID, so the project's threads are grounded in its own files.
import Foundation

public struct Project: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var instructions: String       // per-project system prompt (user-authored = trusted)
    public var folderPath: String?        // local folder for this project's files
    public let createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(id: UUID = UUID(), name: String, instructions: String = "",
                folderPath: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date(),
                schemaVersion: Int = 1) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.folderPath = folderPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        folderPath = try c.decodeIfPresent(String.self, forKey: .folderPath)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }

    /// A filesystem-safe slug for the default folder name.
    public var slug: String {
        let allowed = CharacterSet.alphanumerics
        let s = name.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(s).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? id.uuidString.prefix(8).lowercased() : collapsed
    }
}

public protocol ProjectStoring: Sendable {
    func load() -> [Project]
    func save(_ projects: [Project])
}

public final class DiskProjectStore: ProjectStoring, @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "ginexus.project.store")

    public init(baseDirectory: URL? = nil) {
        let base = baseDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GINEXUS", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("projects.json")
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    public func load() -> [Project] {
        queue.sync {
            guard let data = try? Data(contentsOf: url),
                  let ps = try? Self.decoder.decode([Project].self, from: data) else { return [] }
            return ps.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    public func save(_ projects: [Project]) {
        queue.async { [self] in
            guard let data = try? Self.encoder.encode(projects.sorted { $0.updatedAt > $1.updatedAt }) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
