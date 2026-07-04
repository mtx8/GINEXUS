// Brand.swift — MackTrax design tokens (dark-only), Counterpart-family edition.
// The look: flat matte ink surfaces (ink900→ink500), warm bone text, ONE ember accent,
// 7%-white hairlines, a single brand easing curve. NO shadows, NO materials/blur, NO gradients —
// depth comes from the surface ramp + hairline only. Tokens only — never hardcode a hex outside
// this file. One accent at a time = ember.
import SwiftUI

enum Brand {
    private static func hex(_ v: UInt) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255,
              green: Double((v >> 8) & 0xFF) / 255,
              blue: Double(v & 0xFF) / 255)
    }

    // MARK: ink / surface ramp
    static let ink1000 = hex(0x050507)   // deepest — vignette extremes
    static let ink900  = hex(0x0A0A0C)   // PRIMARY canvas (never pure black)
    static let ink850  = hex(0x0F0F13)   // recessed surfaces (sidebar, headers, footers)
    static let ink800  = hex(0x14141A)   // EXISTING alias (== panel base); kept for back-compat
    static let ink700  = hex(0x14141A)   // panel base (cards, fields, chips)
    static let ink600  = hex(0x1A1A22)   // raised card / selected fill
    static let ink500  = hex(0x232330)   // hover / active pill
    static let ink400  = hex(0x2D2D3C)   // strong divider / inactive dot
    /// Universal hairline — 7% white (the Counterpart `Theme.line`).
    static let line1   = Color.white.opacity(0.07)
    /// Hover/focus hairline — one step brighter.
    static let line2   = Color.white.opacity(0.13)

    // MARK: bone / text
    static let bone50  = hex(0xF5EFE4)   // primary text
    static let bone100 = hex(0xE9E1D2)
    static let bone200 = hex(0xC9C0AE)   // secondary text
    static let bone300 = hex(0x908778)   // tertiary / metadata / stamp headers
    static let bone400 = hex(0x5E5749)   // disabled / placeholder
    static let muted   = hex(0x8A867C)   // EXISTING alias (≈ bone-300)

    // MARK: ember (the single locking accent)
    static let ember300 = hex(0xEFA862)
    static let ember400 = hex(0xE8943C)
    static let ember500 = hex(0xE08A2A)  // PRIMARY accent
    static let ember600 = hex(0xBD6F1A)
    static let ember700 = hex(0x8E5210)  // accent border/stroke (dim)

    // MARK: cultural / support (sparing — NOT normal UI)
    static let hi500  = hex(0xD8233A)    // Hinomaru red — Japan/Okinawa callouts ONLY
    static let sea500 = hex(0x2E6F84)    // Ryukyu sea — subtle support
    static let sea300 = hex(0x6FA8B8)

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
    /// Top sheen — retired. Fully transparent so any straggler usage renders nothing.
    static let topSheen = Color.clear
    /// Canvas glow — retired. The canvas is pure matte ink900.
    static let canvasGlow = Color.clear

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

/// The section header stamp — heavy, uppercase, wide-kerned, bone300 (Counterpart `StampText`).
struct StampText: View {
    let text: String
    var size: CGFloat = 12
    var color: Color = Brand.bone300
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .heavy))
            .kerning(2.2)
            .foregroundStyle(color)
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

/// A capsule pill button label — `filled` = solid-ember CTA (ink900 text), else bordered ink chip.
struct TacticalLabel: View {
    let text: String
    var icon: String? = nil
    var filled: Bool = false
    var tint: Color = Brand.bone200
    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
            Text(text).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(filled ? Brand.ink900 : tint)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(filled ? Brand.ember500 : Brand.ink600, in: Capsule())
        .overlay(Capsule().stroke(filled ? Color.clear : Brand.line1, lineWidth: 1))
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
        .background(Brand.ink700, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.line1, lineWidth: 1))
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
        .background(Brand.ink700, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(active ? Brand.ember700.opacity(0.7) : Brand.line1, lineWidth: 1))
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
        .foregroundStyle(filled ? Brand.ink900 : tint)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(filled ? Brand.ember500 : Brand.ink600, in: Capsule())
        .overlay(Capsule().stroke(filled ? Color.clear : Brand.line1, lineWidth: 1))
    }
}
