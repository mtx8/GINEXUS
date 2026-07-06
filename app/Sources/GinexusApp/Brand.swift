// Brand.swift — MackTrax design tokens (dark-only), Silo Unison edition.
// The look: flat matte ink surfaces (ink900 canvas → ink700 panels), warm bone text, ONE ember
// accent used sparingly, solid #26262E hairlines (1px), a single brand easing curve. NO shadows,
// NO materials/blur, NO gradients — depth comes from the surface ramp + hairline only. Tokens only
// — never hardcode a hex outside this file. One accent at a time = ember; Hinomaru red is hover-
// only on destructive affordances.
import SwiftUI

enum Brand {
    private static func hex(_ v: UInt) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255,
              green: Double((v >> 8) & 0xFF) / 255,
              blue: Double(v & 0xFF) / 255)
    }

    // MARK: ink / surface ramp (Silo Unison values)
    static let ink1000 = hex(0x050507)   // deepest — vignette extremes / scrims
    static let ink900  = hex(0x0A0A0C)   // PRIMARY canvas (never pure black)
    static let ink850  = hex(0x0A0A0C)   // side panels sit on clean canvas (Silo Unison: two surface tones only)
    static let ink800  = hex(0x131318)   // EXISTING alias (== panel base); kept for back-compat
    static let ink700  = hex(0x131318)   // panel base (cards, fields, chips)
    static let ink600  = hex(0x1A1A22)   // raised card / selected fill
    static let ink500  = hex(0x232330)   // hover / active pill
    static let ink400  = hex(0x2D2D3C)   // strong divider / inactive dot
    /// Universal hairline — solid #26262E, 1px.
    static let line1   = hex(0x26262E)
    /// Hover/focus hairline — one step brighter.
    static let line2   = hex(0x34343E)

    // MARK: bone / text
    static let bone50  = hex(0xF5EFE4)   // primary body text (never pure white)
    static let bone100 = hex(0xE9E1D2)
    static let bone200 = hex(0xB4B4BE)   // secondary text (cool step above dim)
    static let bone300 = hex(0x8B8B96)   // dim / metadata / stamp headers (Silo dim gray)
    static let bone400 = hex(0x5C5C66)   // disabled / placeholder
    static let muted   = hex(0x8B8B96)   // EXISTING alias (== bone-300)

    // MARK: ember (the single locking accent)
    static let ember300 = hex(0xEFA862)
    static let ember400 = hex(0xEDA23F)  // hover/bright variant
    static let ember500 = hex(0xE08A2A)  // PRIMARY accent
    static let ember600 = hex(0xBD6F1A)
    static let ember700 = hex(0xB56F1E)  // accent border/stroke (Silo Unison focus-ring ember)
    /// Dark text sat ON a solid-ember button — near-black warm ink.
    static let emberText = hex(0x141005)

    // MARK: cultural / support (sparing — NOT normal UI)
    static let hi500  = hex(0xD8233A)    // Hinomaru red — Japan/Okinawa callouts ONLY
    static let sea500 = hex(0x2E6F84)    // Ryukyu sea — subtle support
    static let sea300 = hex(0x6FA8B8)

    // MARK: cyan — the OMNISCIENT live-data accent, scoped to the FABRICATION console.
    // Law (OMNISCIENT native grammar): cyan marks LIVE DATA VALUES only — telemetry numbers,
    // progress, rising counts. Never on buttons, nav, or chrome (that stays ember). One accent
    // per element; ember and cyan never color the same glyph.
    static let cyan500 = hex(0x00E5FF)   // live-data value / active telemetry
    static let cyan300 = hex(0x7FF2FF)   // bright variant (emphasized value)
    static let cyan700 = hex(0x00A8BC)   // dimmed track/edge for cyan elements

    // MARK: chrome (headline metal)
    static let chrome100 = hex(0xF2F2F2)
    static let chrome300 = hex(0xB8B8B8)

    // MARK: semantic status
    static let success = hex(0x36D399)
    static let warning = hex(0xF4C430)
    static let error   = hex(0xFF6565)
    static let ok      = hex(0x5AC08A)   // EXISTING alias (connection dot)

    // MARK: flat surface aliases (the gradient era is over — these stay for call-site compat)
    /// Card fill — flat panel base. (Formerly a gradient; flat by design now.)
    static let cardFill = ink700
    /// Floating-panel fill — flat recessed surface.
    static let panelFill = ink850

    // MARK: motion — ONE brand curve for everything
    static let ease = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.45)
    static func ease(_ d: Double) -> Animation { .timingCurve(0.22, 1, 0.36, 1, duration: d) }

    // MARK: type — system faces, Counterpart grammar
    /// Display stamps / wordmark: heavy system, wide-kerned all-caps at the call site.
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight)
    }
    /// The workhorse body face.
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// Monospaced: code, paths, model tags, metrics — content that IS code-shaped.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - reusable brand UI

/// The section header stamp — small, semibold, UPPERCASE, wide-kerned, dim gray — with an optional
/// ONE word rendered in ember (`ember:`), per the Silo Unison header grammar.
struct StampText: View {
    let text: String
    var size: CGFloat = 12
    var color: Color = Brand.bone300
    /// One word of `text` (case-insensitive) to render in ember. One accent word, never more.
    var ember: String? = nil
    var body: some View {
        Text(composed)
            .font(.system(size: size, weight: .semibold))
            .kerning(max(2.4, size * 0.28))
    }
    /// Built as one `AttributedString` (per-run colors) — no deprecated `Text + Text` concatenation.
    private var composed: AttributedString {
        let caps = text.uppercased()
        guard let ember, !ember.isEmpty else {
            var s = AttributedString(caps); s.foregroundColor = color; return s
        }
        let target = ember.uppercased()
        var out = AttributedString()
        let words = caps.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        for (i, w) in words.enumerated() {
            if i > 0 { var sep = AttributedString(" "); sep.foregroundColor = color; out += sep }
            var piece = AttributedString(w)
            piece.foregroundColor = (w == target ? Brand.ember500 : color)
            out += piece
        }
        return out
    }
}

/// Back-compat section label — now renders as the brand stamp (the HUD/mono eyebrow is retired).
struct Eyebrow: View {
    let text: String
    var color: Color = Brand.bone300
    var tick: Bool = false   // retired — kept for call-site compat, renders nothing extra
    var body: some View {
        StampText(text: text, size: 11, color: color)
    }
}

/// A capsule pill button label — `filled` = solid-ember CTA (dark emberText, uppercase, hover
/// brightens to ember400), else a bordered ink chip with bone text.
struct TacticalLabel: View {
    let text: String
    var icon: String? = nil
    var filled: Bool = false
    var tint: Color = Brand.bone200
    @State private var hover = false
    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
            Text(text.uppercased()).font(.system(size: 11.5, weight: .semibold)).kerning(0.8)
        }
        .foregroundStyle(filled ? Brand.emberText : tint)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(filled ? (hover ? Brand.ember400 : Brand.ember500)
                           : (hover ? Brand.ink500 : Brand.ink600), in: Capsule())
        .overlay(Capsule().stroke(filled ? Color.clear : (hover ? Brand.line2 : Brand.line1), lineWidth: 1))
        .onHover { h in withAnimation(Brand.ease(0.15)) { hover = h } }
    }
}

/// The canonical PRIMARY button — solid ember capsule, dark emberText, UPPERCASE 12pt semibold with
/// slight letterspacing; hover brightens the fill to ember400. Disabled = flat ink pill.
struct EmberButton: View {
    let title: String
    var icon: String? = nil
    var enabled: Bool = true
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                Text(title.uppercased()).font(.system(size: 12, weight: .semibold)).kerning(0.8)
            }
            .foregroundStyle(enabled ? Brand.emberText : Brand.bone400)
            .padding(.horizontal, 18).padding(.vertical, 8)
            .background(enabled ? (hover ? Brand.ember400 : Brand.ember500) : Brand.ink500, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).disabled(!enabled)
        .onHover { h in withAnimation(Brand.ease(0.15)) { hover = h && enabled } }
    }
}

/// Destructive icon affordance — quiet gray that turns Hinomaru red ONLY on hover (the single
/// permitted use of hi500 in normal UI).
struct DestructiveIconButton: View {
    var icon: String = "trash"
    var size: CGFloat = 12
    var help: String = "Delete"
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size))
                .foregroundStyle(hover ? Brand.hi500 : Brand.bone400)
        }
        .buttonStyle(.plain).help(help)
        .onHover { h in withAnimation(Brand.ease(0.15)) { hover = h } }
    }
}

/// Thin linear progress — 4pt ember bar on the hairline-color track. The ONLY determinate bar.
struct ThinProgressBar: View {
    var value: Double          // 0…1
    var height: CGFloat = 4
    var tint: Color = Brand.ember500
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.line1)
                Capsule().fill(tint).frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: height)
        .animation(Brand.ease(0.3), value: value)
    }
}

/// The GINEXUS wordmark — TWO tones, one line: "GI" in bone, "NEXUS" in ember.
struct Wordmark: View {
    var size: CGFloat = 22
    var color: Color = Brand.ember500
    var body: some View {
        HStack(spacing: 0) {
            Text("GI").foregroundStyle(Brand.bone50)
            Text("NEXUS").foregroundStyle(color)
        }
        .font(.system(size: size, weight: .heavy))
        .kerning(max(1.6, size * 0.14))
        .lineLimit(1)                                  // the wordmark is ONE line, always
        .fixedSize(horizontal: true, vertical: false)  // never compress/wrap on a tight header
    }
}

/// The abstract ember nexus app glyph (no text/name, NO box). A clean 8-point ember starburst —
/// the GINEXUS mark, used bigger in the rail.
struct GlyphMark: View {
    var size: CGFloat = 26
    /// When true the mark slowly rotates + breathes — the "GINEXUS is thinking / loading" state.
    var spinning: Bool = false
    @State private var angle: Double = 0
    @State private var pulse = false
    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                Capsule().fill(Brand.ember500)
                    .frame(width: size * 0.055, height: size * 0.92)
                    .rotationEffect(.degrees(Double(i) * 45))
            }
            Circle().fill(Brand.ember300).frame(width: size * 0.2, height: size * 0.2)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(angle))
        .scaleEffect(pulse ? 1.07 : 1.0)
        .opacity(pulse ? 1.0 : (spinning ? 0.85 : 1.0))   // breathe by opacity — no glow shadows
        .onAppear { if spinning { start() } }
        .onChange(of: spinning) { _, on in if on { start() } else { stop() } }
    }
    private func start() {
        // Reset instantly (0° ≡ 360° for the 8-fold mark, so invisible), THEN spin.
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { angle = 0 }
        withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { angle = 360 }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
    }
    private func stop() {
        // CHANGE the value (360 → 0) with animations OFF — this cancels the repeatForever (setting
        // it back to 360 would be a no-op and the spin would never stop). 360≡0, so no visible jump.
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { angle = 0 }
        withAnimation(.easeOut(duration: 0.3)) { pulse = false }
    }
}

/// The canonical brand panel — a flat matte card with a hairline border. No sheen, no shadow.
struct Panel<Content: View>: View {
    var title: String? = nil
    var accessory: AnyView? = nil
    var padding: CGFloat = 14
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || accessory != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title { StampText(text: title, size: 11) }
                    Spacer(minLength: 0)
                    if let accessory { accessory }
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(padding)
        .background(Brand.ink700, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.line1, lineWidth: 1))
    }
}

/// An execution-stream activity card — a labeled block (Action / Final Output). Flat ink surface,
/// hairline border; the border warms to ember while the step is live. No gradients, no shadows.
struct BlockCard<Content: View>: View {
    let label: String
    var icon: String? = nil
    var accent: Color = Brand.bone300
    var active: Bool = false
    /// Pulse the header icon — used by the live "what GINEXUS is doing now" card.
    var iconAnimating: Bool = false
    @State private var pulse = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                        .scaleEffect(iconAnimating && pulse ? 1.22 : 1.0)
                        .opacity(iconAnimating && !pulse ? 0.55 : 1.0)
                        .onAppear {
                            if iconAnimating {
                                withAnimation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true)) { pulse = true }
                            }
                        }
                        .onChange(of: iconAnimating) { _, on in
                            if on {
                                withAnimation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true)) { pulse = true }
                            } else {
                                withAnimation(.easeOut(duration: 0.2)) { pulse = false }   // settle when the step completes
                            }
                        }
                }
                Text(label.uppercased()).font(.system(size: 10, weight: .heavy)).kerning(2.2).foregroundStyle(accent)
                Spacer(minLength: 0)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(Brand.ink700, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(active ? Brand.ember700 : Brand.line1, lineWidth: 1))
    }
}

/// A small status dot (connection / capability state). Glow = a soft ring, never a shadow.
struct StatusDot: View {
    var color: Color
    var glow: Bool = false
    var size: CGFloat = 7
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .overlay(Circle().stroke(color.opacity(glow ? 0.35 : 0), lineWidth: 2).padding(-2))
    }
}

/// A sidebar navigation row (Counterpart rail item): icon + label, radius-8. Selected = raised ink
/// fill + ember icon; hover = one ink step up.
struct RailItem: View {
    let icon: String
    let label: String
    var selected: Bool = false
    var hovered: Bool = false
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 12))
                .foregroundStyle(selected ? Brand.ember500 : Brand.bone300).frame(width: 16)
            Text(label).font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Brand.bone50 : Brand.bone200)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(selected ? Brand.ink600 : (hovered ? Brand.ink700 : .clear),
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}

/// A small inline capsule chip (composer controls, meta badges): icon + label on raised ink.
struct BrandChip: View {
    var icon: String? = nil
    let label: String
    var tint: Color = Brand.bone300
    var filled: Bool = false
    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
            Text(label).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(filled ? Brand.emberText : tint)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(filled ? Brand.ember500 : Brand.ink600, in: Capsule())
        .overlay(Capsule().stroke(filled ? Color.clear : Brand.line1, lineWidth: 1))
    }
}
