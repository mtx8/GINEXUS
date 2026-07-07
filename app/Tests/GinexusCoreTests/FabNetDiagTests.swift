// Reachability diagnosis — the pure classification + subnet logic behind the add-printer verdicts.
import XCTest
@testable import GinexusCore

final class FabNetDiagTests: XCTestCase {
    func testControlPorts() {
        XCTAssertEqual(FabNetDiag.controlPort(for: "sdcp"), 3030)
        XCTAssertEqual(FabNetDiag.controlPort(for: "octoprint"), 80)
        XCTAssertEqual(FabNetDiag.controlPort(for: "moonraker"), 7125)
    }

    func testHotspotDetection() {
        XCTAssertTrue(FabNetDiag.isHotspotIP("172.20.10.2"))
        XCTAssertFalse(FabNetDiag.isHotspotIP("192.168.1.44"))
    }

    func testSameSubnet() {
        XCTAssertEqual(FabNetDiag.sameSubnet("172.20.10.2", "172.20.10.3", prefix: 28), true)
        XCTAssertEqual(FabNetDiag.sameSubnet("172.20.10.2", "192.168.1.44", prefix: 28), false)
        XCTAssertEqual(FabNetDiag.sameSubnet("192.168.1.10", "192.168.1.200", prefix: 24), true)
        XCTAssertNil(FabNetDiag.sameSubnet("nope", "192.168.1.1", prefix: 24))
    }

    func testDiagnoseHotspotIsTheHeadline() {
        // The exact situation from the field report: on an iPhone hotspot, an unreachable printer.
        let local = LocalNet(ip: "172.20.10.2", prefix: 28, isHotspot: true)
        let d = FabNetDiag.diagnose(host: "172.20.10.3", kind: "sdcp", result: .timedOut, local: local)
        XCTAssertEqual(d.severity, "error")
        XCTAssertFalse(d.reachable)
        XCTAssertTrue(d.summary.contains("Personal Hotspot"))
        XCTAssertTrue(d.detail.contains("same Wi"))
    }

    func testDiagnoseDifferentSubnet() {
        let local = LocalNet(ip: "192.168.1.5", prefix: 24, isHotspot: false)
        let d = FabNetDiag.diagnose(host: "10.0.0.9", kind: "sdcp", result: .unreachable, local: local)
        XCTAssertEqual(d.severity, "error")
        XCTAssertTrue(d.summary.contains("different network"))
    }

    func testDiagnoseReachableAndRefused() {
        let ok = FabNetDiag.diagnose(host: "192.168.1.44", kind: "sdcp", result: .open, local: nil)
        XCTAssertEqual(ok.severity, "ok")
        XCTAssertTrue(ok.reachable)

        let refused = FabNetDiag.diagnose(host: "192.168.1.1", kind: "sdcp", result: .refused, local: nil)
        XCTAssertEqual(refused.severity, "warn")
        XCTAssertFalse(refused.reachable)
        XCTAssertTrue(refused.summary.contains("not a Elegoo/SDCP") || refused.summary.contains("port 3030"))
    }

    func testDiagnoseGenericUnreachableGivesPermissionHint() {
        let local = LocalNet(ip: "192.168.1.5", prefix: 24, isHotspot: false)
        let d = FabNetDiag.diagnose(host: "192.168.1.99", kind: "sdcp", result: .timedOut, local: local)
        XCTAssertEqual(d.severity, "error")
        XCTAssertTrue(d.detail.contains("Local Network"))
    }
}
