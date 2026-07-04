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
import GinexusCore

final class AppToolHost {
    let socketPath: String
    let token: String
    private var listenFD: Int32 = -1
    private var running = false
    private let store = EKEventStore()

    /// W1 session_search: read-only view of the app's persisted transcripts (same on-disk store the
    /// sidebar uses; a second instance is safe — reads see atomically-written files).
    private let convStore: ConversationStoring = DiskConversationStore()
    /// W1: how the host learns which conversation is ACTIVE (excluded from discovery — it is already
    /// in context). Set on the main actor BEFORE start(); the handler reads it via a main-queue hop.
    var activeConversationProvider: (@MainActor () -> UUID?)?

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
        case "list_folder":     return listFolder(args)
        case "find_file":       return findFile(args)
        case "read_docx_text":  return readDocxText(args)
        case "fill_docx":       return fillDocx(args)
        case "mcp_list":        return mcpList()
        case "connect_mcp":     return connectMcp(args)
        case "session_search":  return sessionSearch(args)
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

    // MARK: - Folders & Word documents (native, TCC-correct, never iCloud, no third-party code)

    /// Expand `~` and treat a bare relative path as relative to the user's home, then canonicalize.
    private func resolveUserPath(_ raw: String) -> String {
        var p = (raw as NSString).expandingTildeInPath
        if !p.hasPrefix("/") { p = (NSHomeDirectory() as NSString).appendingPathComponent(p) }
        return SpineController.canonical(p)
    }

    /// List a user folder (e.g. ~/Documents/MSR): names, kinds, and sizes so the agent can find a file.
    private func listFolder(_ a: [String: Any]) -> Data {
        guard let raw = (a["path"] as? String), !raw.isEmpty else { return fail("'path' required (e.g. ~/Documents/MSR)") }
        let dir = resolveUserPath(raw)
        if SpineController.isICloudPath(dir) { return fail("refusing to read iCloud (\(tildeShown(dir))). Use a local folder.") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return fail("folder not found: \(tildeShown(dir))")
        }
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        var entries: [[String: Any]] = []
        for name in items.sorted() where !name.hasPrefix(".") {
            let full = (dir as NSString).appendingPathComponent(name)
            var d: ObjCBool = false
            FileManager.default.fileExists(atPath: full, isDirectory: &d)
            let size = (try? FileManager.default.attributesOfItem(atPath: full)[.size] as? Int) ?? nil
            entries.append(["name": name, "kind": d.boolValue ? "folder" : "file", "size": size ?? 0])
        }
        let payload: [String: Any] = ["path": tildeShown(dir), "count": entries.count, "items": entries]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return fail("could not encode listing") }
        return ok(json)
    }

    /// Find files by name (case-insensitive substring) under a base folder, or under the common user
    /// folders (Documents / Desktop / Downloads) when no base is given. Skips hidden + Library; caps results.
    private func findFile(_ a: [String: Any]) -> Data {
        guard let needle = (a["name"] as? String)?.lowercased(), !needle.isEmpty else { return fail("'name' required") }
        let bases: [String]
        if let b = a["base"] as? String, !b.isEmpty {
            bases = [resolveUserPath(b)]
        } else {
            let home = NSHomeDirectory()
            bases = ["Documents", "Desktop", "Downloads"].map { (home as NSString).appendingPathComponent($0) }
        }
        var matches: [String] = []
        let fm = FileManager.default
        outer: for base in bases {
            if SpineController.isICloudPath(base) { continue }
            guard let en = fm.enumerator(at: URL(fileURLWithPath: base),
                                         includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            var scanned = 0
            for case let url as URL in en {
                scanned += 1
                if scanned > 6000 { break }                    // bound the walk
                if url.path.contains("/Library/") { en.skipDescendants(); continue }
                if url.lastPathComponent.lowercased().contains(needle),
                   (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                   !SpineController.isICloudPath(url.path) {
                    matches.append(tildeShown(url.path))
                    if matches.count >= 25 { break outer }
                }
            }
        }
        let payload: [String: Any] = ["query": needle, "count": matches.count, "matches": matches]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return fail("could not encode results") }
        return ok(matches.isEmpty ? "No files matching “\(needle)” under \(bases.map { tildeShown($0) }.joined(separator: ", "))." : json)
    }

    private enum DocxSrc { case ok(String); case err(Data) }

    /// Resolve a .docx source path (expand ~, refuse iCloud, must exist + be a .docx).
    private func resolveDocx(_ a: [String: Any]) -> DocxSrc {
        guard let raw = (a["src"] as? String), !raw.isEmpty else { return .err(fail("'src' required")) }
        let src = resolveUserPath(raw)
        if SpineController.isICloudPath(src) { return .err(fail("refusing to touch iCloud (\(tildeShown(src))).")) }
        guard FileManager.default.fileExists(atPath: src) else { return .err(fail("file not found: \(tildeShown(src))")) }
        guard src.lowercased().hasSuffix(".docx") else { return .err(fail("not a .docx file: \(tildeShown(src)). (Legacy .doc isn't supported — save as .docx.)")) }
        return .ok(src)
    }

    /// Read a Word .docx's text by extracting word/document.xml (system unzip) and stripping tags.
    private func readDocxText(_ a: [String: Any]) -> Data {
        let src: String
        switch resolveDocx(a) { case .err(let e): return e; case .ok(let s): src = s }
        let r = run("/usr/bin/unzip", ["-p", src, "word/document.xml"])
        guard r.code == 0, !r.out.isEmpty else { return fail("could not read .docx (corrupt or not a Word file): \(tildeShown(src))") }
        let text = Self.docxXmlToText(r.out)
        return ok(text.isEmpty ? "(no extractable text)" : text)
    }

    /// Turn word/document.xml into readable text: paragraphs → newlines, tabs honored, tags stripped,
    /// XML entities decoded. Good enough for the agent to see placeholders/fields it needs to fill.
    private static func docxXmlToText(_ xml: String) -> String {
        var s = xml
        s = s.replacingOccurrences(of: "</w:p>", with: "\n")
        s = s.replacingOccurrences(of: "<w:tab/>", with: "\t")
        s = s.replacingOccurrences(of: "<w:br/>", with: "\n")
        // strip all remaining tags
        var out = "", inTag = false
        for c in s { if c == "<" { inTag = true } else if c == ">" { inTag = false } else if !inTag { out.append(c) } }
        out = out.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
        return out.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Fill an existing Word .docx by replacing literal text in word/document.xml — duplicate to a named
    /// copy (out_name) or `-filled.docx` (new_copy), or edit in place with a timestamped backup.
    /// `replacements` = { findText: replaceWith }. WRITE action (HITL-gated by the host).
    private func fillDocx(_ a: [String: Any]) -> Data {
        let src: String
        switch resolveDocx(a) { case .err(let e): return e; case .ok(let s): src = s }
        guard let repl = a["replacements"] as? [String: Any], !repl.isEmpty else {
            return fail("'replacements' object required ({ \"find text\": \"replace with\" })")
        }
        let dir = (src as NSString).deletingLastPathComponent
        let stem = ((src as NSString).lastPathComponent as NSString).deletingPathExtension
        let fm = FileManager.default

        // Decide destination.
        let dest: String
        if let outName = (a["out_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !outName.isEmpty {
            let safe = outName.replacingOccurrences(of: "/", with: "-")
            let name = safe.lowercased().hasSuffix(".docx") ? safe : safe + ".docx"
            dest = (dir as NSString).appendingPathComponent(name)
            try? fm.removeItem(atPath: dest)
            do { try fm.copyItem(atPath: src, toPath: dest) } catch { return fail("could not create copy: \(error.localizedDescription)") }
        } else if (a["new_copy"] as? Bool) == true {
            dest = (dir as NSString).appendingPathComponent("\(stem)-filled.docx")
            try? fm.removeItem(atPath: dest)
            do { try fm.copyItem(atPath: src, toPath: dest) } catch { return fail("could not create copy: \(error.localizedDescription)") }
        } else {
            // In place: back up first.
            let backup = (dir as NSString).appendingPathComponent("\(stem).backup.docx")
            try? fm.removeItem(atPath: backup); try? fm.copyItem(atPath: src, toPath: backup)
            dest = src
        }

        // Unpack → edit document.xml → repack, all in a scratch dir.
        let work = (NSTemporaryDirectory() as NSString).appendingPathComponent("gx-docx-\(UUID().uuidString)")
        defer { try? fm.removeItem(atPath: work) }
        try? fm.createDirectory(atPath: work, withIntermediateDirectories: true)
        if run("/usr/bin/unzip", ["-o", "-q", dest, "-d", work]).code != 0 { return fail("could not unpack the .docx") }
        let docXmlPath = (work as NSString).appendingPathComponent("word/document.xml")
        guard var xml = try? String(contentsOfFile: docXmlPath, encoding: .utf8) else { return fail("could not read the document body") }

        var applied = 0
        for (find, value) in repl {
            let replacement = Self.xmlEscape("\(value)")
            // Replace both the raw text and its XML-escaped form (Word stores & < > escaped).
            for needle in [find, Self.xmlEscape(find)] where !needle.isEmpty && xml.contains(needle) {
                xml = xml.replacingOccurrences(of: needle, with: replacement)
                applied += 1
            }
        }
        guard (try? xml.write(toFile: docXmlPath, atomically: true, encoding: .utf8)) != nil else { return fail("could not write the filled body") }

        // Repack: zip the work dir contents back into dest (Word opens any valid zip; order not required).
        let tmpZip = (NSTemporaryDirectory() as NSString).appendingPathComponent("gx-out-\(UUID().uuidString).docx")
        if runIn(work, "/usr/bin/zip", ["-r", "-X", "-q", tmpZip, "."]).code != 0 { return fail("could not repackage the .docx") }
        try? fm.removeItem(atPath: dest)
        do { try fm.moveItem(atPath: tmpZip, toPath: dest) } catch { return fail("could not save: \(error.localizedDescription)") }

        if applied == 0 {
            return ok("Saved \(tildeShown(dest)), but none of the find-text values were present in the document. Call read_docx_text first to see the exact placeholder text, then retry.")
        }
        return ok("Filled \(applied) field(s) and saved \(tildeShown(dest)).")
    }

    /// Run a process with a working directory (for repacking the docx zip from inside the scratch dir).
    private func runIn(_ cwd: String, _ path: String, _ args: [String]) -> (code: Int32, out: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        p.waitUntilExit()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(data: d, encoding: .utf8) ?? "")
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

        // Destination, in priority order:
        //   out_name → DUPLICATE the template into a named file in the same folder (template untouched)
        //              — this is the "monthly report from a template" workflow.
        //   new_copy → a "<stem>-filled.pdf" copy beside the original.
        //   else     → fill in place, with an automatic timestamped backup.
        let srcURL = URL(fileURLWithPath: src)
        let dir = srcURL.deletingLastPathComponent()
        let outName = (a["out_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newCopy = (a["new_copy"] as? Bool) ?? false
        var madeCopy = false
        let destPath: String
        if let outName, !outName.isEmpty {
            var name = (outName as NSString).lastPathComponent           // single component, no traversal
            if !name.lowercased().hasSuffix(".pdf") { name += ".pdf" }
            var dest = dir.appendingPathComponent(name)
            if dest.path == src {                                        // never overwrite the template
                dest = dir.appendingPathComponent("\((name as NSString).deletingPathExtension) (copy).pdf")
            }
            destPath = dest.path
            madeCopy = true
        } else if newCopy {
            let stem = srcURL.deletingPathExtension().lastPathComponent
            destPath = dir.appendingPathComponent("\(stem)-filled.pdf").path
            madeCopy = true
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
        if madeCopy { msg += " The template was left unchanged." } else { msg += " Original backed up." }
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

    // MARK: session search (W1) — read-only recall over the app's persisted transcripts.
    // The logic is pure and lives in GinexusCore (SessionSearch); this is only the wire adapter.
    // Never fails: notices (unknown id, empty store) come back as ok() plain text by design.

    private func sessionSearch(_ a: [String: Any]) -> Data {
        // The active conversation is main-actor state (AppModel); hop like mcpList does.
        var activeID: UUID?
        if let provider = activeConversationProvider {
            activeID = DispatchQueue.main.sync { MainActor.assumeIsolated { provider() } }
        }
        let args = SessionSearch.Args(
            query: a["query"] as? String,
            conversationID: a["conversation_id"] as? String,
            aroundIndex: (a["around_index"] as? NSNumber)?.intValue
        )
        return ok(SessionSearch.run(args, store: convStore, activeConversationID: activeID))
    }

    // MARK: MCP integrations — connect external servers from within a chat (SP-Connect-in-chat).
    // Persistence goes through SettingsStore.shared (the single settings.json writer) on the main
    // actor; the secret lands in the Keychain, never plaintext. The server activates on next restart.

    private func mcpList() -> Data {
        let servers = DispatchQueue.main.sync { MainActor.assumeIsolated { SettingsStore.shared.settings.mcpServers } }
        if servers.isEmpty { return ok("No MCP integrations are connected yet.") }
        let lines = servers.map { s -> String in
            let state = s.enabled ? "enabled" : "disabled"
            let cred = (s.tokenEnv?.isEmpty == false) ? " · uses a Keychain credential" : ""
            return "- \(s.name): \(state)\(cred)"
        }
        return ok("Connected MCP servers:\n" + lines.joined(separator: "\n"))
    }

    private func connectMcp(_ a: [String: Any]) -> Data {
        let slug = (a["name"] as? String ?? "")
            .lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let command = (a["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty else { return fail("a short name is required") }
        guard !command.isEmpty else { return fail("the server's launch command is required") }
        let tokenEnv = (a["token_env"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = a["token"] as? String
        var ref: String? = nil
        if let tokenEnv, !tokenEnv.isEmpty, let token, !token.isEmpty {
            let r = "mcp.\(slug).token"
            _ = Keychain.set(token, for: r)
            ref = r
        }
        let cfg = McpServerConfig(name: slug, command: command, enabled: true,
                                  tokenEnv: (tokenEnv?.isEmpty == false) ? tokenEnv : nil, credentialRef: ref)
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                SettingsStore.shared.update { s in
                    s.mcpServers.removeAll { $0.name == slug }
                    s.mcpServers.append(cfg)
                }
            }
        }
        return ok("Connected “\(slug)”. It activates the next time GINEXUS is restarted — relaunch the app to start using its tools.")
    }
}
