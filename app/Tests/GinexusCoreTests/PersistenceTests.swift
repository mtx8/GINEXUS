// PersistenceTests — the conversation-history data layer: ChatMsg Codable identity, the disk
// store's save/load/index/delete cycle (incl. index rebuild on drift), and GinexusSettings'
// forward/back-compatible decode + fail-safe load.
import XCTest
@testable import GinexusCore

final class PersistenceTests: XCTestCase {

    // MARK: ChatMsg Codable

    func testChatMsgRoundTripPreservesIdAndDropsTransientState() throws {
        let id = UUID()
        let msg = ChatMsg(id: id, role: "assistant", text: "hello\nworld",
                          imagePath: "/tmp/x.png", streaming: true, status: "tool · running…")
        let data = try JSONEncoder().encode(msg)
        let back = try JSONDecoder().decode(ChatMsg.self, from: data)
        XCTAssertEqual(back.id, id)                 // id decoded, never re-minted
        XCTAssertEqual(back.role, "assistant")
        XCTAssertEqual(back.text, "hello\nworld")
        XCTAssertEqual(back.imagePath, "/tmp/x.png")
        XCTAssertFalse(back.streaming)              // transient → always loads finalized
        XCTAssertNil(back.status)                   // transient → dropped
    }

    func testChatMsgArrayRoundTripStableIds() throws {
        let msgs = [ChatMsg(role: "user", text: "q"), ChatMsg(role: "assistant", text: "a")]
        let data = try JSONEncoder().encode(msgs)
        let back = try JSONDecoder().decode([ChatMsg].self, from: data)
        XCTAssertEqual(back.map(\.id), msgs.map(\.id))
    }

    // MARK: DiskConversationStore

    private func tempStore() throws -> (DiskConversationStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ginexus-test-\(UUID().uuidString)", isDirectory: true)
        return (DiskConversationStore(baseDirectory: dir), dir)
    }

    func testSaveLoadIndexDelete() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let conv = Conversation(title: "First chat", createdAt: Date(), updatedAt: Date(),
                                messages: [ChatMsg(role: "user", text: "hi"),
                                           ChatMsg(role: "assistant", text: "hello")])
        store.save(conv, index: [conv.meta])

        let index = store.loadIndex()
        XCTAssertEqual(index.count, 1)
        XCTAssertEqual(index.first?.id, conv.id)
        XCTAssertEqual(index.first?.title, "First chat")
        XCTAssertEqual(index.first?.messageCount, 2)

        let loaded = try XCTUnwrap(store.load(id: conv.id))
        XCTAssertEqual(loaded.id, conv.id)
        XCTAssertEqual(loaded.title, conv.title)
        XCTAssertEqual(loaded.messages, conv.messages)   // incl. stable message ids
        // Timestamps round-trip at second resolution (iso8601, human-readable on disk).
        XCTAssertEqual(loaded.createdAt.timeIntervalSince1970, conv.createdAt.timeIntervalSince1970, accuracy: 1.0)

        store.delete(id: conv.id, index: [])
        XCTAssertNil(store.load(id: conv.id))
        XCTAssertTrue(store.loadIndex().isEmpty)
    }

    func testIndexWrittenVerbatimNewestFirst() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = Conversation(title: "old", createdAt: Date(timeIntervalSince1970: 1000),
                               updatedAt: Date(timeIntervalSince1970: 1000), messages: [])
        let new = Conversation(title: "new", createdAt: Date(timeIntervalSince1970: 2000),
                               updatedAt: Date(timeIntervalSince1970: 2000), messages: [])
        store.save(old, index: [old.meta])
        store.save(new, index: [old.meta, new.meta])   // caller passes the authoritative snapshot
        XCTAssertEqual(store.loadIndex().map(\.title), ["new", "old"])   // store sorts newest-first
    }

    func testIndexRebuiltWhenMissing() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let conv = Conversation(title: "orphan", createdAt: Date(), updatedAt: Date(), messages: [])
        store.save(conv, index: [conv.meta])
        _ = store.loadIndex()   // sync point: blocks until the queued async save has written to disk
        // Remove index.json — the directory of transcripts is the source of truth.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("index.json"))
        let index = store.loadIndex()
        XCTAssertEqual(index.count, 1)
        XCTAssertEqual(index.first?.title, "orphan")
    }

    // MARK: GinexusSettings

    func testSettingsDefaultsAndValidation() {
        let s = GinexusSettings()
        XCTAssertEqual(s.defaultModel, "auto")
        XCTAssertEqual(s.defaultMode, "hitl")
        XCTAssertTrue(s.persistTranscript)
        XCTAssertTrue(s.ollamaBaseIsLoopback)
        XCTAssertTrue(s.ollamaBaseIsValid)
    }

    func testSettingsRejectsMalformedOllamaBase() {
        var s = GinexusSettings(); s.ollamaBase = "http://10.0.0.5:11434"   // no /v1, non-loopback
        XCTAssertFalse(s.ollamaBaseIsValid)
        XCTAssertFalse(s.ollamaBaseIsLoopback)
    }

    func testSettingsPartialJSONDecodesWithDefaults() throws {
        // An older/partial settings.json missing most fields must decode with defaulted values.
        let json = #"{"defaultMode":"autonomous"}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(GinexusSettings.self, from: json)
        XCTAssertEqual(s.defaultMode, "autonomous")
        XCTAssertEqual(s.defaultModel, "auto")            // defaulted
        XCTAssertEqual(s.ollamaBase, GinexusSettings.defaultOllamaBase)
    }

    func testSettingsFileLoadFailsSafeOnCorruption() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ginexus-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try "{ not valid json".data(using: .utf8)!.write(to: url)
        let s = SettingsFile.load(from: url)
        XCTAssertEqual(s, GinexusSettings())              // known-good defaults, never a throw
    }

    func testSettingsFileSaveLoadRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ginexus-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var s = GinexusSettings(); s.defaultModel = "smart"; s.persistTranscript = false
        try SettingsFile.save(s, to: url)
        XCTAssertEqual(SettingsFile.load(from: url), s)
    }
}
