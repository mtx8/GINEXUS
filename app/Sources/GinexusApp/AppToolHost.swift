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
import PDFKit

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
        case "save_to_folder":  return saveToFolder(args)
        case "pages_write":     return pagesWrite(args)
        case "read_pdf_fields": return readPdfFields(args)
        case "fill_pdf_form":   return fillPdfForm(args)
        case "read_pdf_text":   return readPdfText(args)
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

    // MARK: - files (TCC-correct: writes originate in the signed app, not the core)

    /// Resolve one of the user's standard folders. macOS prompts once for access; attributed to GINEXUS.
    private func standardFolder(_ name: String) -> URL? {
        let dir: FileManager.SearchPathDirectory
        switch name.lowercased() {
        case "desktop": dir = .desktopDirectory
        case "documents": dir = .documentDirectory
        default: dir = .downloadsDirectory
        }
        return try? FileManager.default.url(for: dir, in: .userDomainMask, appropriateFor: nil, create: false)
    }

    /// `~`-relative display of a path (never leak the username).
    private func tildeShown(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func saveToFolder(_ a: [String: Any]) -> Data {
        guard let srcRaw = (a["src"] as? String), !srcRaw.isEmpty else { return fail("'src' required") }
        let src = (srcRaw as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: src) else { return fail("source file not found: \(tildeShown(src))") }
        guard let base = standardFolder((a["location"] as? String) ?? "downloads") else {
            return fail("could not resolve the destination folder")
        }
        let rawName = (a["filename"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (src as NSString).lastPathComponent
        let safe = (rawName as NSString).lastPathComponent   // single component, no traversal
        let dest = base.appendingPathComponent(safe)
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(atPath: src, toPath: dest.path)
        } catch {
            return fail("copy failed (grant GINEXUS access to the \(((a["location"] as? String) ?? "Downloads")) folder if macOS asks): \(error.localizedDescription)")
        }
        return ok("Saved to \(tildeShown(dest.path))")
    }

    private func stripMarkdown(_ s: String) -> String {
        s.components(separatedBy: "\n").map { line -> String in
            var t = line.trimmingCharacters(in: .whitespaces)
            if t == "---" || t == "***" || t == "___" { return "" }
            if let r = t.range(of: "^#{1,6}\\s+", options: .regularExpression) { t.removeSubrange(r) }
            if let r = t.range(of: "^[-*+]\\s+", options: .regularExpression) { t.replaceSubrange(r, with: "•  ") }
            t = t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            t = t.replacingOccurrences(of: "`", with: "")
            return t
        }.joined(separator: "\n")
    }

    private func pagesWrite(_ a: [String: Any]) -> Data {
        guard let content = a["content"] as? String, !content.isEmpty else { return fail("'content' required") }
        let title = (a["title"] as? String) ?? ""
        let fmt = ((a["format"] as? String) ?? "pdf").lowercased()
        let ext = (fmt == "docx" || fmt == "word") ? "docx" : (fmt == "pages" ? "pages" : "pdf")
        guard let base = standardFolder((a["location"] as? String) ?? "downloads") else {
            return fail("could not resolve the destination folder")
        }
        let stem = ((((a["filename"] as? String) ?? "document") as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        let dest = base.appendingPathComponent("\(stem.isEmpty ? "document" : stem).\(ext)")

        // Body via a temp UTF-8 file → avoids AppleScript string-escaping of multi-line content.
        let body = (title.isEmpty ? "" : title + "\n\n") + stripMarkdown(content)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gx-pages-\(UUID().uuidString).txt")
        guard (try? body.data(using: .utf8)?.write(to: tmp)) != nil else { return fail("temp write failed") }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let setBody = "set body text of d to (read (POSIX file \"\(tmp.path)\") as «class utf8»)"
        let finish: String
        if ext == "pages" {
            finish = "save d in (POSIX file \"\(dest.path)\")"
        } else {
            let asFmt = ext == "docx" ? "Microsoft Word" : "PDF"
            finish = "export d to (POSIX file \"\(dest.path)\") as \(asFmt)"
        }
        let script = """
        tell application "Pages"
            set d to make new document
            \(setBody)
            \(finish)
            close d saving no
        end tell
        """
        let r = run("/usr/bin/osascript", ["-e", script])
        if r.code != 0 {
            return fail("Pages export failed — make sure Pages is installed and allow GINEXUS to control it if macOS asks. \(r.out)")
        }
        return ok("Created in Apple Pages and saved to \(tildeShown(dest.path))")
    }

    // MARK: - PDF forms (SP-Docs Flow B — native PDFKit, TCC-correct, never iCloud)

    private enum PDFOpen { case ok(PDFDocument, String); case err(Data) }

    /// Open a PDF and resolve its source path, refusing iCloud + missing files. Shared by both PDF tools.
    private func openPDF(_ a: [String: Any]) -> PDFOpen {
        guard let srcRaw = (a["src"] as? String), !srcRaw.isEmpty else { return .err(fail("'src' required")) }
        let src = SpineController.canonical((srcRaw as NSString).expandingTildeInPath)
        if SpineController.isICloudPath(src) {
            return .err(fail("refusing to touch iCloud (\(tildeShown(src))) — move the PDF to a local folder like ~/GINEXUS-Docs"))
        }
        guard FileManager.default.fileExists(atPath: src) else { return .err(fail("PDF not found: \(tildeShown(src))")) }
        guard let doc = PDFDocument(url: URL(fileURLWithPath: src)) else { return .err(fail("could not open PDF (corrupt or encrypted): \(tildeShown(src))")) }
        return .ok(doc, src)
    }

    private func fieldTypeName(_ t: PDFAnnotationWidgetSubtype) -> String {
        switch t {
        case .text: return "text"
        case .button: return "button"
        case .choice: return "choice"
        case .signature: return "signature"
        default: return "unknown"
        }
    }

    /// List the fillable AcroForm fields so the agent can map the user's data to them.
    private func readPdfFields(_ a: [String: Any]) -> Data {
        let doc: PDFDocument, src: String
        switch openPDF(a) { case .err(let e): return e; case .ok(let d, let s): doc = d; src = s }

        var fields: [[String: Any]] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for ann in page.annotations where ann.fieldName != nil {
                var f: [String: Any] = [
                    "name": ann.fieldName ?? "",
                    "type": fieldTypeName(ann.widgetFieldType),
                    "page": i,
                    "value": ann.widgetStringValue ?? "",
                ]
                if let choices = ann.choices, !choices.isEmpty { f["options"] = choices }
                fields.append(f)
            }
        }
        if fields.isEmpty {
            return ok("This PDF has no fillable AcroForm fields — it may be a flat/scanned PDF or an XFA form, which can't be filled in place. (\(tildeShown(src)))")
        }
        let payload: [String: Any] = ["path": tildeShown(src), "field_count": fields.count, "fields": fields]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return fail("could not encode fields") }
        return ok(json)
    }

    /// Extract a PDF's text (read_document's PDF path runs through here for TCC-correct file access).
    private func readPdfText(_ a: [String: Any]) -> Data {
        let doc: PDFDocument
        switch openPDF(a) { case .err(let e): return e; case .ok(let d, _): doc = d }
        let text = doc.string ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ok("(no extractable text — this PDF is likely scanned images)")
        }
        return ok(text)
    }

    private static let truthy: Set<String> = ["on", "true", "yes", "y", "x", "1", "checked", "✓"]

    /// Fill an existing AcroForm PDF in place (default) with an automatic timestamped backup, or to a
    /// new copy when `new_copy` is set. `fields` is { fieldName: value }.
    private func fillPdfForm(_ a: [String: Any]) -> Data {
        let doc: PDFDocument, src: String
        switch openPDF(a) { case .err(let e): return e; case .ok(let d, let s): doc = d; src = s }
        guard let fields = a["fields"] as? [String: Any], !fields.isEmpty else { return fail("'fields' object required ({fieldName: value})") }

        // Index widgets by field name.
        var widgets: [String: PDFAnnotation] = [:]
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for ann in page.annotations { if let n = ann.fieldName { widgets[n] = ann } }
        }
        if widgets.isEmpty { return fail("no AcroForm fields to fill (flat/scanned or XFA PDF): \(tildeShown(src))") }

        var filled: [String] = []
        var missing: [String] = []
        for (name, raw) in fields {
            guard let ann = widgets[name] else { missing.append(name); continue }
            let value = "\(raw)"
            if ann.widgetFieldType == .button {
                let on = Self.truthy.contains(value.lowercased())
                ann.buttonWidgetState = on ? .onState : .offState
                if on, ann.buttonWidgetStateString.isEmpty == false { /* keep export state */ }
                // For radio groups the value may be an export name rather than a boolean.
                if !on && !Self.truthy.contains(value.lowercased()) { ann.widgetStringValue = value }
            } else {
                ann.widgetStringValue = value
            }
            filled.append(name)
        }

        // Destination: in place (with backup) by default, or a new "-filled.pdf" copy.
        let newCopy = (a["new_copy"] as? Bool) ?? false
        let destPath: String
        if newCopy {
            let url = URL(fileURLWithPath: src)
            let stem = url.deletingPathExtension().lastPathComponent
            destPath = url.deletingLastPathComponent().appendingPathComponent("\(stem)-filled.pdf").path
        } else {
            if let backup = backupPath(for: src) {
                try? FileManager.default.copyItem(atPath: src, toPath: backup)
            }
            destPath = src
        }
        guard doc.write(to: URL(fileURLWithPath: destPath)) else {
            return fail("failed to write the filled PDF (grant GINEXUS access to that folder if macOS asks)")
        }
        var msg = "Filled \(filled.count) field(s) → \(tildeShown(destPath))."
        if !newCopy { msg += " Original backed up." }
        if !missing.isEmpty { msg += " Not found in the form: \(missing.sorted().joined(separator: ", "))." }
        return ok(msg)
    }

    /// Timestamped backup path under App Support so an in-place fill is always reversible.
    private func backupPath(for src: String) -> String? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GINEXUS/backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        let stem = (src as NSString).lastPathComponent
        return base.appendingPathComponent("\(df.string(from: Date()))-\(stem)").path
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
