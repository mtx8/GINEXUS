// ContentView.swift (SP2) — chat-forward UI over the live hardened spine. Brand spine tokens.
import SwiftUI

/// Headless-render-safe view (no ScrollView/TextField, which ImageRenderer won't draw) used
/// only to capture a PNG of the live conversation for verification.
struct SnapshotView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ZStack {
            Brand.ink900
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Text("GINEXUS").font(.system(size: 30, weight: .heavy)).kerning(2).foregroundStyle(Brand.bone50)
                    Text("nexus").font(.system(size: 26, weight: .semibold, design: .serif)).italic().foregroundStyle(Brand.ember500)
                    Spacer()
                }
                HStack(spacing: 8) {
                    Circle().fill(model.connected ? Brand.ok : Brand.muted).frame(width: 8, height: 8)
                    Text(model.spineStatus).font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(model.connected ? Brand.ok : Brand.muted)
                    Spacer()
                }
                ForEach(model.chat) { msg in
                    let isUser = msg.role == "user"
                    VStack(alignment: .leading, spacing: 3) {
                        Text(isUser ? "YOU" : "GINEXUS")
                            .font(.system(size: 9, weight: .bold, design: .monospaced)).kerning(1.5)
                            .foregroundStyle(isUser ? Brand.ember500 : Brand.muted)
                        Text(msg.text).font(.system(size: 14, design: .monospaced)).foregroundStyle(Brand.bone50)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(isUser ? Brand.ink800 : Color.white.opacity(0.03))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                if model.sending {
                    Text("…thinking").font(.system(size: 12, design: .monospaced)).foregroundStyle(Brand.ember500)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .frame(width: 640, height: 560)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Brand.ink900.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                header
                statusStrip
                transcript
                capabilityBar
                inputRow
            }
            .padding(24)
        }
        .frame(minWidth: 560, minHeight: 460)
        .preferredColorScheme(.dark)
        .sheet(item: $model.pending) { p in approvalSheet(p) }
        .sheet(isPresented: $model.memoryOpen) { memorySheet }
    }

    /// One-tap capability actions. Council / Research / Image wrap the current input and invoke the
    /// matching tool; Profile distills long-term memory into the always-in-context self-model.
    private var capabilityBar: some View {
        HStack(spacing: 8) {
            capChip("PERSPECTIVES", help: "Answer your message from several expert viewpoints, then give a balanced take.",
                    enabled: model.canQuickAction) { model.runCouncil() }
            capChip("RESEARCH", help: "Investigate your message in depth across multiple angles, then return a written, sourced answer.",
                    enabled: model.canQuickAction) { model.runResearch() }
            capChip("CREATE IMAGE", help: "Generate an image from your message.",
                    enabled: model.canQuickAction) { model.runImage() }
            Spacer()
        }
    }

    private func capChip(_ title: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced)).kerning(1)
                .foregroundStyle(enabled ? Brand.ember500 : Brand.muted)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke((enabled ? Brand.ember500 : Brand.muted).opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    /// HITL: GINEXUS pauses an irreversible/OS action here until you approve with Touch ID.
    private func approvalSheet(_ p: PendingAction) -> some View {
        ZStack {
            Brand.ink900.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Text("APPROVAL REQUIRED")
                    .font(.system(size: 13, weight: .bold, design: .monospaced)).kerning(2)
                    .foregroundStyle(Brand.ember500)
                Text("GINEXUS wants to run an action that changes something. Approve with Touch ID to proceed.")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(p.preview)
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(Brand.bone50)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(Brand.ink800).clipShape(RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 10) {
                    Spacer()
                    Button(action: { model.deny() }) {
                        Text("DENY").font(.system(size: 12, weight: .bold, design: .monospaced)).kerning(1.5)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .foregroundStyle(Brand.muted).background(Brand.ink800)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                    Button(action: { model.approve() }) {
                        Text("APPROVE · TOUCH ID").font(.system(size: 12, weight: .bold, design: .monospaced)).kerning(1.5)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .foregroundStyle(Brand.ink900).background(Brand.ember500)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
            }
            .padding(24)
        }
        .frame(width: 480)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("GINEXUS")
                .font(.system(size: 30, weight: .heavy)).kerning(2)
                .foregroundStyle(Brand.bone50)
            Text("nexus")
                .font(.system(size: 26, weight: .semibold, design: .serif)).italic()
                .foregroundStyle(Brand.ember500)
            Spacer()
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 8) {
            Circle().fill(model.connected ? Brand.ok : Brand.muted).frame(width: 8, height: 8)
            Text(model.spineStatus)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(model.connected ? Brand.ok : Brand.muted)
            Spacer()
            Button(action: { model.openMemory() }) {
                Text("MEMORY").font(.system(size: 10, weight: .bold, design: .monospaced)).kerning(1)
                    .foregroundStyle(Brand.muted)
            }
            .buttonStyle(.plain)
            .help("Browse what GINEXUS knows — core profile + searchable long-term memory")
            .disabled(!model.connected)
            Button(action: { model.importExport() }) {
                Text("⤓ IMPORT").font(.system(size: 10, weight: .bold, design: .monospaced)).kerning(1)
                    .foregroundStyle(Brand.muted)
            }
            .buttonStyle(.plain)
            .help("Import a sanitized ChatGPT/Claude export into memory")
            .disabled(!model.connected)
            autonomyToggle
            modelPicker
        }
    }

    /// Memory browser — core blocks (incl. the consolidated profile) + searchable archival facts.
    private var memorySheet: some View {
        ZStack {
            Brand.ink900.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("MEMORY").font(.system(size: 14, weight: .bold, design: .monospaced)).kerning(2)
                        .foregroundStyle(Brand.bone50)
                    Text("\(model.memFactsCount) facts").font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Brand.muted)
                    Spacer()
                    if model.memLoading { ProgressView().controlSize(.small) }
                    Button("BUILD PROFILE") { model.buildProfile() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Brand.ember500)
                        .disabled(!model.connected || model.sending)
                        .help("Summarize what GINEXUS knows about you from memory, and keep it in mind")
                    Button("DONE") { model.memoryOpen = false }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Brand.muted)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.memBlocks.isEmpty {
                            Text("Nothing learned about you yet. Tap BUILD PROFILE above to summarize what GINEXUS knows from your memory.")
                                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Brand.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(model.memBlocks) { b in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(b.name.uppercased())
                                    .font(.system(size: 10, weight: .bold, design: .monospaced)).kerning(1.5)
                                    .foregroundStyle(Brand.ember500)
                                Text(b.value).font(.system(size: 13)).foregroundStyle(Brand.bone50)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(Brand.ink800).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        Divider().overlay(Color.white.opacity(0.08))
                        ForEach(model.memResults) { f in
                            HStack(alignment: .top, spacing: 8) {
                                Text(f.origin == "untrusted" ? "DATA" : "·")
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Brand.muted).frame(width: 34, alignment: .leading)
                                Text(f.text).font(.system(size: 12)).foregroundStyle(Brand.bone50.opacity(0.9))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                HStack(spacing: 8) {
                    TextField("Search memory…", text: $model.memQuery)
                        .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Brand.bone50).padding(10).background(Brand.ink800)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onSubmit { model.searchMemory() }
                    Button(action: { model.searchMemory() }) {
                        Text("SEARCH").font(.system(size: 11, weight: .bold, design: .monospaced)).kerning(1)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .foregroundStyle(Brand.ink900).background(Brand.ember500)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
            }
            .padding(24)
        }
        .frame(width: 620, height: 640)
        .preferredColorScheme(.dark)
    }

    /// HITL ⇄ Autonomous toggle. The hard gate (money / external comms / legal / delete / exec) still
    /// requires Touch ID even in autonomous mode — this only relaxes ordinary irreversible tools.
    private var autonomyToggle: some View {
        Button(action: { model.autonomous.toggle() }) {
            HStack(spacing: 5) {
                Image(systemName: model.autonomous ? "bolt.fill" : "hand.raised.fill")
                Text(model.autonomous ? "AUTO" : "HITL")
                    .font(.system(size: 10, weight: .bold, design: .monospaced)).kerning(1)
            }
            .foregroundStyle(model.autonomous ? Brand.ember500 : Brand.muted)
        }
        .buttonStyle(.plain)
        .help(model.autonomous
            ? "Autonomous: irreversible actions run unattended — EXCEPT hard-gated ones (money, external comms, legal, delete, code execution), which always ask. Click for human-in-the-loop."
            : "Human-in-the-loop: every irreversible action asks for Touch ID. Click to enable autonomous mode.")
        .disabled(!model.connected)
    }

    /// Auto/manual model selector — "Auto" routes to the 30B for chat/agent; pick a tier to pin it.
    private var modelPicker: some View {
        Picker("Model", selection: $model.selectedModel) {
            ForEach(model.models) { m in Text(m.label).tag(m.id) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .tint(Brand.ember500)
        .frame(maxWidth: 240)
        .disabled(!model.connected)
    }

    private var transcript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.chat.isEmpty {
                    Text("Ask GINEXUS anything — it runs entirely on this Mac.")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Brand.muted)
                }
                ForEach(model.chat) { msg in
                    bubble(msg)
                }
                if model.sending {
                    Text("…thinking")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Brand.ember500)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    private func bubble(_ msg: ChatMsg) -> some View {
        let isUser = msg.role == "user"
        return VStack(alignment: .leading, spacing: 3) {
            Text(isUser ? "YOU" : "GINEXUS")
                .font(.system(size: 9, weight: .bold, design: .monospaced)).kerning(1.5)
                .foregroundStyle(isUser ? Brand.ember500 : Brand.muted)
            Group {
                if isUser {
                    // The user's own input — show verbatim (monospace), no Markdown rendering.
                    Text(msg.text)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(Brand.bone50)
                        .textSelection(.enabled)
                } else if msg.streaming {
                    // Live: plain text + cursor (cheap to update per token); a status line shows
                    // tool/council/research activity. Switches to rich rendering once finalized.
                    VStack(alignment: .leading, spacing: 6) {
                        if let status = msg.status {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(status).font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Brand.ember500)
                            }
                        }
                        StreamingText(text: msg.text)
                    }
                } else {
                    // Finalized assistant reply — content-aware rich rendering (text/code/images/…).
                    MarkdownReply(text: msg.text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(isUser ? Brand.ink800 : Color.white.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            // Explicit generated image (from the image_generate tool) attached to the message.
            if let path = msg.imagePath, let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img).resizable().scaledToFit()
                    .frame(maxWidth: 360, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            TextField("Message GINEXUS…", text: $model.chatInput)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(Brand.bone50)
                .padding(12)
                .background(Brand.ink800)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onSubmit { model.send(model.chatInput) }
            Button(action: { model.send(model.chatInput) }) {
                Text("SEND").font(.system(size: 12, weight: .bold, design: .monospaced)).kerning(1.5)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .foregroundStyle(Brand.ink900).background(Brand.ember500)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(model.sending || !model.connected)
        }
    }
}

/// Streaming answer text with a terminal-style BLINKING filled cursor in the SEND-button accent
/// (ember). The cursor glyph is always present but alternates ember ⇄ clear, so it blinks in place
/// with no layout reflow. Inline at the end of the (wrapping) text.
private struct StreamingText: View {
    let text: String
    @State private var on = true
    private let blink = Timer.publish(every: 0.53, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(attributed)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onReceive(blink) { _ in on.toggle() }
    }

    private var attributed: AttributedString {
        var s = AttributedString(text)
        s.font = .system(size: 14)
        s.foregroundColor = Brand.bone50
        var cursor = AttributedString("▌")
        cursor.font = .system(size: 14)
        cursor.foregroundColor = on ? Brand.ember500 : .clear
        return s + cursor
    }
}
