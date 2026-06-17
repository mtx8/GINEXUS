// ConversationStore.swift — app-side persistence for conversation transcripts.
//
// v1 keeps transcripts APP-SIDE: the Rust core is stateless per request (it receives the full
// messages array every call and persists only MEMORY, never the transcript), so the transcript
// is purely an app concern. The protocol exists so a future UDSConversationStore can serve the
// IDENTICAL Conversation JSON over the core's UDS when multiple heads (iPhone/Watch/Hermes, SP9)
// need to share history — the disk impl swaps out behind the same interface, no model change.
//
// Layout under ~/Library/Application Support/GINEXUS/conversations/:
//   <uuid>.json   — one full Conversation per chat
//   index.json    — an array of ConversationMeta for the sidebar
//
// Concurrency contract (matters — the app fires saves/deletes per turn from @MainActor):
//   • All mutations run on ONE private SERIAL queue, so two writes can never interleave (no torn
//     index.json, no resurrection of a just-deleted file by a late save).
//   • The caller (AppModel, on the main actor) owns the AUTHORITATIVE index: it passes the full
//     in-memory [ConversationMeta] snapshot to every save/delete, which is written VERBATIM. The
//     store never read-modify-writes index.json, so there is no lost-update. Submission order from
//     the main actor == execution order (serial queue is FIFO), so the last write wins correctly.
//   • Reads (load/loadIndex) run on the same serial queue (queue.sync), so they observe all
//     previously-submitted writes. index.json is still self-healing: if it is missing/empty it is
//     rebuilt by scanning the directory of <uuid>.json transcripts (the source of truth).
import Foundation

public protocol ConversationStoring: Sendable {
    func loadIndex() -> [ConversationMeta]
    func load(id: UUID) -> Conversation?
    /// Persist `conversation` and overwrite index.json with `index` verbatim (caller-owned truth).
    func save(_ conversation: Conversation, index: [ConversationMeta])
    /// Remove `conversation` and overwrite index.json with `index` verbatim (caller already pruned it).
    func delete(id: UUID, index: [ConversationMeta])
}

public final class DiskConversationStore: ConversationStoring, @unchecked Sendable {
    // All mutable access is confined to `queue`, so @unchecked Sendable is sound.
    private let dir: URL
    private let queue = DispatchQueue(label: "ginexus.conversation.store")

    /// `baseDirectory` overridable for tests; defaults to the app-owned conversations folder.
    public init(baseDirectory: URL? = nil) {
        let base = baseDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GINEXUS", isDirectory: true)
            .appendingPathComponent("conversations", isDirectory: true)
        dir = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    private var indexURL: URL { dir.appendingPathComponent("index.json") }
    private func fileURL(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).json") }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func save(_ conversation: Conversation, index: [ConversationMeta]) {
        queue.async { [self] in
            if let data = try? Self.encoder.encode(conversation) {
                try? data.write(to: fileURL(conversation.id), options: .atomic)
            }
            writeIndexVerbatim(index)
        }
    }

    public func delete(id: UUID, index: [ConversationMeta]) {
        queue.async { [self] in
            try? FileManager.default.removeItem(at: fileURL(id))
            writeIndexVerbatim(index)
        }
    }

    public func load(id: UUID) -> Conversation? {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL(id)) else { return nil }
            return try? Self.decoder.decode(Conversation.self, from: data)
        }
    }

    public func loadIndex() -> [ConversationMeta] {
        queue.sync {
            if let data = try? Data(contentsOf: indexURL),
               let metas = try? Self.decoder.decode([ConversationMeta].self, from: data),
               !metas.isEmpty {
                let live = metas.filter { FileManager.default.fileExists(atPath: fileURL($0.id).path) }
                if live.count == metas.count {
                    return live.sorted { $0.updatedAt > $1.updatedAt }
                }
                return rebuildIndexLocked()   // drift → rebuild from the directory of record
            }
            return rebuildIndexLocked()
        }
    }

    // MARK: queue-confined helpers

    /// Write index.json exactly as given (newest-first). The caller owns the truth.
    private func writeIndexVerbatim(_ metas: [ConversationMeta]) {
        let sorted = metas.sorted { $0.updatedAt > $1.updatedAt }
        guard let data = try? Self.encoder.encode(sorted) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Rebuild index.json by scanning the directory of <uuid>.json transcripts. MUST be called on
    /// `queue` (it is, from loadIndex's queue.sync).
    private func rebuildIndexLocked() -> [ConversationMeta] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        var metas: [ConversationMeta] = []
        for f in files where f.pathExtension == "json" && f.lastPathComponent != "index.json" {
            if let data = try? Data(contentsOf: f),
               let conv = try? Self.decoder.decode(Conversation.self, from: data) {
                metas.append(conv.meta)
            }
        }
        writeIndexVerbatim(metas)
        return metas.sorted { $0.updatedAt > $1.updatedAt }
    }
}
