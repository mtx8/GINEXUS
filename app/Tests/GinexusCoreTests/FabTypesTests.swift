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

    func testModelReportParsesAndDerives() throws {
        let json = """
        {"file":"~/parts/bracket.stl","triangles":12,"vertices":8,"watertight":true,
         "boundary_edges":0,"non_manifold_edges":0,"bbox_mm":[10,10,10],"volume_mm3":1000,
         "surface_area_mm2":600,"overhang_area_fraction":0.1667,
         "notes":["watertight manifold solid — sliceable"]}
        """
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let r = try XCTUnwrap(FabModelReport.parse(o))
        XCTAssertTrue(r.watertight)
        XCTAssertTrue(r.passes)
        XCTAssertEqual(r.volumeCM3, 1.0, accuracy: 0.0001)   // 1000 mm³ = 1 cm³
        XCTAssertEqual(r.dims, "10.0 × 10.0 × 10.0 mm")
        XCTAssertEqual(r.triangles, 12)
        // A non-solid model fails the gate.
        var bad = o; bad["watertight"] = false; bad["volume_mm3"] = 0
        let r2 = try XCTUnwrap(FabModelReport.parse(bad))
        XCTAssertFalse(r2.passes)
        XCTAssertNil(FabModelReport.parse([:]))
    }

    func testCameraParse() {
        let mjpeg = FabCamera.parse(["kind": "mjpeg_url", "url": "http://x/stream"])
        XCTAssertTrue(mjpeg.hasStream)
        let none = FabCamera.parse(["kind": "none", "url": ""])
        XCTAssertFalse(none.hasStream)
        XCTAssertFalse(FabCamera.parse([:]).hasStream)
    }

    func testETAGrammar() {
        XCTAssertEqual(fabETA(45), "45s")
        XCTAssertEqual(fabETA(60), "1m")
        XCTAssertEqual(fabETA(59 * 60), "59m")
        XCTAssertEqual(fabETA(8040), "2h 14m")
        XCTAssertEqual(fabETA(3600), "1h 0m")
    }

    func testDurationGrammarWithSeconds() {
        XCTAssertEqual(fabETADuration(45), "45s")
        XCTAssertEqual(fabETADuration(63), "1m 03s")
        XCTAssertEqual(fabETADuration(8040), "2h 14m 00s")
        XCTAssertEqual(fabETADuration(3661), "1h 01m 01s")
    }

    func testRelativeTime() {
        let now = Date(timeIntervalSince1970: 10_000)
        let ms = { (secsAgo: Double) -> Int64 in Int64((10_000 - secsAgo) * 1000) }
        XCTAssertEqual(fabRelTime(ms(3), now: now), "just now")
        XCTAssertEqual(fabRelTime(ms(30), now: now), "30s ago")
        XCTAssertEqual(fabRelTime(ms(120), now: now), "2m ago")
        XCTAssertEqual(fabRelTime(ms(7200), now: now), "2h ago")
        XCTAssertEqual(fabRelTime(0, now: now), "—")
    }
}
