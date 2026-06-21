import XCTest
@testable import GinexusCore

final class VoiceTests: XCTestCase {
    func testWavHeaderAndPayload() {
        // 3 samples → 6 bytes PCM + 44-byte canonical header.
        let wav = WAVUtil.wav(fromFloat: [0.0, 1.0, -1.0], sampleRate: 24000)
        XCTAssertEqual(wav.count, 44 + 6)
        XCTAssertEqual(Array(wav.prefix(4)), Array("RIFF".utf8))
        XCTAssertEqual(Array(wav[8..<12]), Array("WAVE".utf8))
        XCTAssertEqual(Array(wav[36..<40]), Array("data".utf8))

        // Full-scale samples clamp to int16 extremes.
        let payload = wav.suffix(6)
        let ints: [Int16] = stride(from: payload.startIndex, to: payload.endIndex, by: 2).map { i in
            Int16(littleEndian: payload[i...].prefix(2).withUnsafeBytes { $0.load(as: Int16.self) })
        }
        XCTAssertEqual(ints[0], 0)
        XCTAssertEqual(ints[1], 32767)
        XCTAssertEqual(ints[2], -32767)
    }

    func testVoiceClientRejectsBadBase() {
        XCTAssertNil(VoiceClient(base: ""))
        XCTAssertNotNil(VoiceClient(base: "http://127.0.0.1:8764"))
        XCTAssertEqual(VoiceClient.sampleRate, 24000)
    }
}
