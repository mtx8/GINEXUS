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
    public var schemaVersion: Int

    public init(id: UUID = UUID(), title: String, createdAt: Date, updatedAt: Date,
                messages: [ChatMsg], schemaVersion: Int = 1) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.schemaVersion = schemaVersion
    }

    /// The lightweight index projection for the sidebar.
    public var meta: ConversationMeta {
        ConversationMeta(id: id, title: title, updatedAt: updatedAt, messageCount: messages.count)
    }
}

public struct ConversationMeta: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    public var updatedAt: Date
    public var messageCount: Int

    public init(id: UUID, title: String, updatedAt: Date, messageCount: Int) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.messageCount = messageCount
    }
}
