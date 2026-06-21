// VoiceLog.swift — lightweight append-only diagnostics for the voice loop, written to
// ~/Library/Application Support/GINEXUS/voice.log so issues can be traced without the debugger.
import Foundation

enum VoiceLog {
    private static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GINEXUS", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("voice.log")
    }()
    private static let q = DispatchQueue(label: "ginexus.voicelog")

    static func log(_ msg: String) {
        q.async {
            let ts = ISO8601DateFormatter().string(from: Date())
            let line = "\(ts) \(msg)\n"
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? line.data(using: .utf8)?.write(to: url)
            }
        }
    }
}
