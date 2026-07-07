// FabNetDiag.swift — network reachability diagnostics for the Fabrication add-printer flow.
// Runs IN THE SIGNED APP process (not the child core), which (a) holds the macOS Local Network
// TCC grant and triggers its prompt, and (b) lets us tell the user EXACTLY why a printer can't be
// reached instead of silently adding an offline device. The heavy protocol logic stays in the
// Rust core; this is only "can I even reach this host, and if not, why."
import Foundation

/// Outcome of a TCP reachability probe to a printer's control port.
public enum ReachResult: Equatable, Sendable {
    case open          // TCP connected — the port is answering
    case refused       // host is up but the port is closed (ECONNREFUSED)
    case timedOut      // no response — host down, filtered, or network-isolated
    case unreachable   // no route to host / network (EHOSTUNREACH / ENETUNREACH)
    case dnsFailed     // name didn't resolve
    case failed(String)
}

/// The Mac's primary IPv4 network context.
public struct LocalNet: Equatable, Sendable {
    public let ip: String
    public let prefix: Int          // CIDR prefix length (e.g. 28)
    public let isHotspot: Bool      // iPhone Personal Hotspot (always 172.20.10.0/28)
    public init(ip: String, prefix: Int, isHotspot: Bool) {
        self.ip = ip; self.prefix = prefix; self.isHotspot = isHotspot
    }
    public var cidr: String { "\(ip)/\(prefix)" }
}

/// A user-facing diagnosis of an add-printer connection attempt.
public struct FabDiagnosis: Equatable, Sendable {
    public let severity: String   // "ok" | "warn" | "error"
    public let summary: String
    public let detail: String
    public let reachable: Bool    // control port answered
    public init(severity: String, summary: String, detail: String, reachable: Bool) {
        self.severity = severity; self.summary = summary; self.detail = detail; self.reachable = reachable
    }
}

public enum FabNetDiag {
    /// The primary control port for a printer kind (what "reachable" means for it).
    public static func controlPort(for kind: String) -> UInt16 {
        switch kind {
        case "sdcp": return 3030          // Elegoo/Chitu SDCP WebSocket
        case "octoprint": return 80       // OctoPrint web (5000 on some rigs)
        case "moonraker": return 7125      // Moonraker HTTP
        default: return 80
        }
    }

    /// True when an IPv4 string looks like the iPhone Personal Hotspot subnet (172.20.10.0/28).
    public static func isHotspotIP(_ ip: String) -> Bool { ip.hasPrefix("172.20.10.") }

    /// Whether two IPv4 addresses share the same /prefix subnet. nil if either can't be parsed.
    public static func sameSubnet(_ a: String, _ b: String, prefix: Int) -> Bool? {
        guard let ua = ipv4ToUInt32(a), let ub = ipv4ToUInt32(b), (0...32).contains(prefix) else { return nil }
        if prefix == 0 { return true }
        let mask: UInt32 = prefix == 32 ? .max : ~(UInt32.max >> UInt32(prefix))
        return (ua & mask) == (ub & mask)
    }

    static func ipv4ToUInt32(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard let n = UInt32(p), n <= 255 else { return nil }
            v = (v << 8) | n
        }
        return v
    }

    /// The Mac's primary active IPv4 interface (prefers en0/en1), or nil.
    public static func localNet() -> LocalNet? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }
        var candidates: [(name: String, ln: LocalNet)] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let ifa = p.pointee
            let name = String(cString: ifa.ifa_name)
            let flags = Int32(ifa.ifa_flags)
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0, name.hasPrefix("en") {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: host)
                var prefix = 24
                if let nm = ifa.ifa_netmask {
                    prefix = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { Int($0.pointee.sin_addr.s_addr.nonzeroBitCount) }
                }
                if !ip.isEmpty && ip != "0.0.0.0" {
                    candidates.append((name, LocalNet(ip: ip, prefix: prefix, isHotspot: isHotspotIP(ip))))
                }
            }
            ptr = ifa.ifa_next
        }
        // Prefer en0, then en1, then any.
        return candidates.first { $0.name == "en0" }?.ln
            ?? candidates.first { $0.name == "en1" }?.ln
            ?? candidates.first?.ln
    }

    /// Non-blocking TCP reachability probe with a timeout (runs in the app → triggers the macOS
    /// Local Network prompt and holds its grant).
    public static func reach(host: String, port: UInt16, timeoutMs: Int32 = 2500) -> ReachResult {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else { return .dnsFailed }
        defer { freeaddrinfo(res) }
        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        if fd < 0 { return .failed("socket") }
        defer { close(fd) }
        let fl = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK)
        let cr = connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
        if cr == 0 { return .open }
        if errno != EINPROGRESS { return classify(errno) }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pr = poll(&pfd, 1, timeoutMs)
        if pr == 0 { return .timedOut }
        if pr < 0 { return .failed("poll") }
        var soErr: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
        return soErr == 0 ? .open : classify(soErr)
    }

    private static func classify(_ err: Int32) -> ReachResult {
        switch err {
        case ECONNREFUSED: return .refused
        case EHOSTUNREACH, ENETUNREACH, EHOSTDOWN: return .unreachable
        case ETIMEDOUT: return .timedOut
        default: return .failed(String(cString: strerror(err)))
        }
    }

    /// Turn a probe result + network context into a clear, actionable verdict. Pure (unit-tested).
    public static func diagnose(host: String, kind: String, result: ReachResult, local: LocalNet?) -> FabDiagnosis {
        let port = controlPort(for: kind)
        let kindName = displayKind(kind)
        switch result {
        case .open:
            return FabDiagnosis(severity: "ok",
                summary: "Reachable — port \(port) is answering.",
                detail: "\(host) responded on the \(kindName) port. Add it and GINEXUS will connect.",
                reachable: true)
        case .refused:
            return FabDiagnosis(severity: "warn",
                summary: "Host is up, but not a \(kindName) printer on port \(port).",
                detail: "\(host) is reachable but refused port \(port). Check that you picked the right printer type, that the printer's network/LAN control is enabled, and that the IP is the printer (not your router or phone).",
                reachable: false)
        case .dnsFailed:
            return FabDiagnosis(severity: "error",
                summary: "Couldn't resolve \(host).",
                detail: "Use the printer's IP address (e.g. 192.168.1.44) or a valid name ending in .local.",
                reachable: false)
        case .timedOut, .unreachable, .failed:
            // Unreachable — the interesting case. Use the network context to explain WHY.
            if let l = local, l.isHotspot {
                return FabDiagnosis(severity: "error",
                    summary: "Can't reach \(host) — you're on an iPhone Personal Hotspot.",
                    detail: "Your Mac is on a Personal Hotspot (\(l.cidr)), which isolates devices so they can't see each other. Connect BOTH your Mac and the printer to the same Wi‑Fi router, then try again.",
                    reachable: false)
            }
            if let l = local, sameSubnet(host, l.ip, prefix: l.prefix) == false {
                return FabDiagnosis(severity: "error",
                    summary: "\(host) is on a different network than your Mac.",
                    detail: "Your Mac is on \(l.cidr). The printer's IP isn't on that network — put both on the same Wi‑Fi, or use the printer's actual IP from its screen (Settings › Network).",
                    reachable: false)
            }
            return FabDiagnosis(severity: "error",
                summary: "Couldn't reach \(host) on port \(port).",
                detail: "Check that: the printer is powered on and on this Wi‑Fi; the IP is correct (see the printer's Network screen); and GINEXUS has Local Network access (System Settings › Privacy & Security › Local Network › GINEXUS).",
                reachable: false)
        }
    }

    public static func displayKind(_ kind: String) -> String {
        switch kind {
        case "sdcp": return "Elegoo/SDCP"
        case "octoprint": return "OctoPrint"
        case "moonraker": return "Moonraker"
        case "mock": return "Mock"
        default: return kind
        }
    }
}
