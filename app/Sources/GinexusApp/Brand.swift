// Brand.swift — MackTrax core tokens (dark-only). The SP2 production UI invokes the full
// macktrax-design skill; this tracer-bullet uses the memorized spine tokens only.
import SwiftUI

enum Brand {
    static let ink900 = Color(red: 0x0A / 255, green: 0x0A / 255, blue: 0x0C / 255)  // canvas, never pure black
    static let ink800 = Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x18 / 255)
    static let bone50 = Color(red: 0xF5 / 255, green: 0xEF / 255, blue: 0xE4 / 255)  // warm off-white text
    static let ember500 = Color(red: 0xE0 / 255, green: 0x8A / 255, blue: 0x2A / 255) // locking accent
    static let muted = Color(red: 0x8A / 255, green: 0x86 / 255, blue: 0x7C / 255)
    static let ok = Color(red: 0x5A / 255, green: 0xC0 / 255, blue: 0x8A / 255)
}
