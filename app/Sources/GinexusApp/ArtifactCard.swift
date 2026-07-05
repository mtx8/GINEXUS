// ArtifactCard.swift — an in-app viewer card for a file GINEXUS produced this turn (a generated
// image, a written/saved document, or any other file). Rendered in the execution stream right under
// the Action card / final answer that created it. Matches the BlockCard grammar exactly (ink700
// panel, line1 hairline, radius 8, ember stamp header) — no emoji, no gradients.
//
// Every card offers: click the thumbnail/row → in-app Quick Look; "Save As…" → NSSavePanel that
// copies the file to a chosen destination (the panel owns the overwrite confirmation); "Reveal in
// Finder". A file that was moved/deleted renders a dim "file no longer exists" state, never a crash.
import SwiftUI
import AppKit
import Quartz          // QLPreviewView — native in-app Quick Look
import GinexusCore

/// A wrapped file URL for `.sheet(item:)` presentation of the Quick Look preview.
private struct PreviewItem: Identifiable, Equatable { let id = UUID(); let url: URL }

/// Embeds the system Quick Look preview view for a file, in-app (no external app, no floating panel).
private struct QuickLookView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        v.autostarts = true
        v.previewItem = url as NSURL
        return v
    }
    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        if (nsView.previewItem as? NSURL) != (url as NSURL) { nsView.previewItem = url as NSURL }
    }
}

struct ArtifactCard: View {
    let path: String

    /// Non-nil while the in-app Quick Look sheet is presented.
    @State private var preview: PreviewItem?
    @State private var thumbnail: NSImage?
    /// Re-checked when the card appears so a Save/Reveal on a since-deleted file degrades gracefully.
    @State private var exists = true

    private var url: URL { URL(fileURLWithPath: path) }
    /// HARD RULE: never read/materialize iCloud-backed files. Such artifacts render
    /// as a reveal-only row — no existence check, thumbnail, Quick Look, or copy.
    private var isCloudPath: Bool {
        path.contains("Mobile Documents") || path.contains("com~apple~CloudDocs")
    }
    private var kind: ArtifactKind { Artifact.kind(forPath: path) }
    private var name: String { Artifact.filename(path) }
    private var headerIcon: String { kind == .image ? "photo" : "doc.richtext" }

    /// e.g. "PDF · 128 KB" — the type stamp and human size for the caption.
    private var caption: String {
        let type = Artifact.ext(path).uppercased()
        let size = fileSizeText()
        switch (type.isEmpty, size.isEmpty) {
        case (false, false): return "\(type) · \(size)"
        case (false, true):  return type
        case (true, false):  return size
        default:             return "FILE"
        }
    }

    var body: some View {
        BlockCard(label: "Artifact", icon: headerIcon, accent: Brand.ember500) {
            if isCloudPath {
                cloudRow
            } else if exists {
                VStack(alignment: .leading, spacing: 12) {
                    if kind == .image { imagePreview } else { fileRow }
                    actionRow
                }
            } else {
                missingRow
            }
        }
        .onAppear { if !isCloudPath { exists = FileManager.default.fileExists(atPath: path) } }
        .sheet(item: $preview) { item in
            VStack(spacing: 0) {
                QuickLookView(url: item.url)
                    .frame(minWidth: 720, minHeight: 520)
                HStack {
                    Text(Artifact.filename(item.url.path)).font(Brand.mono(11)).foregroundStyle(Brand.bone300)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { preview = nil } label: { TacticalLabel(text: "Done", filled: true) }.buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Brand.ink800)
            }
            .background(Brand.ink900)
        }
    }

    // MARK: content

    /// Image: an inline thumbnail (fits within ~360pt), tappable for Quick Look, with a name/size line.
    private var imagePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { openQuickLook() } label: {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFit()
                            .frame(maxWidth: 360, maxHeight: 300)
                    } else {
                        RoundedRectangle(cornerRadius: 8).fill(Brand.ink600)
                            .frame(width: 360, height: 180)
                            .overlay(ProgressView().controlSize(.small))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.line1, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Quick Look")
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Brand.mono(12, weight: .medium)).foregroundStyle(Brand.bone50)
                    .lineLimit(1).truncationMode(.middle)
                Text(caption).font(Brand.mono(8.5, weight: .bold)).kerning(0.8).foregroundStyle(Brand.bone400)
            }
        }
        .task(id: path) {
            guard thumbnail == nil else { return }
            let p = path
            thumbnail = await Task.detached(priority: .userInitiated) {
                AppModel.thumbnailImage(p, maxPixel: 720)
            }.value
        }
    }

    /// Document / any other file: the real Finder file-type icon + name + type·size, tappable for Quick Look.
    private var fileRow: some View {
        Button { openQuickLook() } label: {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable().interpolation(.high)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(Brand.mono(12, weight: .medium)).foregroundStyle(Brand.bone50)
                        .lineLimit(1).truncationMode(.middle)
                    Text(caption).font(Brand.mono(8.5, weight: .bold)).kerning(0.8).foregroundStyle(Brand.bone400)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Quick Look")
    }

    /// Dim state for a file that no longer exists (moved/deleted) — informative, never a crash.
    private var missingRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "questionmark.square.dashed").font(.system(size: 22)).foregroundStyle(Brand.bone400)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Brand.mono(12, weight: .medium)).foregroundStyle(Brand.bone300)
                    .lineLimit(1).truncationMode(.middle)
                Text("FILE NO LONGER EXISTS").font(Brand.mono(8.5, weight: .bold)).kerning(0.8).foregroundStyle(Brand.bone400)
            }
            Spacer(minLength: 0)
        }
        .opacity(0.75)
    }

    /// iCloud-backed artifact: shown but never read — Reveal in Finder is the only action.
    private var cloudRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "icloud").font(.system(size: 20)).foregroundStyle(Brand.bone400)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Brand.mono(12, weight: .medium)).foregroundStyle(Brand.bone300)
                    .lineLimit(1).truncationMode(.middle)
                Text("IN ICLOUD — PREVIEW DISABLED").font(Brand.mono(8.5, weight: .bold)).kerning(0.8)
                    .foregroundStyle(Brand.bone400)
            }
            Spacer(minLength: 0)
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { TacticalLabel(text: "Reveal") }
                .buttonStyle(.plain)
        }
        .opacity(0.85)
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button { openQuickLook() } label: { TacticalLabel(text: "Preview", icon: "eye") }.buttonStyle(.plain)
            Button { saveAs() } label: { TacticalLabel(text: "Save As", icon: "square.and.arrow.down") }.buttonStyle(.plain)
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { TacticalLabel(text: "Reveal") }.buttonStyle(.plain)
            Spacer(minLength: 0)
        }
    }

    // MARK: actions

    private func fileSizeText() -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let n = attrs[.size] as? Int64 else { return "" }
        return ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private func openQuickLook() {
        guard FileManager.default.fileExists(atPath: path) else { exists = false; return }
        preview = PreviewItem(url: url)
    }

    /// Copy the artifact to a user-chosen destination. NSSavePanel's own dialog handles the overwrite
    /// confirmation; on confirm we replace the existing file and copy the source in.
    private func saveAs() {
        guard FileManager.default.fileExists(atPath: path) else { exists = false; NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.title = "Save Artifact"
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                // Panel already confirmed the overwrite; replace atomically so a
                // failed copy can never destroy the existing file.
                let tmp = dest.deletingLastPathComponent()
                    .appendingPathComponent(".\(UUID().uuidString)-\(name)")
                try FileManager.default.copyItem(at: url, to: tmp)
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try FileManager.default.copyItem(at: url, to: dest)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not save artifact"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
