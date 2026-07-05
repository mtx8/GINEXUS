// Artifact.swift — pure, testable classification of files GINEXUS produces (generated images,
// written documents, saved copies). Lives in GinexusCore so the path-detection logic is covered by
// GinexusCoreTests independently of the SwiftUI layer. The app's ArtifactCard renders one card per
// normalized path and picks its presentation from `ArtifactKind`.
import Foundation

/// How a produced file is presented in the artifact viewer.
public enum ArtifactKind: String, Sendable, Equatable {
    case image        // inline thumbnail preview
    case document     // file-type icon + name/size
    case other        // fallback — any other file, treated like a document row
}

public enum Artifact {
    /// Image extensions that get an inline thumbnail. Lowercased, no dot.
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tiff", "bmp"]
    /// Document/text extensions that get a file-type icon row.
    public static let documentExtensions: Set<String> = ["pdf", "pages", "docx", "doc", "md", "markdown", "txt", "csv", "json", "html", "htm", "rtf"]

    /// The lowercased extension (no dot) of a path, or "" if none.
    public static func ext(_ path: String) -> String {
        (path as NSString).pathExtension.lowercased()
    }

    /// The last path component (filename with extension).
    public static func filename(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Classify a path by its extension. Unknown extensions fall back to `.other` (still shown, with
    /// a generic file icon) so "any file" the agent produces surfaces a card rather than vanishing.
    public static func kind(forPath path: String) -> ArtifactKind {
        let e = ext(path)
        if imageExtensions.contains(e) { return .image }
        if documentExtensions.contains(e) { return .document }
        return .other
    }

    /// Clean a raw list of tool-produced paths for rendering: trim whitespace, drop empties, and
    /// de-duplicate while preserving first-seen order (a turn that generates then saves the same file
    /// must not show two identical cards). Absolute paths are kept as-is.
    public static func normalize(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in paths {
            let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { continue }
            if seen.insert(p).inserted { out.append(p) }
        }
        return out
    }
}
