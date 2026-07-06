// FabComponents.swift — the Fabrication cockpit's building blocks. STRICTLY RECTANGULAR: every
// container is a RoundedRectangle (radius 4–8) with a 1px hairline — NO capsules/pills anywhere.
// Aesthetic: OMNISCIENT "Bloomberg × Gotham" density over the Silo Unison ink/ember palette;
// cyan is reserved for LIVE data values. Local to Fabrication so the rest of the app is untouched.
import SwiftUI
import AppKit
import GinexusCore

// MARK: - button

enum FabButtonStyle { case primary, standard, danger, ghost }

/// A rectangular action button. `primary` = solid ember; `standard` = ink fill + hairline;
/// `danger` = hairline that warms to Hinomaru on hover; `ghost` = borderless dim.
struct FabButton: View {
    let title: String
    var icon: String? = nil
    var style: FabButtonStyle = .standard
    var enabled: Bool = true
    var compact: Bool = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: { if enabled { action() } }) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: compact ? 9.5 : 10.5, weight: .semibold)) }
                Text(title.uppercased())
                    .font(.system(size: compact ? 10 : 11, weight: .semibold)).kerning(1.1)
            }
            .foregroundStyle(fg)
            .padding(.horizontal, compact ? 10 : 13).padding(.vertical, compact ? 6 : 8)
            .frame(maxWidth: .infinity, alignment: .center)
            .fixedSize(horizontal: true, vertical: false)
            .background(bg, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { h in withAnimation(Brand.ease(0.15)) { hover = h && enabled } }
    }

    private var fg: Color {
        switch style {
        case .primary: return Brand.emberText
        case .danger: return hover ? Brand.hi500 : Brand.bone200
        case .ghost: return hover ? Brand.bone100 : Brand.bone300
        case .standard: return hover ? Brand.bone50 : Brand.bone200
        }
    }
    private var bg: Color {
        switch style {
        case .primary: return hover ? Brand.ember400 : Brand.ember500
        case .ghost: return .clear
        case .danger: return hover ? Brand.hi500.opacity(0.10) : .clear
        case .standard: return hover ? Brand.ink500 : Brand.ink600
        }
    }
    private var border: Color {
        switch style {
        case .primary: return .clear
        case .ghost: return .clear
        case .danger: return hover ? Brand.hi500.opacity(0.6) : Brand.line1
        case .standard: return hover ? Brand.line2 : Brand.line1
        }
    }
}

// MARK: - tag (rectangular micro-label, replaces the pill chip)

struct FabTag: View {
    let text: String
    var color: Color = Brand.bone300
    var filled: Bool = false
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 8.5, weight: .bold)).kerning(1.0)
            .foregroundStyle(filled ? Brand.emberText : color)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(filled ? color : Brand.ink600, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(filled ? .clear : Brand.line1, lineWidth: 1))
    }
}

// MARK: - segmented control (rectangular, replaces pill tabs)

struct FabSegment: View {
    let label: String
    var selected: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold)).kerning(1.2)
                .foregroundStyle(selected ? Brand.bone50 : (hover ? Brand.bone200 : Brand.bone400))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Brand.ink600 : .clear, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(selected ? Brand.ember700 : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - section panel with an ember accent spine (OMNISCIENT omni-panel)

struct FabPanel<Content: View>: View {
    let title: String
    var accent: Color = Brand.ember500
    var accessory: AnyView? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Rectangle().fill(accent).frame(width: 2, height: 11)   // the accent spine
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold)).kerning(2.0).foregroundStyle(Brand.bone300)
                    .padding(.leading, 8)
                Spacer(minLength: 8)
                if let accessory { accessory }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            Rectangle().fill(Brand.line1).frame(height: 1)
            content().padding(14)
        }
        .background(Brand.ink700, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.line1, lineWidth: 1))
    }
}

// MARK: - a telemetry metric cell (label over value)

struct FabMetric: View {
    let key: String
    let value: String
    var live: Bool = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key.uppercased()).font(.system(size: 8.5, weight: .semibold)).kerning(1.1)
                .foregroundStyle(Brand.bone400).lineLimit(1)
            Text(value).font(.system(size: 13, weight: .semibold, design: .monospaced))
                .monospacedDigit().foregroundStyle(live ? Brand.cyan500 : Brand.bone100).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - a key/value data row (dim key left, mono value right)

struct FabDataRow: View {
    let key: String
    let value: String
    var valueColor: Color = Brand.bone100
    var body: some View {
        HStack(spacing: 8) {
            Text(key.uppercased()).font(.system(size: 9.5, weight: .medium)).kerning(0.6)
                .foregroundStyle(Brand.bone400)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .monospacedDigit().foregroundStyle(valueColor).lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - a metric whose value ticks in real time (elapsed grows, remaining shrinks)

struct FabLiveMetric: View {
    let key: String
    let baseSecs: Int
    let since: Date       // when baseSecs was sampled from the core
    let countUp: Bool     // true = elapsed, false = remaining
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let delta = Int(ctx.date.timeIntervalSince(since))
            let v = countUp ? baseSecs + delta : max(0, baseSecs - delta)
            FabMetric(key: key, value: fabETADuration(v), live: true)
        }
    }
}

// MARK: - indeterminate progress (rectangular sweep) for long ops

struct FabIndeterminateBar: View {
    var tint: Color = Brand.ember500
    @State private var phase: CGFloat = 0
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            RoundedRectangle(cornerRadius: 2).fill(Brand.line1)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(tint)
                        .frame(width: w * 0.3)
                        .offset(x: phase * w * 1.3 - w * 0.3)
                }
                .clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .frame(height: 3)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}

// MARK: - a key/value row with a copy affordance on hover

struct FabCopyRow: View {
    let key: String
    let value: String
    @State private var hover = false
    @State private var copied = false
    var body: some View {
        HStack(spacing: 8) {
            Text(key.uppercased()).font(.system(size: 9.5, weight: .medium)).kerning(0.6).foregroundStyle(Brand.bone400)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 11.5, weight: .medium, design: .monospaced)).monospacedDigit()
                .foregroundStyle(Brand.bone100).lineLimit(1).textSelection(.enabled)
            if hover || copied {
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9.5)).foregroundStyle(copied ? Brand.success : Brand.bone400)
                }
                .buttonStyle(.plain).help("Copy")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

// MARK: - a workflow step number badge (square, not a pill)

struct FabStepBadge: View {
    let n: Int
    var done: Bool = false
    var active: Bool = false
    var body: some View {
        Text(String(format: "%02d", n))
            .font(.system(size: 9, weight: .heavy, design: .monospaced))
            .foregroundStyle(done ? Brand.emberText : (active ? Brand.ember500 : Brand.bone400))
            .frame(width: 22, height: 18)
            .background(done ? Brand.ember500 : Brand.ink600, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(active && !done ? Brand.ember700 : Brand.line1, lineWidth: 1))
    }
}
