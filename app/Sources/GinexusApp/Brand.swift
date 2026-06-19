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
    /// Subtle top→bottom card fill — clean modern depth (a slightly raised ink top settling into the
    /// card base). Neutral (no blue/teal) so the ember accent stays the only color.
    static let cardFill = LinearGradient(
        colors: [hex(0x1C1C25), hex(0x121217)],
        startPoint: .top, endPoint: .bottom)
    /// Even subtler, slightly translucent — for the big floating side panels that sit over the canvas.
    static let panelFill = LinearGradient(
        colors: [hex(0x16161D).opacity(0.92), hex(0x0E0E12).opacity(0.92)],
        startPoint: .top, endPoint: .bottom)
    /// A 1px inset top sheen drawn over a card for the "lit from above" modern look.
    static let topSheen = LinearGradient(
        colors: [Color.white.opacity(0.06), .clear],
        startPoint: .top, endPoint: .bottom)

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

/// The GINEXUS wordmark — ONE word, ONE color (the brand ember logotype).
struct Wordmark: View {
    var size: CGFloat = 22
    var color: Color = Brand.ember500
    var body: some View {
        Text("GINEXUS").foregroundStyle(color)
            .font(Brand.display(size, weight: .heavy)).kerning(0.5)
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
        .shadow(color: Brand.ember500.opacity(pulse ? 0.5 : 0), radius: pulse ? size * 0.16 : 0)
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
        .background(Brand.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .top) { Brand.topSheen.frame(height: 1).clipShape(RoundedRectangle(cornerRadius: 12)) }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.line1, lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 6)   // soft luxe depth, not gimmicky
    }
}

/// A clean, luxurious execution-stream card — a labeled block (User Input / Agent Thought / Action /
/// Final Output). Soft fill, hairline border, gentle depth; an ember left-tab marks the active block.
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
        VStack(alignment: .leading, spacing: 11) {
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
                Text(label.uppercased()).font(Brand.mono(10, weight: .semibold)).kerning(1.4).foregroundStyle(accent)
                Spacer(minLength: 0)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18).padding(.vertical, 15)
        .background(Brand.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .top) { Brand.topSheen.frame(height: 1).clipShape(RoundedRectangle(cornerRadius: 14)) }
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(active ? Brand.ember500.opacity(0.45) : Brand.line1, lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 16, x: 0, y: 7)
    }
}

/// A modern FLOATING side panel — a rounded, slightly translucent dark card with a header
/// (title + collapse chevron), hairline border, top highlight, and a soft drop shadow so it floats
/// over the canvas. Matches the OMNISCIENT side-panel design.
struct FloatingPanel<Content: View>: View {
    let title: String
    var collapseIcon: String = "chevron.left"
    var onCollapse: (() -> Void)? = nil
    var headerAccessory: AnyView? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(title.uppercased()).font(Brand.mono(11, weight: .bold)).kerning(1.5).foregroundStyle(Brand.bone200)
                Spacer(minLength: 8)
                if let headerAccessory { headerAccessory }
                if let onCollapse {
                    Button(action: onCollapse) {
                        Image(systemName: collapseIcon).font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.bone400)
                    }.buttonStyle(.plain).help("Collapse")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            Divider().overlay(Brand.line1)
            content()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // Subtle top→bottom gradient fill (clean, modern depth) over the canvas.
        .background(Brand.panelFill)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .top) { Brand.topSheen.frame(height: 1).clipShape(RoundedRectangle(cornerRadius: 16)) }
        // Thin, bright hairline border.
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 22, x: 0, y: 10)
    }
}

/// A small floating tab shown when a panel is collapsed — a rotated label + expand chevron. Compact
/// (intrinsic height, vertically centered by its column), so a hidden panel reads as a short pill,
/// not a full-height bar. Same subtle-fill / bright-hairline language as the expanded panel.
struct CollapsedTab: View {
    let label: String
    var expandIcon: String = "chevron.right"
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: expandIcon).font(.system(size: 10, weight: .semibold))
                Text(label.uppercased()).font(Brand.mono(9.5, weight: .bold)).kerning(2)
                    .fixedSize().rotationEffect(.degrees(-90)).frame(width: 14, height: 64)
            }
            .foregroundStyle(Brand.bone300)
            .padding(.vertical, 16)
            .frame(width: 34)
            .background(Brand.ink850.opacity(0.42))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
            .contentShape(Rectangle())   // whole pill is the click target
        }.buttonStyle(.plain).help("Expand")
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
