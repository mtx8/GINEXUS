// Conversation.swift — a persisted chat transcript and its lightweight index row.
//
// One Conversation is stored as a single <id>.json file; ConversationMeta is the cheap
// projection written into index.json so the sidebar can list every chat without decoding
// every full transcript at launch. `schemaVersion` is stamped on every file so the store can
// migrate cleanly when transcripts move core-side (SP9, shared across iPhone/Watch/Hermes heads).
import Foundation

public struct Conversation: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    public var messages: [ChatMsg]
    /// SP-Projects: the project this thread belongs to (nil = a loose chat). Back-compatible:
    /// older transcripts without the key decode as nil.
    public var projectID: UUID?
    public var schemaVersion: Int

    public init(id: UUID = UUID(), title: String, createdAt: Date, updatedAt: Date,
                messages: [ChatMsg], projectID: UUID? = nil, schemaVersion: Int = 2) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.projectID = projectID
        self.schemaVersion = schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        messages = try c.decode([ChatMsg].self, forKey: .messages)
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }

    /// The lightweight index projection for the sidebar.
    public var meta: ConversationMeta {
        ConversationMeta(id: id, title: title, updatedAt: updatedAt, messageCount: messages.count, projectID: projectID)
    }
}

public struct ConversationMeta: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    public var updatedAt: Date
    public var messageCount: Int
    public var projectID: UUID?

    public init(id: UUID, title: String, updatedAt: Date, messageCount: Int, projectID: UUID? = nil) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.projectID = projectID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        messageCount = try c.decode(Int.self, forKey: .messageCount)
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
    }
}
