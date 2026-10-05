import AppKit
import SwiftUI

/// Design tokens: a warm parchment canvas (warm charcoal in dark mode), ink text, hairline
/// warm-gray borders, and a single deep teal used only for selected states and the
/// focused-input glow. Flat surfaces, softly rounded corners, weights 400–500 only, compact
/// 4 pt spacing.
enum Theme {
    // Colors — each has a light (parchment) and a dark (warm charcoal) value.
    static let parchment = Color(light: 0xFAF8F5, dark: 0x1B1A17)   // canvas
    static let softPaper = Color(light: 0xFDFBFA, dark: 0x24231F)   // cards, one step above the canvas
    static let warmMist = Color(light: 0xD1D1CD, dark: 0x3A3833)    // hairline borders
    static let ash = Color(light: 0x92918B, dark: 0x7F7D76)         // helper text, timestamps
    static let graphite = Color(light: 0x72706B, dark: 0xA9A69E)    // secondary text and icons
    static let ink = Color(light: 0x27251E, dark: 0xECE9E2)         // primary text, filled buttons
    static let teal = Color(light: 0x016A71, dark: 0x13818A)        // selected state only
    /// Text on a filled (ink) button: the canvas color, so the pair inverts in dark mode.
    static let onInk = parchment
    /// Card outline: invisible on parchment, a faint line on charcoal.
    static let cardEdge = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: 0x312F2B) : .clear
    })
    /// Focused input outline: soft teal on parchment, a brighter teal on charcoal.
    static let focusRing = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(hex: 0x2BA3AC)
            : NSColor(hex: 0x016A71).withAlphaComponent(0.5)
    })
    /// Text on a teal fill.
    static let onTeal = Color.white

    // Radii: softly rounded rectangles rather than pills.
    static let cardRadius: CGFloat = 10
    static let inputRadius: CGFloat = 8
    static let controlRadius: CGFloat = 8   // pill buttons
    static let chipRadius: CGFloat = 6
    static let buttonRadius: CGFloat = 6    // ghost buttons

    // Spacing (4 pt base)
    static let gap: CGFloat = 8
    static let cardPadding: CGFloat = 16
    static let sectionGap: CGFloat = 32

    // Type: the system font stands in for the reference's geometric sans.
    static let caption = Font.system(size: 11, weight: .medium)
    static let small = Font.system(size: 12)
    static let body = Font.system(size: 14)
    static let bodyLarge = Font.system(size: 16)
    static let label = Font.system(size: 14, weight: .medium)
    static let title = Font.system(size: 16, weight: .medium)
    static let timestamp = Font.system(size: 12).monospacedDigit()

    static func shape(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }

    /// A color that follows the light/dark appearance of the view it is drawn in.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension View {
    /// A card surface: soft paper, 10 pt corners, the system's single subtle shadow, and a
    /// hairline edge that only shows in dark mode (where the shadow can't).
    func cardSurface() -> some View {
        self
            .background(Theme.softPaper, in: Theme.shape(Theme.cardRadius))
            .overlay(Theme.shape(Theme.cardRadius).strokeBorder(Theme.cardEdge))
            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
    }

    func card(padding: CGFloat = Theme.cardPadding) -> some View {
        self.padding(padding).cardSurface()
    }

    /// The app's surface: parchment canvas and ink text. Light or dark comes from the
    /// Appearance setting (applied app-wide).
    func parchmentSurface() -> some View {
        self
            .font(Theme.body)
            .foregroundStyle(Theme.ink)
            .tint(Theme.teal)
            .background(Theme.parchment)
    }
}
