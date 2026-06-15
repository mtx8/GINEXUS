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
        }
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
