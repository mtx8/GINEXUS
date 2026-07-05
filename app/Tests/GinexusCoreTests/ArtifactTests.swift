// ArtifactTests — the pure artifact path-detection/classification logic that drives the in-app
// artifact viewer: extension → kind mapping, filename extraction, and the normalize() dedupe that
// turns a raw tool-produced path list into the ordered, unique set of cards to render.
import XCTest
@testable import GinexusCore

final class ArtifactTests: XCTestCase {

    // MARK: kind(forPath:)

    func testImageExtensionsClassifyAsImage() {
        for ext in ["png", "jpg", "jpeg", "heic", "webp", "gif", "PNG", "JPG"] {
            XCTAssertEqual(Artifact.kind(forPath: "/tmp/pic.\(ext)"), .image, "\(ext) should be image")
        }
    }

    func testDocumentExtensionsClassifyAsDocument() {
        for ext in ["pdf", "pages", "docx", "doc", "md", "txt", "csv", "json", "html", "PDF", "Docx"] {
            XCTAssertEqual(Artifact.kind(forPath: "/tmp/file.\(ext)"), .document, "\(ext) should be document")
        }
    }

    func testUnknownExtensionFallsBackToOther() {
        XCTAssertEqual(Artifact.kind(forPath: "/tmp/model.stl"), .other)
        XCTAssertEqual(Artifact.kind(forPath: "/tmp/noext"), .other)
        XCTAssertEqual(Artifact.kind(forPath: "/tmp/archive.zip"), .other)
    }

    func testKindHandlesRealArtifactDirs() {
        let img = "/Users/x/Library/Application Support/GINEXUS/media/gen-123.png"
        let doc = "/Users/x/Library/Application Support/GINEXUS/documents/report.pdf"
        XCTAssertEqual(Artifact.kind(forPath: img), .image)
        XCTAssertEqual(Artifact.kind(forPath: doc), .document)
    }

    // MARK: filename / ext

    func testFilenameAndExt() {
        let p = "/Users/x/Documents/MSR/Q3 Report.pdf"
        XCTAssertEqual(Artifact.filename(p), "Q3 Report.pdf")   // spaces preserved
        XCTAssertEqual(Artifact.ext(p), "pdf")
        XCTAssertEqual(Artifact.ext("/tmp/noext"), "")
    }

    // MARK: normalize()

    func testNormalizeDropsEmptyAndWhitespace() {
        let input = ["", "   ", "/tmp/a.png", "\t"]
        XCTAssertEqual(Artifact.normalize(input), ["/tmp/a.png"])
    }

    func testNormalizeDedupesPreservingFirstSeenOrder() {
        let input = ["/tmp/b.pdf", "/tmp/a.png", "/tmp/b.pdf", "/tmp/c.txt", "/tmp/a.png"]
        XCTAssertEqual(Artifact.normalize(input), ["/tmp/b.pdf", "/tmp/a.png", "/tmp/c.txt"])
    }

    func testNormalizeTrimsSurroundingWhitespace() {
        XCTAssertEqual(Artifact.normalize(["  /tmp/a.png  "]), ["/tmp/a.png"])
    }

    func testNormalizeEmptyInput() {
        XCTAssertTrue(Artifact.normalize([]).isEmpty)
    }

    // MARK: ChatMsg persistence of artifactPaths (round-trips + back-compat)

    func testChatMsgPersistsArtifactPaths() throws {
        let msg = ChatMsg(role: "assistant", text: "done",
                          artifactPaths: ["/tmp/a.png", "/tmp/b.pdf"])
        let data = try JSONEncoder().encode(msg)
        let back = try JSONDecoder().decode(ChatMsg.self, from: data)
        XCTAssertEqual(back.artifactPaths, ["/tmp/a.png", "/tmp/b.pdf"])
    }

    func testChatMsgArtifactPathsDefaultsEmptyForLegacyTranscripts() throws {
        // A message encoded before artifactPaths existed has no such key.
        let legacy = #"{"id":"\#(UUID().uuidString)","role":"assistant","text":"hi","docPath":"/tmp/x.pdf"}"#
        let back = try JSONDecoder().decode(ChatMsg.self, from: Data(legacy.utf8))
        XCTAssertEqual(back.artifactPaths, [])       // absent key → empty, no crash
        XCTAssertEqual(back.docPath, "/tmp/x.pdf")   // legacy field still drives the fallback render
    }
}
