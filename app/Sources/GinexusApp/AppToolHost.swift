// AppToolHost.swift (SP5) — a tiny UDS server hosted by the SIGNED app so the Rust core can run
// OS-attributed actions (Calendar / Shortcuts / system) with correct TCC attribution. The core
// advertises the tool schemas to the model and forwards execution here; EventKit/Shortcuts run in
// the notarized app, never the sidecar (the project's hard rule).
//
// Wire protocol (matches ginexus-agent::app_tools): newline-delimited JSON, connection-per-call:
//   →  {"token","tool","args"}\n      ←  {"ok":bool,"output":string}\n
import Foundation
import Darwin
import EventKit
import IOKit.ps

final class AppToolHost {
    let socketPath: String
    let token: String
    private var listenFD: Int32 = -1
    private var running = false
    private let store = EKEventStore()

    init(socketPath: String, token: String) {
        self.socketPath = socketPath
        self.token = token
    }

    func start() {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { NSLog("AppToolHost: socket() failed"); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        socketPath.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                    _ = strncpy(dst, cstr, cap - 1)
                }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else { NSLog("AppToolHost: bind failed errno=\(errno)"); close(fd); return }
        chmod(socketPath, 0o600)
        guard listen(fd, 8) == 0 else { NSLog("AppToolHost: listen failed"); close(fd); return }
        listenFD = fd
        running = true
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
        NSLog("AppToolHost listening at \(socketPath)")
    }

    func stop() {
        running = false
        if listenFD >= 0 { close(listenFD) }
        listenFD = -1
        unlink(socketPath)
    }

    private func acceptLoop() {
        while running {
            let conn = accept(listenFD, nil, nil)
            if conn < 0 { if running { usleep(20_000) }; continue }
            handle(conn)
            close(conn)
        }
    }

    private func handle(_ fd: Int32) {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if data.contains(0x0A) || data.count > 8_000_000 { break }
        }
        var reply = process(data)
        reply.append(0x0A)
        _ = reply.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    private func ok(_ s: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["ok": true, "output": s])) ?? Data("{\"ok\":true}".utf8)
    }
    private func fail(_ s: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["ok": false, "output": s])) ?? Data("{\"ok\":false}".utf8)
    }

    private func process(_ data: Data) -> Data {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tk = obj["token"] as? String, constantTimeEqual(tk, token),
              let tool = obj["tool"] as? String else { return fail("unauthorized or malformed") }
        let args = obj["args"] as? [String: Any] ?? [:]
        switch tool {
        case "system_status":   return ok(systemStatus())
        case "calendar_list":   return calendarList(days: (args["days"] as? Int) ?? 1)
        case "calendar_create": return calendarCreate(args)
        case "shortcuts_list":  return shortcutsList()
        case "shortcuts_run":   return shortcutsRun(args)
        default:                return fail("unknown tool '\(tool)'")
        }
    }

    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        if x.count != y.count { return false }
        var r: UInt8 = 0
        for i in 0..<x.count { r |= x[i] ^ y[i] }
        return r == 0
    }

    // MARK: - handlers

    private func systemStatus() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let up = Int(ProcessInfo.processInfo.systemUptime); let h = up / 3600, m = (up % 3600) / 60
        let appearance = (UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark") ? "dark" : "light"
        let batt = batteryPercent().map { "\($0)%" } ?? "n/a (desktop)"
        return "macOS \(os); battery \(batt); appearance \(appearance); uptime \(h)h\(m)m"
    }

    private func batteryPercent() -> Int? {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for s in list {
            if let d = IOPSGetPowerSourceDescription(snap, s)?.takeUnretainedValue() as? [String: Any],
               let cur = d[kIOPSCurrentCapacityKey] as? Int, let mx = d[kIOPSMaxCapacityKey] as? Int, mx > 0 {
                return Int((Double(cur) / Double(mx)) * 100.0)
            }
        }
        return nil
    }

    /// Blocking EventKit authorization (runs on the host's background thread).
    private func ekAuthorized() -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var granted = false
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { g, _ in granted = g; sem.signal() }
        } else {
            store.requestAccess(to: .event) { g, _ in granted = g; sem.signal() }
        }
        _ = sem.wait(timeout: .now() + 60)
        return granted
    }

    private func calendarList(days: Int) -> Data {
        guard ekAuthorized() else {
            return fail("calendar access not granted — approve the macOS prompt for GINEXUS, then retry")
        }
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: max(1, days), to: start)!
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
        if events.isEmpty { return ok("No events in the next \(max(1, days)) day(s).") }
        let df = DateFormatter(); df.dateFormat = "EEE MMM d HH:mm"
        return ok(events.prefix(25).map { "• \(df.string(from: $0.startDate)) — \($0.title ?? "(untitled)")" }
            .joined(separator: "\n"))
    }

    private func calendarCreate(_ a: [String: Any]) -> Data {
        guard ekAuthorized() else { return fail("calendar access not granted") }
        guard let title = a["title"] as? String, let startStr = a["start"] as? String else {
            return fail("title and start required")
        }
        guard let start = parseDate(startStr) else {
            return fail("bad 'start' — use ISO-8601 like 2026-06-20T14:00:00")
        }
        let ev = EKEvent(eventStore: store)
        ev.title = title
        ev.startDate = start
        ev.endDate = (a["end"] as? String).flatMap(parseDate) ?? start.addingTimeInterval(3600)
        ev.notes = a["notes"] as? String
        ev.calendar = store.defaultCalendarForNewEvents
        do { try store.save(ev, span: .thisEvent); return ok("Created '\(title)'.") }
        catch { return fail("save failed: \(error.localizedDescription)") }
    }

    private func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; df.timeZone = .current
        return df.date(from: s)
    }

    private func shortcutsList() -> Data {
        let r = run("/usr/bin/shortcuts", ["list"])
        return r.code == 0 ? ok(r.out.isEmpty ? "(no shortcuts installed)" : r.out)
                           : fail("shortcuts list failed: \(r.out)")
    }

    private func shortcutsRun(_ a: [String: Any]) -> Data {
        guard let name = a["name"] as? String, !name.isEmpty else { return fail("'name' required") }
        let r = run("/usr/bin/shortcuts", ["run", name])
        return r.code == 0 ? ok("Ran '\(name)'.\(r.out.isEmpty ? "" : " " + r.out)")
                           : fail("run failed: \(r.out)")
    }

    private func run(_ path: String, _ args: [String]) -> (code: Int32, out: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        p.waitUntilExit()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}
