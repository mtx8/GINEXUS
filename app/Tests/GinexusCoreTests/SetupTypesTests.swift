// Setup Assistant probe parsing — mirrors the /v1/setup/probe JSON the Rust core emits.
import XCTest
@testable import GinexusCore

final class SetupTypesTests: XCTestCase {
    private func probeJSON() -> [String: Any] {
        let json = """
        {
          "hardware": {"chip":"Apple M4 Pro","apple_silicon":true,"ram_gb":64.0,"usable_ram_gb":51.2,
                       "free_storage_gb":420.0,"cpu_cores":12,"perf_cores":8},
          "dependencies": {"ollama_installed":true,"ollama_running":true,"ollama_version":"0.30.8",
                           "homebrew":true,"prusaslicer":true,"uvtools":false,"openscad":true},
          "models": [
            {"id":"qwen3:8b","label":"Qwen3 8B","role":"chat","params":"8B","size_gb":5.2,"min_ram_gb":12.0,
             "note":"n","fit":"comfortable","installed":false,"recommended":false},
            {"id":"qwen3:30b-a3b-instruct-2507-q4_K_M","label":"Qwen3 30B-A3B","role":"chat","params":"30B-A3B MoE",
             "size_gb":18.0,"min_ram_gb":30.0,"note":"n","fit":"comfortable","installed":true,"recommended":true},
            {"id":"nomic-embed-text","label":"nomic","role":"embed","params":"137M","size_gb":0.3,"min_ram_gb":4.0,
             "note":"n","fit":"comfortable","installed":true,"recommended":false}
          ],
          "recommended_daily_driver":"qwen3:30b-a3b-instruct-2507-q4_K_M",
          "verdict":"Comfortable — runs the full daily driver locally."
        }
        """
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
    }

    func testProbeParsesFully() throws {
        let p = try XCTUnwrap(SetupProbe.parse(probeJSON()))
        XCTAssertEqual(p.hardware.chip, "Apple M4 Pro")
        XCTAssertEqual(p.hardware.ramLabel, "64 GB")
        XCTAssertEqual(p.hardware.usableLabel, "51 GB usable")
        XCTAssertEqual(p.hardware.storageLabel, "420 GB free")
        XCTAssertTrue(p.deps.ollamaReady)
        XCTAssertEqual(p.deps.ollamaVersion, "0.30.8")
        XCTAssertEqual(p.recommendedDailyDriver, "qwen3:30b-a3b-instruct-2507-q4_K_M")
        XCTAssertEqual(p.recommendedModel?.id, "qwen3:30b-a3b-instruct-2507-q4_K_M")
        XCTAssertTrue(p.recommendedModel?.installed == true)
    }

    func testChatModelsExcludeEmbed() throws {
        let p = try XCTUnwrap(SetupProbe.parse(probeJSON()))
        // Embed model is filtered out of the daily-driver picker; both chat models remain.
        XCTAssertEqual(p.chatModels.count, 2)
        XCTAssertFalse(p.chatModels.contains { $0.role == "embed" })
    }

    func testFitAndSizeLabels() throws {
        let p = try XCTUnwrap(SetupProbe.parse(probeJSON()))
        let m8 = try XCTUnwrap(p.models.first { $0.id == "qwen3:8b" })
        XCTAssertEqual(m8.sizeLabel, "5.2 GB")
        XCTAssertTrue(m8.fitsAtAll)
        let embed = try XCTUnwrap(p.models.first { $0.id == "nomic-embed-text" })
        XCTAssertEqual(embed.sizeLabel, "300 MB")   // <1 GB shown in MB
    }

    func testRejectsMalformed() {
        XCTAssertNil(SetupProbe.parse([:]))
        XCTAssertNil(SetupProbe.parse(["hardware": [:]]))   // missing dependencies
    }
}
