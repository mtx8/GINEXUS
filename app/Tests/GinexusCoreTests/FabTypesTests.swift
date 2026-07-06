// SP-FAB types: parsing of the core's /v1/fab/* payloads + the console's ETA grammar.
import XCTest
@testable import GinexusCore

final class FabTypesTests: XCTestCase {
    func testPrinterParsesFullPayload() throws {
        let json = """
        {"printer_id":"saturn-4-ultra","name":"Saturn 4 Ultra","kind":"sdcp",
         "host":"192.168.1.44","model":"ELEGOO Saturn 4 Ultra","state":"printing",
         "progress":0.42,"current_layer":210,"total_layers":500,"time_left_secs":8040,
         "job_name":"/local/bracket.goo","detail":"release film state 1"}
        """
        let o = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let p = try XCTUnwrap(FabPrinter.parse(o))
        XCTAssertEqual(p.id, "saturn-4-ultra")
        XCTAssertEqual(p.state, "printing")
        XCTAssertTrue(p.isActive)
        XCTAssertEqual(p.currentLayer, 210)
        XCTAssertEqual(p.totalLayers, 500)
        XCTAssertEqual(p.timeLeftSecs, 8040)
        XCTAssertEqual(p.progress ?? 0, 0.42, accuracy: 0.0001)
    }

    func testPrinterParsesMinimalAndRejectsEmpty() throws {
        let p = try XCTUnwrap(FabPrinter.parse(["printer_id": "m1"]))
        XCTAssertEqual(p.name, "m1")
        XCTAssertEqual(p.state, "unknown")
        XCTAssertFalse(p.isActive)
        XCTAssertNil(FabPrinter.parse([:]))
        XCTAssertNil(FabPrinter.parse(["printer_id": ""]))
    }

    func testJobParsesAndClearanceGate() throws {
        let o: [String: Any] = ["job_id": "job-1", "name": "bracket", "printer_id": "saturn",
                                "state": "complete", "sliced_path": "/x/bracket.goo",
                                "validation": "no issues reported", "updated_ms": 1_700_000]
        let j = try XCTUnwrap(FabJobItem.parse(o))
        XCTAssertTrue(j.awaitsClearance)   // finished plate blocks the next job until cleared
        var j2 = j
        j2.state = "printing"
        XCTAssertFalse(j2.awaitsClearance)
        XCTAssertNil(FabJobItem.parse([:]))
    }

    func testETAGrammar() {
        XCTAssertEqual(fabETA(45), "45s")
        XCTAssertEqual(fabETA(60), "1m")
        XCTAssertEqual(fabETA(59 * 60), "59m")
        XCTAssertEqual(fabETA(8040), "2h 14m")
        XCTAssertEqual(fabETA(3600), "1h 0m")
    }
}
