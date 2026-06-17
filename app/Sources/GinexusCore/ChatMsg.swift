// ChatMsg.swift — one chat message. Lives in GinexusCore (not the app target) so it is
// independently testable and can be the persisted unit inside a Conversation.
//
// Codable contract: only the DURABLE fields round-trip (id/role/text/imagePath). `streaming`
// and `status` are transient UI state — a persisted message always decodes finalized
// (streaming=false, status=nil) so a transcript restored from disk never shows a stuck cursor
// or a stale "tool · running…" line. The `id` is decoded (never re-minted) so the app's
// streaming-bubble lookup (firstIndex by id) and ForEach identity stay stable across a reload.
import Foundation

public struct ChatMsg: Identifiable, Sendable, Codable, Equatable {
    public let id: UUID
    public let role: String            // "user" | "assistant"
    public var text: String            // mutable: assistant text grows as tokens stream in
    public var imagePath: String?      // an image rendered inline (generated, or a user attachment)
    public var docPath: String?        // a document produced this turn (PDF/Word) → Final Output card
    public var steps: [String]         // agent-flow actions taken this turn (tool names, in order)
    public var streaming: Bool         // true while tokens are still arriving (transient, not persisted)
    public var status: String?         // transient activity line, e.g. "deep_research · running…"

    public init(id: UUID = UUID(), role: String, text: String, imagePath: String? = nil,
                docPath: String? = nil, steps: [String] = [], streaming: Bool = false, status: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.imagePath = imagePath
        self.docPath = docPath
        self.steps = steps
        self.streaming = streaming
        self.status = status
    }

    private enum CodingKeys: String, CodingKey { case id, role, text, imagePath, docPath, steps }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(String.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath)
        docPath = try c.decodeIfPresent(String.self, forKey: .docPath)
        steps = try c.decodeIfPresent([String].self, forKey: .steps) ?? []
        streaming = false   // never persist mid-stream state
        status = nil         // transient
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(imagePath, forKey: .imagePath)
        try c.encodeIfPresent(docPath, forKey: .docPath)
        if !steps.isEmpty { try c.encode(steps, forKey: .steps) }
    }
}
