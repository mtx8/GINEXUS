import Testing
import Foundation
@testable import GinexusCore

@Suite struct UDSClientTests {

    @Test func connectFailureOnMissingSocket() {
        let r = UDSClient.request(socketPath: "/tmp/ginexus-absent-\(UUID().uuidString).sock", path: "/healthz")
        guard case .failure(.connect) = r else {
            Issue.record("expected .connect failure for a missing socket")
            return
        }
    }

    @Test func roundTripAgainstLocalUDSServer() throws {
        // Stand up a tiny UDS HTTP server that returns a canned 200, then drive UDSClient at it.
        let path = NSTemporaryDirectory() + "ginexus-test-\(UUID().uuidString).sock"
        unlink(path)
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(server >= 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { t in
            t.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                path.withCString { strncpy(dst, $0, cap - 1) }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let b = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, len) }
        }
        #expect(b == 0)
        #expect(listen(server, 1) == 0)

        let body = #"{"status":"ready","models_loaded":[]}"#
        Thread.detachNewThread {
            let client = accept(server, nil, nil)
            if client >= 0 {
                var tmp = [UInt8](repeating: 0, count: 1024)
                _ = read(client, &tmp, tmp.count)  // drain request
                let resp = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                _ = Array(resp.utf8).withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                close(client)
            }
        }

        let r = UDSClient.request(socketPath: path, path: "/healthz")
        unlink(path); close(server)
        guard case .success(let resp) = r else {
            Issue.record("expected success")
            return
        }
        #expect(resp.status == 200)
        #expect(resp.body.contains("\"status\":\"ready\""))
    }
}
