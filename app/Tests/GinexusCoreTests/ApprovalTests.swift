// Cross-language parity for the approval token: these golden vectors are byte-identical to the
// Rust core (ginexus_security::approval) and the Python reference. If JSONSerialization ever
// diverges from serde_json's canonical form, these fail and every real approval would be rejected.
import XCTest
@testable import GinexusCore

final class ApprovalTests: XCTestCase {
    // key = bytes 0x00..0x1f (matches the Rust tests' `key()`)
    let keyHex = (0..<32).map { String(format: "%02x", $0) }.joined()

    func testCanonicalAndHmacGoldenVector1() {
        let payload = Approval.canonicalPayload(
            action: "killswitch.reset", args: [:], target: "killswitch",
            nonce: "nonce-1", expiryMs: 1_718_000_000_000, bootId: "boot-xyz")
        XCTAssertEqual(
            String(data: payload ?? Data(), encoding: .utf8),
            #"{"action":"killswitch.reset","args":{},"boot_id":"boot-xyz","expiry_ms":1718000000000,"nonce":"nonce-1","target":"killswitch","v":1}"#)
        XCTAssertEqual(
            Approval.mint(approvalKeyHex: keyHex, action: "killswitch.reset", args: [:],
                          target: "killswitch", nonce: "nonce-1", expiryMs: 1_718_000_000_000, bootId: "boot-xyz"),
            "30f2b224641b070b35a1544ac212fd223552325ee040f3d0ef0d26b7d87a2255")
    }

    func testNestedArgsSortedGoldenVector2() {
        let args: [String: Any] = ["name": "shopping", "content": "milk, eggs"]
        let payload = Approval.canonicalPayload(
            action: "write_note", args: args, target: "shopping",
            nonce: "n1", expiryMs: 1_718_000_000_000, bootId: "boot-xyz")
        XCTAssertEqual(
            String(data: payload ?? Data(), encoding: .utf8),
            #"{"action":"write_note","args":{"content":"milk, eggs","name":"shopping"},"boot_id":"boot-xyz","expiry_ms":1718000000000,"nonce":"n1","target":"shopping","v":1}"#)
        XCTAssertEqual(
            Approval.mint(approvalKeyHex: keyHex, action: "write_note", args: args, target: "shopping",
                          nonce: "n1", expiryMs: 1_718_000_000_000, bootId: "boot-xyz"),
            "f38b0c1d7fdbc9a7afda23b05fe910a9d40489f20e5923debc88f3385741a80e")
    }

    func testTargetOf() {
        XCTAssertEqual(Approval.target(forTool: "write_note", args: ["name": "n"]), "n")
        XCTAssertEqual(Approval.target(forTool: "calendar_create", args: ["title": "x"]), "tool:calendar_create")
    }
}
