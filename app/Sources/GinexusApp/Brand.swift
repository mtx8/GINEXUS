// Brand.swift — MackTrax design tokens (dark-only), brought into SwiftUI from the canonical
// source of truth (~/.claude/skills/macktrax-design/colors_and_type.css). Tokens only — never
// hardcode a hex outside this file. One accent at a time = ember. No purple/teal/neon/glassmorphism.
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
    static let ink850  = hex(0x0F0F13)   // brand ink-800: recessed surfaces / shroud
    static let ink800  = hex(0x14141A)   // EXISTING alias (== brand ink-700 card base); kept for back-compat
    static let ink700  = hex(0x14141A)   // card / panel base
    static let ink600  = hex(0x1A1A22)   // raised card
    static let ink500  = hex(0x232330)   // hover state
    static let ink400  = hex(0x2D2D3C)   // strong divider
    static let line1   = hex(0x1F1F26)   // default 1px hairline
    static let line2   = hex(0x2A2A33)   // hover/focus hairline

    // MARK: bone / text
    static let bone50  = hex(0xF5EFE4)   // primary text
    static let bone100 = hex(0xE9E1D2)
    static let bone200 = hex(0xC9C0AE)   // secondary text
    static let bone300 = hex(0x908778)   // tertiary / metadata
    static let bone400 = hex(0x5E5749)   // disabled / placeholder
    static let muted   = hex(0x8A867C)   // EXISTING alias (≈ bone-300)

    // MARK: ember (the single locking accent)
    static let ember300 = hex(0xEFA862)
    static let ember400 = hex(0xE8943C)
    static let ember500 = hex(0xE08A2A)  // PRIMARY accent
    static let ember600 = hex(0xBD6F1A)
    static let ember700 = hex(0x8E5210)

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

    // MARK: gradients
    /// Brushed-metal plate for large display type (background-clip:text equivalent).
    static let chromePlate = LinearGradient(
        colors: [hex(0xFFFFFF), hex(0xD6D6D6), hex(0x8A8A8A), hex(0xC8C8C8), hex(0xF4F4F4)],
        startPoint: .top, endPoint: .bottom)
    /// Conic ember nexus glyph fill (the GiNexus mark).
    static let emberConic = AngularGradient(
        colors: [ember500, ember600, ember700, ember500],
        center: .center, angle: .degrees(220))
    /// Faint top-of-canvas ember atmosphere (tasteful, not neon).
    static let canvasGlow = RadialGradient(
        colors: [ember500.opacity(0.06), .clear],
        center: .init(x: 0.5, y: -0.1), startRadius: 0, endRadius: 520)

    // MARK: motion
    static let ease = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.2)
    static func ease(_ d: Double) -> Animation { .timingCurve(0.22, 1, 0.36, 1, duration: d) }

    // MARK: type — system approximations of the brand families
    /// Trade-Gothic-Condensed stand-in: condensed bold (display stamps, eyebrows, wordmark).
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight).width(.condensed)
    }
    /// Franklin-Gothic stand-in: the workhorse body face.
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// JetBrains-Mono stand-in: code, paths, metrics.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - reusable brand UI

/// An all-caps tracked-out section label (the tactical "eyebrow") — monospace, like a HUD readout.
/// `tick: true` prepends a small ember bar (the OMNISCIENT "┃ DATA LAYERS" treatment).
struct Eyebrow: View {
    let text: String
    var color: Color = Brand.bone300
    var tick: Bool = false
    var body: some View {
        HStack(spacing: 6) {
            if tick { Rectangle().fill(Brand.ember500).frame(width: 2, height: 11) }
            Text(text.uppercased())
                .font(Brand.mono(10.5, weight: .bold)).kerning(1.4)
                .foregroundStyle(color)
        }
    }
}

/// HUD corner-accent ticks (L-shaped marks at the four corners) — the tactical panel signature.
struct CornerAccents: View {
    var color: Color = Brand.line2
    var len: CGFloat = 9
    var inset: CGFloat = 3
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            Path { p in
                // top-left
                p.move(to: .init(x: inset, y: inset + len)); p.addLine(to: .init(x: inset, y: inset)); p.addLine(to: .init(x: inset + len, y: inset))
                // top-right
                p.move(to: .init(x: w - inset - len, y: inset)); p.addLine(to: .init(x: w - inset, y: inset)); p.addLine(to: .init(x: w - inset, y: inset + len))
                // bottom-left
                p.move(to: .init(x: inset, y: h - inset - len)); p.addLine(to: .init(x: inset, y: h - inset)); p.addLine(to: .init(x: inset + len, y: h - inset))
                // bottom-right
                p.move(to: .init(x: w - inset - len, y: h - inset)); p.addLine(to: .init(x: w - inset, y: h - inset)); p.addLine(to: .init(x: w - inset, y: h - inset - len))
            }
            .stroke(color, lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// A tactical button label style — thin outline, monospace caps, small radius. `filled` = ember CTA.
struct TacticalLabel: View {
    let text: String
    var icon: String? = nil
    var filled: Bool = false
    var tint: Color = Brand.bone200
    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
            Text(text.uppercased()).font(Brand.mono(10.5, weight: .bold)).kerning(1.2)
        }
        .foregroundStyle(filled ? Brand.ink900 : tint)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(filled ? Brand.ember500 : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(filled ? Color.clear : Brand.line2, lineWidth: 1))
    }
}

/// The GINEXUS wordmark — ONE word, two-tone: GI (bone) + NEXUS (ember). No italic second word.
struct Wordmark: View {
    var size: CGFloat = 22
    var body: some View {
        HStack(spacing: 0) {
            Text("GI").foregroundStyle(Brand.bone50)
            Text("NEXUS").foregroundStyle(Brand.ember500)
        }
        .font(Brand.display(size, weight: .heavy)).kerning(0.5)
    }
}

/// The abstract ember nexus app glyph (no text/name — per the no-name-on-logo rule).
struct GlyphMark: View {
    var size: CGFloat = 26
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(Brand.emberConic)
            RoundedRectangle(cornerRadius: size * 0.3 - 2, style: .continuous)
                .fill(Brand.ink900).padding(2.5)
            // 6-point nexus starburst in ember.
            ForEach(0..<6, id: \.self) { i in
                Capsule().fill(Brand.ember500)
                    .frame(width: 1.6, height: size * 0.42)
                    .offset(y: -size * 0.0)
                    .rotationEffect(.degrees(Double(i) * 60))
            }
            Circle().fill(Brand.ember300).frame(width: size * 0.16, height: size * 0.16)
        }
        .frame(width: size, height: size)
    }
}

/// The canonical brand panel — a recessed card with a hairline border + inset top highlight.
struct Panel<Content: View>: View {
    var title: String? = nil
    var accessory: AnyView? = nil
    var padding: CGFloat = 14
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || accessory != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title { Eyebrow(text: title) }
                    Spacer(minLength: 0)
                    if let accessory { accessory }
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(padding)
        .background(Brand.ink850)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Brand.line2, lineWidth: 1))
        .overlay(CornerAccents())   // tactical HUD corner ticks
    }
}

/// A small status dot (connection / capability state).
struct StatusDot: View {
    var color: Color
    var glow: Bool = false
    var size: CGFloat = 7
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .shadow(color: glow ? color.opacity(0.7) : .clear, radius: glow ? 5 : 0)
    }
}
