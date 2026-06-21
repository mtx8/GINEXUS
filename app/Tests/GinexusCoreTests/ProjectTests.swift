import XCTest
@testable import GinexusCore

final class ProjectTests: XCTestCase {
    func testProjectSlug() {
        XCTAssertEqual(Project(name: "Taxes 2026").slug, "taxes-2026")
        XCTAssertEqual(Project(name: "  My  Project!! ").slug, "my-project")
    }

    func testProjectStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gx-proj-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DiskProjectStore(baseDirectory: dir)
        let p = Project(name: "Taxes 2026", instructions: "Be precise and cite forms.")
        store.save([p])
        // give the async write a beat
        let exp = expectation(description: "persist"); DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "Taxes 2026")
        XCTAssertEqual(loaded.first?.instructions, "Be precise and cite forms.")
    }

    func testConversationProjectIDBackCompat() throws {
        // Old transcript JSON without projectID must still decode (projectID = nil).
        let legacy = """
        {"id":"\(UUID().uuidString)","title":"old","createdAt":"2026-01-01T00:00:00Z",
         "updatedAt":"2026-01-01T00:00:00Z","messages":[],"schemaVersion":1}
        """
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let conv = try dec.decode(Conversation.self, from: Data(legacy.utf8))
        XCTAssertNil(conv.projectID)

        // And a project-tagged conversation round-trips.
        let pid = UUID()
        let tagged = Conversation(title: "t", createdAt: Date(), updatedAt: Date(), messages: [], projectID: pid)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let back = try dec.decode(Conversation.self, from: enc.encode(tagged))
        XCTAssertEqual(back.projectID, pid)
    }
}
