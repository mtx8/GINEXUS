// MarkdownReply.swift — content-aware renderer for assistant replies. Instead of dumping raw
// Markdown as monospace text, it parses the reply into blocks and renders each by TYPE:
//   • prose      → rendered Markdown (bold / italic / inline-code / links)
//   • headings   → sized, weighted bone text
//   • lists      → bullets / numbers
//   • code       → monospaced panel with a language tag + Copy button
//   • images     → inline (local path or remote URL)
//   • video      → an AVKit player (local path or remote URL)
//   • tables     → preformatted monospace (alignment preserved)
//   • rules      → hairline · quotes → ember-barred italic
// Brand-styled (ink / bone / ember), dark-only, no dependencies.
import SwiftUI
import AppKit
import AVKit

struct MarkdownReply: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            let blocks = ReplyParser.parse(text)
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(Brand.ember500) // links render in the locking accent
    }

    @ViewBuilder
    private func render(_ block: ReplyBlock) -> some View {
        switch block {
        case .paragraph(let s):
            Text(ReplyParser.inline(s))
                .font(.system(size: 14.5))
                .lineSpacing(5)
                .foregroundStyle(Brand.bone50)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let s):
            let size: CGFloat = [22, 19, 16, 15, 14, 13][min(max(level - 1, 0), 5)]
            Text(s)
                .font(.system(size: size, weight: .bold)).kerning(0.3)
                .foregroundStyle(Brand.bone50)
                .padding(.top, level <= 2 ? 4 : 1)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Brand.ember500).font(.system(size: 14.5, weight: .bold))
                        Text(ReplyParser.inline(it)).font(.system(size: 14.5)).lineSpacing(4).foregroundStyle(Brand.bone50)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .ordered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1).").foregroundStyle(Brand.ember500)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                        Text(ReplyParser.inline(it)).font(.system(size: 14.5)).lineSpacing(4).foregroundStyle(Brand.bone50)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .code(let lang, let code):
            CodePanel(language: lang, code: code)

        case .preformatted(let s):
            Text(s)
                .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Brand.bone50)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.white.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 8))

        case .rule:
            Rectangle().fill(Brand.line1).frame(height: 1).padding(.vertical, 2)

        case .quote(let s):
            HStack(spacing: 10) {
                Rectangle().fill(Brand.ember500.opacity(0.7)).frame(width: 3)
                Text(ReplyParser.inline(s)).font(.system(size: 14.5)).italic().lineSpacing(4)
                    .foregroundStyle(Brand.bone50.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .image(let src):
            MediaImage(src: src)

        case .video(let src):
            MediaVideo(src: src)
        }
    }
}

// MARK: - Blocks

enum ReplyBlock {
    case paragraph(String)
    case heading(Int, String)
    case bullets([String])
    case ordered([String])
    case code(language: String?, code: String)
    case preformatted(String) // tables / aligned text
    case rule
    case quote(String)
    case image(String)
    case video(String)
}

// MARK: - Parser

enum ReplyParser {
    /// Render inline Markdown (bold/italic/`code`/links), preserving whitespace; falls back to plain.
    static func inline(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }

    static func parse(_ text: String) -> [ReplyBlock] {
        var blocks: [ReplyBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }

        while i < lines.count {
            let line = lines[i]
            let t = trimmed(line)

            // fenced code ```lang ... ```
            if t.hasPrefix("```") {
                let lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !trimmed(lines[i]).hasPrefix("```") { code.append(lines[i]); i += 1 }
                if i < lines.count { i += 1 } // skip closing fence
                blocks.append(.code(language: lang.isEmpty ? nil : lang, code: code.joined(separator: "\n")))
                continue
            }
            if t.isEmpty { i += 1; continue }

            // standalone image / video (markdown ![..](url) or a bare path/url)
            if let media = mediaRef(t) {
                blocks.append(media.kind == "video" ? .video(media.src) : .image(media.src))
                i += 1; continue
            }
            // horizontal rule
            if isRule(t) { blocks.append(.rule); i += 1; continue }
            // heading
            if t.hasPrefix("#") {
                let hashes = t.prefix(while: { $0 == "#" }).count
                blocks.append(.heading(hashes, trimmed(String(t.dropFirst(hashes)))))
                i += 1; continue
            }
            // table / aligned block: consecutive lines starting with '|'
            if t.hasPrefix("|") {
                var rows: [String] = []
                while i < lines.count, trimmed(lines[i]).hasPrefix("|") { rows.append(lines[i]); i += 1 }
                blocks.append(.preformatted(rows.joined(separator: "\n")))
                continue
            }
            // blockquote
            if t.hasPrefix(">") {
                var qs: [String] = []
                while i < lines.count, trimmed(lines[i]).hasPrefix(">") {
                    qs.append(trimmed(String(trimmed(lines[i]).dropFirst())))
                    i += 1
                }
                blocks.append(.quote(qs.joined(separator: "\n")))
                continue
            }
            // unordered list
            if isBullet(t) {
                var items: [String] = []
                while i < lines.count, isBullet(trimmed(lines[i])) {
                    items.append(stripBullet(trimmed(lines[i]))); i += 1
                }
                blocks.append(.bullets(items)); continue
            }
            // ordered list
            if isOrdered(t) {
                var items: [String] = []
                while i < lines.count, isOrdered(trimmed(lines[i])) {
                    items.append(stripOrdered(trimmed(lines[i]))); i += 1
                }
                blocks.append(.ordered(items)); continue
            }
            // paragraph: gather consecutive "plain" lines
            var para: [String] = []
            while i < lines.count {
                let lt = trimmed(lines[i])
                if lt.isEmpty || lt.hasPrefix("```") || lt.hasPrefix("#") || lt.hasPrefix(">")
                    || lt.hasPrefix("|") || isRule(lt) || isBullet(lt) || isOrdered(lt) || mediaRef(lt) != nil {
                    break
                }
                para.append(lines[i]); i += 1
            }
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))) }
        }
        return blocks
    }

    private static func isRule(_ t: String) -> Bool {
        let s = t.replacingOccurrences(of: " ", with: "")
        return s.count >= 3 && (s.allSatisfy { $0 == "-" } || s.allSatisfy { $0 == "*" } || s.allSatisfy { $0 == "_" })
    }
    private static func isBullet(_ t: String) -> Bool {
        t.range(of: #"^[-*+]\s+\S"#, options: .regularExpression) != nil
    }
    private static func stripBullet(_ t: String) -> String {
        t.replacingOccurrences(of: #"^[-*+]\s+"#, with: "", options: .regularExpression)
    }
    private static func isOrdered(_ t: String) -> Bool {
        t.range(of: #"^\d+[.)]\s+\S"#, options: .regularExpression) != nil
    }
    private static func stripOrdered(_ t: String) -> String {
        t.replacingOccurrences(of: #"^\d+[.)]\s+"#, with: "", options: .regularExpression)
    }
    /// Detect a standalone image/video reference; returns (kind, src) or nil.
    static func mediaRef(_ t: String) -> (kind: String, src: String)? {
        var src = t
        // markdown image: ![alt](url)
        if t.hasPrefix("!["), let open = t.range(of: "]("), t.hasSuffix(")") {
            src = String(t[open.upperBound..<t.index(before: t.endIndex)])
        } else if t.hasPrefix("[") && t.contains("](") && t.hasSuffix(")") {
            // a bare link on its own line, e.g. [clip](file.mp4)
            if let open = t.range(of: "](") { src = String(t[open.upperBound..<t.index(before: t.endIndex)]) }
        } else if t.contains(" ") {
            return nil // prose, not a bare path
        }
        let low = src.lowercased()
        let looksPathy = low.hasPrefix("http://") || low.hasPrefix("https://") || low.hasPrefix("/")
            || low.hasPrefix("~/") || low.hasPrefix("file://")
        guard looksPathy else { return nil }
        if [".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".bmp"].contains(where: low.hasSuffix) {
            return ("image", src)
        }
        if [".mp4", ".mov", ".m4v", ".webm"].contains(where: low.hasSuffix) { return ("video", src) }
        return nil
    }
}

// MARK: - Code panel

private struct CodePanel: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((language ?? "code").uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced)).kerning(1.2)
                    .foregroundStyle(Brand.muted)
                Spacer()
                Button(action: copy) {
                    Text(copied ? "COPIED" : "COPY")
                        .font(.system(size: 9, weight: .bold, design: .monospaced)).kerning(1)
                        .foregroundStyle(Brand.ember500)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
            Text(code)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Brand.bone50)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(Color(red: 0x0F / 255, green: 0x0F / 255, blue: 0x13 / 255)) // recessed ink
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

// MARK: - Media

private struct MediaImage: View {
    let src: String
    @State private var local: NSImage?
    var body: some View {
        Group {
            if src.lowercased().hasPrefix("http") {
                AsyncImage(url: URL(string: src)) { img in
                    img.resizable().scaledToFit()
                } placeholder: {
                    ProgressView().controlSize(.small)
                }
            } else if let local {
                Image(nsImage: local).resizable().scaledToFit()
            } else {
                ProgressView().controlSize(.small)   // decoding once (off the per-render path)
            }
        }
        .frame(maxWidth: 440, maxHeight: 440)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // Decode a local image ONCE per src (downsampled) — never on every render/streamed token.
        .task(id: src) {
            if !src.lowercased().hasPrefix("http"), local == nil {
                local = AppModel.thumbnailImage(filePath(src), maxPixel: 880)
            }
        }
    }
}

private struct MediaVideo: View {
    let src: String
    var body: some View {
        let url = src.lowercased().hasPrefix("http")
            ? URL(string: src)
            : URL(fileURLWithPath: filePath(src))
        return Group {
            if let url {
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(maxWidth: 480, minHeight: 270, maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Text(src).font(.system(size: 12, design: .monospaced)).foregroundStyle(Brand.muted)
            }
        }
    }
}

private func filePath(_ src: String) -> String {
    (src.replacingOccurrences(of: "file://", with: "") as NSString).expandingTildeInPath
}
