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
                inputRow
            }
            .padding(24)
        }
        .frame(minWidth: 560, minHeight: 460)
        .preferredColorScheme(.dark)
        .sheet(item: $model.pending) { p in approvalSheet(p) }
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
            Button(action: { model.importExport() }) {
                Text("⤓ IMPORT").font(.system(size: 10, weight: .bold, design: .monospaced)).kerning(1)
                    .foregroundStyle(Brand.muted)
            }
            .buttonStyle(.plain)
            .help("Import a sanitized ChatGPT/Claude export into memory")
            .disabled(!model.connected)
            modelPicker
        }
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
            Text(msg.text)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(Brand.bone50)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(isUser ? Brand.ink800 : Color.white.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 8))
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
