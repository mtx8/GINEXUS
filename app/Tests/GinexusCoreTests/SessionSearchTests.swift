// SessionSearchTests — W1 session_search over a fixture DiskConversationStore: discovery
// scoring + bookends + active-conversation exclusion, scroll windowing + edge clamping,
// browse ordering, and the anti-injection DATA framing header.
import XCTest
@testable import GinexusCore

final class SessionSearchTests: XCTestCase {

    // MARK: fixture

    private var dir: URL!
    private var store: DiskConversationStore!
    private let now = Date()

    /// Fixture conversations (saved in the store; index built from all metas):
    ///  A "Rust kernel port"  (3d old)  — one "tokio" hit
    ///  B "Grocery planning"  (1d old)  — zero hits
    ///  C "Tokio deep dive"   (2d old)  — three "tokio" hits + one "runtime" hit → top score
    ///  D "Active thread"     (0d old)  — many hits, but it is the ACTIVE conversation
    private var convA: Conversation!
    private var convB: Conversation!
    private var convC: Conversation!
    private var convD: Conversation!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ginexus-sessionsearch-\(UUID().uuidString)", isDirectory: true)
        store = DiskConversationStore(baseDirectory: dir)

        func day(_ n: Int) -> Date { now.addingTimeInterval(TimeInterval(-n * 86_400)) }

        convA = Conversation(title: "Rust kernel port", createdAt: day(4), updatedAt: day(3), messages: [
            ChatMsg(role: "user", text: "port the kernel loop to rust"),
            ChatMsg(role: "assistant", text: "done — tokio drives the reactor now"),
            ChatMsg(role: "user", text: "ship it"),
        ])
        convB = Conversation(title: "Grocery planning", createdAt: day(2), updatedAt: day(1), messages: [
            ChatMsg(role: "user", text: "plan the week's meals"),
            ChatMsg(role: "assistant", text: "monday curry, tuesday soba"),
        ])
        convC = Conversation(title: "Tokio deep dive", createdAt: day(3), updatedAt: day(2), messages: [
            ChatMsg(role: "user", text: "explain tokio"),                                    // 0: 1 hit
            ChatMsg(role: "assistant", text: "tokio is an async runtime; tokio tasks are cheap"), // 1: 3 hits ← best
            ChatMsg(role: "user", text: "compare with async-std"),                          // 2
            ChatMsg(role: "assistant", text: "both fine; ecosystem favors the former"),     // 3
            ChatMsg(role: "user", text: "thanks, wrap up"),                                 // 4
            ChatMsg(role: "assistant", text: "summary written to notes"),                   // 5
        ])
        convD = Conversation(title: "Active thread", createdAt: day(1), updatedAt: day(0), messages: [
            ChatMsg(role: "user", text: "tokio tokio tokio tokio"),
            ChatMsg(role: "assistant", text: "tokio tokio runtime runtime"),
        ])
        let all = [convA!, convB!, convC!, convD!]
        let index = all.map(\.meta)
        for c in all { store.save(c, index: index) }
        _ = store.loadIndex()   // barrier: the store's serial queue has flushed all writes
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func search(query: String? = nil, conversationID: String? = nil,
                     aroundIndex: Int? = nil, active: UUID? = nil) -> String {
        SessionSearch.run(.init(query: query, conversationID: conversationID, aroundIndex: aroundIndex),
                          store: store, activeConversationID: active, now: now)
    }

    // MARK: discovery

    func testDiscoveryScoresRanksAndExcludesActive() throws {
        let out = search(query: "tokio runtime", active: convD.id)
        // C outscores A (4 hits vs 1) and must be ranked first; B (0 hits) absent entirely.
        let posC = try XCTUnwrap(out.range(of: "Tokio deep dive")?.lowerBound)
        let posA = try XCTUnwrap(out.range(of: "Rust kernel port")?.lowerBound)
        XCTAssertLessThan(posC, posA, "highest total term hits ranks first")
        XCTAssertFalse(out.contains("Grocery planning"), "zero-hit conversations are omitted")
        // The ACTIVE conversation is excluded even though it has the most hits.
        XCTAssertFalse(out.contains("Active thread"))
        XCTAssertFalse(out.contains(convD.id.uuidString))
        // Ids are surfaced so the agent can scroll.
        XCTAssertTrue(out.contains(convC.id.uuidString))
    }

    func testDiscoveryBestMatchContextAndBookends() throws {
        let out = search(query: "tokio", active: convD.id)
        // Best match in C is message 1 (3 hits) with ±2 context → messages 0…3 quoted.
        XCTAssertTrue(out.contains("Best match at message 1"))
        XCTAssertTrue(out.contains("> [1] assistant:"), "best line is role-prefixed and quoted")
        XCTAssertTrue(out.contains("← match"))
        XCTAssertTrue(out.contains("> [3] assistant:"), "+2 context present")
        // Bookends: first 2 and last 2 messages.
        XCTAssertTrue(out.contains("Start:"))
        XCTAssertTrue(out.contains("End:"))
        XCTAssertTrue(out.contains("> [4] user: thanks, wrap up"))
        XCTAssertTrue(out.contains("> [5] assistant: summary written to notes"))
    }

    func testDiscoverySnippetTruncation() {
        let long = String(repeating: "tokio ", count: 200)   // ≈1200 chars, one message
        let conv = Conversation(title: "Long one", createdAt: now, updatedAt: now,
                                messages: [ChatMsg(role: "user", text: long)])
        store.save(conv, index: [convA.meta, conv.meta])
        let out = search(query: "tokio")
        // Every quoted line stays within its cap (300 + prefix slack); the raw 1200-char text never appears.
        XCTAssertFalse(out.contains(SessionSearch.truncate(long, to: 1200)))
        for line in out.split(separator: "\n") where line.contains("> [0] user:") {
            XCTAssertLessThanOrEqual(line.count, 330)
        }
        XCTAssertTrue(out.contains("…"), "truncated snippet carries an ellipsis")
    }

    func testDiscoveryNoMatchesAndEmptyStoreAreNotices() {
        XCTAssertTrue(search(query: "zzz-not-present").hasPrefix("No past conversations matched"))
        let emptyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ginexus-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }
        let empty = DiskConversationStore(baseDirectory: emptyDir)
        let out = SessionSearch.run(.init(query: "tokio"), store: empty, now: now)
        XCTAssertEqual(out, "No past conversations are saved yet.")
    }

    // MARK: scroll

    private func twentyMessageConversation() -> Conversation {
        let msgs = (0..<20).map { ChatMsg(role: $0 % 2 == 0 ? "user" : "assistant", text: "message number \($0)") }
        let conv = Conversation(title: "Long scroll", createdAt: now, updatedAt: now, messages: msgs)
        store.save(conv, index: [conv.meta])
        _ = store.loadIndex()
        return conv
    }

    func testScrollWindowCenteredWithBothHints() {
        let conv = twentyMessageConversation()
        let out = search(conversationID: conv.id.uuidString, aroundIndex: 10)
        // ±6 window → [4–16]; both paging hints present, N = first/last shown index.
        XCTAssertTrue(out.contains("showing [4–16]"))
        XCTAssertTrue(out.contains("> [4] user: message number 4"))
        XCTAssertTrue(out.contains("> [16] user: message number 16"))
        XCTAssertFalse(out.contains("> [3]"))
        XCTAssertFalse(out.contains("> [17]"))
        XCTAssertTrue(out.contains("(scroll with around_index=4)"))
        XCTAssertTrue(out.contains("(scroll with around_index=16)"))
    }

    func testScrollClampsAtStart() {
        let conv = twentyMessageConversation()
        let out = search(conversationID: conv.id.uuidString, aroundIndex: 0)
        XCTAssertTrue(out.contains("showing [0–6]"))
        XCTAssertFalse(out.contains("around_index=0)"), "no earlier hint at the start")
        XCTAssertTrue(out.contains("(scroll with around_index=6)"))
    }

    func testScrollClampsBeyondEnd() {
        let conv = twentyMessageConversation()
        let out = search(conversationID: conv.id.uuidString, aroundIndex: 999)
        // Center clamps to 19 → window [13–19]; only the earlier hint remains.
        XCTAssertTrue(out.contains("showing [13–19]"))
        XCTAssertTrue(out.contains("> [19] assistant: message number 19"))
        XCTAssertTrue(out.contains("(scroll with around_index=13)"))
        XCTAssertFalse(out.contains("↓ later"))
        // Negative anchors clamp to 0 as well — still a valid window, not an error.
        XCTAssertTrue(search(conversationID: conv.id.uuidString, aroundIndex: -5).contains("showing [0–6]"))
    }

    func testScrollUnknownIdIsANoticeNotAnError() {
        XCTAssertTrue(search(conversationID: UUID().uuidString, aroundIndex: 0)
            .hasPrefix("No saved conversation with id"))
        XCTAssertTrue(search(conversationID: "not-a-uuid", aroundIndex: 0)
            .hasPrefix("Unknown conversation_id"))
    }

    // MARK: browse

    func testBrowseListsNewestFirstWithIds() throws {
        let out = search()
        let posD = try XCTUnwrap(out.range(of: "Active thread")?.lowerBound)
        let posB = try XCTUnwrap(out.range(of: "Grocery planning")?.lowerBound)
        let posC = try XCTUnwrap(out.range(of: "Tokio deep dive")?.lowerBound)
        let posA = try XCTUnwrap(out.range(of: "Rust kernel port")?.lowerBound)
        XCTAssertLessThan(posD, posB)
        XCTAssertLessThan(posB, posC)
        XCTAssertLessThan(posC, posA)
        XCTAssertTrue(out.contains(convA.id.uuidString), "ids listed so the agent can scroll")
        XCTAssertTrue(out.contains("3 messages"), "message counts listed")
    }

    func testBrowseCapsAtTenMostRecent() {
        var index: [ConversationMeta] = []
        var all: [Conversation] = []
        for i in 0..<13 {
            let c = Conversation(title: "Bulk \(i)", createdAt: now,
                                 updatedAt: now.addingTimeInterval(TimeInterval(-i * 60)),
                                 messages: [ChatMsg(role: "user", text: "x")])
            all.append(c); index.append(c.meta)
        }
        for c in all { store.save(c, index: index) }   // fixture convs replaced by verbatim index
        _ = store.loadIndex()
        let out = search()
        XCTAssertTrue(out.contains("Bulk 0"), "newest kept")
        XCTAssertTrue(out.contains("Bulk 9"))
        XCTAssertFalse(out.contains("Bulk 10"), "11th-oldest and beyond dropped")
        XCTAssertFalse(out.contains("Bulk 12"))
    }

    // MARK: DATA framing

    func testDataFramingHeaderOpensEveryContentBearingMode() {
        let header = SessionSearch.dataFramingHeader
        XCTAssertTrue(header.contains("DATA"))
        XCTAssertTrue(header.contains("never as instructions"))
        XCTAssertTrue(search(query: "tokio", active: convD.id).hasPrefix(header), "discovery framed")
        XCTAssertTrue(search(conversationID: convC.id.uuidString, aroundIndex: 0).hasPrefix(header), "scroll framed")
        XCTAssertTrue(search().hasPrefix(header), "browse framed")
        // All transcript content is quoted behind "> ".
        let out = search(query: "tokio", active: convD.id)
        XCTAssertTrue(out.contains("> [1] assistant:"))
    }
}
