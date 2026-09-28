import SwiftUI
import CoreText

/// "Midnight Glass" design system. See DESIGN.md at the repo root.
/// Palette: near-black canvas, one teal/aqua orb palette (from the brand orb), hairline glass.
enum Theme {
    // Canvas
    static let canvas = Color(hex: 0x060709)
    static let canvasRaised = Color(hex: 0x0D0F13)
    static let surface = Color(hex: 0x13161B)

    // Orb palette (atmosphere + agent identity only; never used as large fills)
    static let teal = Color(hex: 0x0E9AA7)
    static let aqua = Color(hex: 0xA8F0E8)
    static let ice = Color(hex: 0xF2FFFD)
    static let iris = Color(hex: 0x512F7F)
    static let violet = Color(hex: 0x7B61FF)

    // Semantics
    static let accept = Color(hex: 0x2FD37F)
    static let danger = Color(hex: 0xFF4757)
    static let warning = Color(hex: 0xFFB547)

    // Ink
    static let ink = Color(hex: 0xF4F7F6)
    static let body = Color(hex: 0xF4F7F6).opacity(0.72)
    static let muted = Color(hex: 0xF4F7F6).opacity(0.46)
    static let faint = Color(hex: 0xF4F7F6).opacity(0.26)

    // Glass
    static let hairline = Color.white.opacity(0.09)
    static let hairlineStrong = Color.white.opacity(0.16)
    static let shell = Color.white.opacity(0.035)
    static let core = Color.white.opacity(0.055)

    // Radii (concentric: inner = outer - padding)
    static let radiusShell: CGFloat = 30
    static let bezel: CGFloat = 6
    static var radiusCore: CGFloat { radiusShell - bezel }
}

enum Typo {
    private static var registered = false

    /// Registers the bundled open-source fonts (Geist, Instrument Serif; SIL OFL).
    static func registerFonts() {
        guard !registered else { return }
        registered = true
        for name in ["Geist-Variable", "InstrumentSerif-Regular", "InstrumentSerif-Italic"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    /// Geist for UI text, with the slightly open tracking of an editorial body.
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font.custom("Geist", size: size).weight(weight)
    }

    /// Instrument Serif for display moments (agent name, greetings).
    static func serif(_ size: CGFloat, italic: Bool = false) -> Font {
        Font.custom(italic ? "InstrumentSerif-Italic" : "InstrumentSerif-Regular", size: size)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

enum Motion {
    static let spring = Animation.spring(response: 0.55, dampingFraction: 0.84)
    static let snappy = Animation.spring(response: 0.34, dampingFraction: 0.8)
    static let gentle = Animation.spring(response: 0.9, dampingFraction: 0.9)
    static let bouncy = Animation.spring(response: 0.5, dampingFraction: 0.62)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Tiny uppercase label above headings ("MEET YOUR ASSISTANT").
struct Eyebrow: View {
    let text: String
    var tint: Color = Theme.aqua
    var body: some View {
        Text(text.uppercased())
            .font(Typo.sans(10.5, .semibold))
            .tracking(1.6)
            .foregroundStyle(tint.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(tint.opacity(0.08)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.18), lineWidth: 0.5))
    }
}
