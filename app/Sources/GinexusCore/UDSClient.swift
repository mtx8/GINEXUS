// UDSClient.swift — minimal HTTP/1.1-over-Unix-Domain-Socket client (SP2).
//
// The GINEXUS app talks to the hardened MTX-NEXUS sidecar over its 0600 UDS + bearer token
// (ADR 0002). URLSession can't dial a UDS, so this is a small POSIX-socket HTTP client:
// connect AF_UNIX → write request → read until close → parse status + body. Synchronous;
// callers run it off the main thread.
import Foundation

public struct UDSResponse: Sendable {
    public let status: Int
    public let body: String
}

public enum UDSError: Error, Sendable {
    case socket(String)
    case connect(String)
    case io(String)
    case parse
}

public enum UDSClient {
    public static func request(
        socketPath: String,
        method: String = "GET",
        path: String = "/",
        token: String? = nil,
        jsonBody: Data? = nil
    ) -> Result<UDSResponse, UDSError> {
        let cap = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        if socketPath.utf8.count >= cap { return .failure(.connect("socket path too long")) }

        // Connect with retry: a freshly-bound UDS can momentarily ECONNREFUSED between
        // bind and the server's accept loop being ready (observed right at spine startup).
        var fd: Int32 = -1
        var lastErr = "connect failed"
        for _ in 0..<8 {
            let s = socket(AF_UNIX, SOCK_STREAM, 0)
            if s < 0 { return .failure(.socket(String(cString: strerror(errno)))) }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            _ = withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
                tuplePtr.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                    socketPath.withCString { src in strncpy(dst, src, cap - 1) }
                }
            }
            let len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let cr = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, len) }
            }
            if cr == 0 { fd = s; break }
            lastErr = String(cString: strerror(errno))
            close(s)
            usleep(200_000)  // 200ms backoff
        }
        if fd < 0 { return .failure(.connect(lastErr)) }
        defer { close(fd) }

        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
        if let token { head += "Authorization: Bearer \(token)\r\n" }
        if let jsonBody {
            head += "Content-Type: application/json\r\nContent-Length: \(jsonBody.count)\r\n"
        }
        head += "\r\n"
        var out = Data(head.utf8)
        if let jsonBody { out.append(jsonBody) }

        let wrote = out.withUnsafeBytes { raw -> Int in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { return -1 }
                sent += n
            }
            return sent
        }
        if wrote < 0 { return .failure(.io("write failed")) }

        var resp = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 { return .failure(.io("read failed")) }
            if n == 0 { break }
            resp.append(buf, count: n)
        }
        return parse(resp)
    }

    /// Streaming POST: connect, send the request, then parse the Server-Sent-Events body, invoking
    /// `onEvent(event, data)` for each frame as it arrives (blocks until the server closes). Runs
    /// synchronously — callers run it off the main thread and hop back to update UI per event.
    public static func stream(
        socketPath: String, path: String, token: String? = nil, jsonBody: Data? = nil,
        onEvent: @escaping (_ event: String, _ data: String) -> Void
    ) -> Result<Void, UDSError> {
        let cap = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        if socketPath.utf8.count >= cap { return .failure(.connect("socket path too long")) }

        var fd: Int32 = -1
        var lastErr = "connect failed"
        for _ in 0..<8 {
            let s = socket(AF_UNIX, SOCK_STREAM, 0)
            if s < 0 { return .failure(.socket(String(cString: strerror(errno)))) }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            _ = withUnsafeMutablePointer(to: &addr.sun_path) { tp in
                tp.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                    socketPath.withCString { strncpy(dst, $0, cap - 1) }
                }
            }
            let len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let cr = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, len) }
            }
            if cr == 0 { fd = s; break }
            lastErr = String(cString: strerror(errno))
            close(s); usleep(200_000)
        }
        if fd < 0 { return .failure(.connect(lastErr)) }
        defer { close(fd) }

        var head = "POST \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
        if let token { head += "Authorization: Bearer \(token)\r\n" }
        if let jsonBody { head += "Content-Type: application/json\r\nContent-Length: \(jsonBody.count)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        if let jsonBody { out.append(jsonBody) }
        let wrote = out.withUnsafeBytes { raw -> Int in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { return -1 }
                sent += n
            }
            return sent
        }
        if wrote < 0 { return .failure(.io("write failed")) }

        // Read + parse SSE: skip HTTP headers (to \r\n\r\n), then dispatch frames on blank lines.
        var raw = Data(), pending = Data()
        var headersDone = false
        var curEvent = "message", curData = ""
        var rbuf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &rbuf, rbuf.count)
            if n < 0 { return .failure(.io("read failed")) }
            if n == 0 { break }
            if !headersDone {
                raw.append(rbuf, count: n)
                if let r = raw.range(of: Data("\r\n\r\n".utf8)) {
                    headersDone = true
                    pending.append(raw.subdata(in: r.upperBound..<raw.endIndex))
                }
                continue
            }
            pending.append(rbuf, count: n)
            while let nl = pending.firstIndex(of: 0x0A) {
                let lineData = pending.subdata(in: pending.startIndex..<nl)
                pending.removeSubrange(pending.startIndex...nl)
                var line = String(data: lineData, encoding: .utf8) ?? ""
                if line.hasSuffix("\r") { line.removeLast() }
                if line.isEmpty {
                    if !curData.isEmpty || curEvent != "message" { onEvent(curEvent, curData) }
                    curEvent = "message"; curData = ""
                } else if line.hasPrefix("event:") {
                    curEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    let d = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    curData = curData.isEmpty ? d : curData + "\n" + d
                }
            }
        }
        return .success(())
    }

    private static func parse(_ data: Data) -> Result<UDSResponse, UDSError> {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return .failure(.parse) }
        let headerData = data.subdata(in: data.startIndex..<sep.lowerBound)
        let bodyData = data.subdata(in: sep.upperBound..<data.endIndex)
        guard let headerStr = String(data: headerData, encoding: .utf8),
              let statusLine = headerStr.split(separator: "\r\n").first else { return .failure(.parse) }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else { return .failure(.parse) }
        // Strip a chunked-transfer trailer if present (sidecar uses Connection: close, so this
        // is usually plain), best-effort decode to UTF-8.
        let body = String(data: bodyData, encoding: .utf8) ?? ""
        return .success(UDSResponse(status: code, body: body))
    }
}
