// Generate the GINEXUS app icon (1024×1024 PNG) per the MackTrax brand:
// ink-900 panel · brushed-chrome "GX" monogram · ember-500 accent. No deps (AppKit + CoreText).
// Run: swift make_icon.swift <out.png>
import AppKit
import CoreText

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let S: CGFloat = 1024

// ---- Brand tokens (from colors_and_type.css) ----
func c(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
let ink600 = c(0x1A1A22), ink900 = c(0x0A0A0C), ink1000 = c(0x050507)
let ember500 = c(0xE08A2A)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// ---- 1. Rounded-rect ink panel with a vertical depth gradient ----
let inset: CGFloat = 36
let panel = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let radius: CGFloat = 224
let panelPath = CGPath(roundedRect: panel, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.saveGState()
ctx.addPath(panelPath)
ctx.clip()
let inkGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                         colors: [ink600.cgColor, ink900.cgColor, ink1000.cgColor] as CFArray,
                         locations: [0.0, 0.55, 1.0])!
ctx.drawLinearGradient(inkGrad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
// soft top highlight for depth
let hl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [NSColor(white: 1, alpha: 0.06).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                    locations: [0.0, 1.0])!
ctx.drawLinearGradient(hl, start: CGPoint(x: 0, y: S - inset), end: CGPoint(x: 0, y: S * 0.6), options: [])
ctx.restoreGState()

// ---- 2. Abstract "nexus" starburst (NO text/name): chrome bladed star around an ember core ----
let cx = panel.midX, cy = panel.midY
let rCard = S * 0.355   // cardinal blade reach (N/E/S/W)
let rDiag = S * 0.225   // diagonal blade reach (corners)
let rIn   = S * 0.072   // concave inner radius between blades

let star = CGMutablePath()
// 16 vertices: alternating outer (8 directions, cardinal long / diagonal short) and inner concave.
for k in 0..<16 {
    let ang = Double(k) * (.pi / 8.0) + .pi / 2.0   // start pointing up
    let isOuter = (k % 2 == 0)
    let dir = k / 2                                   // 0..7 outer direction index
    let r: CGFloat
    if isOuter { r = (dir % 2 == 0) ? rCard : rDiag } else { r = rIn }
    let p = CGPoint(x: cx + cos(ang) * r, y: cy + sin(ang) * r)
    if k == 0 { star.move(to: p) } else { star.addLine(to: p) }
}
star.closeSubpath()

// drop shadow under the blades for separation from the panel
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 36, color: NSColor(white: 0, alpha: 0.55).cgColor)
ctx.addPath(star); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()

// brushed-chrome fill, clipped to the star
ctx.saveGState()
ctx.addPath(star)
ctx.clip()
let chrome = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [c(0xF7F2E8).cgColor, c(0xC9C0AE).cgColor, c(0x6E6658).cgColor,
                                 c(0xC2B9A7).cgColor, c(0xEDE6D8).cgColor] as CFArray,
                        locations: [0.0, 0.42, 0.52, 0.62, 1.0])!
ctx.drawLinearGradient(chrome, start: CGPoint(x: cx, y: cy + rCard), end: CGPoint(x: cx, y: cy - rCard), options: [])
ctx.restoreGState()

// ---- 3. Ember core node at the convergence point (the locking accent) ----
let coreR = S * 0.058
let core = CGRect(x: cx - coreR, y: cy - coreR, width: coreR * 2, height: coreR * 2)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 30, color: ember500.withAlphaComponent(0.8).cgColor) // ember glow
ctx.addPath(CGPath(ellipseIn: core, transform: nil))
ctx.setFillColor(ember500.cgColor)
ctx.fillPath()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
