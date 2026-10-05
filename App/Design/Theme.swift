import AppKit
import SwiftUI

/// One complete set of theme colors.
struct Palette {
    var parchment: Color   // canvas
    var softPaper: Color   // cards, one step above the canvas
    var warmMist: Color    // hairline borders
    var ash: Color         // helper text, timestamps
    var graphite: Color    // secondary text and icons
    var ink: Color         // primary text
    var teal: Color        // selected-state fill (chips)
    var onTeal: Color      // text on the selected fill
    var fill: Color        // filled buttons
    var fillHover: Color   // filled buttons on hover/press
    var onFill: Color      // text and waveform on filled buttons
    var accent: Color      // system controls: toggles, progress bars, pickers
    var focusRing: Color   // focused input outline
    var cardEdge: Color    // card outline
    var hoverFill: Color   // chips and ghost buttons on hover/press

    /// Parchment in light mode, warm charcoal in dark mode (follows the window appearance).
    static let standard = Palette(
        parchment: Color(light: 0xFAF8F5, dark: 0x1B1A17),
        softPaper: Color(light: 0xFDFBFA, dark: 0x24231F),
        warmMist: Color(light: 0xD1D1CD, dark: 0x3A3833),
        ash: Color(light: 0x92918B, dark: 0x7F7D76),
        graphite: Color(light: 0x72706B, dark: 0xA9A69E),
        ink: Color(light: 0x27251E, dark: 0xECE9E2),
        teal: Color(light: 0x016A71, dark: 0x13818A),
        onTeal: .white,
        fill: Color(light: 0x27251E, dark: 0xECE9E2),
        fillHover: Color(light: 0x27251E, dark: 0xECE9E2),
        onFill: Color(light: 0xFAF8F5, dark: 0x1B1A17),
        accent: Color(light: 0x016A71, dark: 0x13818A),
        focusRing: Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor(hex: 0x2BA3AC) : NSColor(hex: 0x016A71).withAlphaComponent(0.5)
        }),
        cardEdge: Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor(hex: 0x312F2B) : .clear
        }),
        hoverFill: Color(light: 0xD1D1CD, dark: 0x3A3833).opacity(0.35)
    )

    /// Rose palette: #FADAD9 #F3C3C5 #E9ABAE #E0959C #D78289 #CE6F79 #C65C69, plus a light
    /// card tint and deep rose text tones (the palette has no dark shade for readable text).
    static let pink = Palette(
        parchment: Color(hex: 0xFADAD9),
        softPaper: Color(hex: 0xFDEFEE),
        warmMist: Color(hex: 0xE9ABAE),
        ash: Color(hex: 0xC65C69),
        graphite: Color(hex: 0x7E3440),
        ink: Color(hex: 0x3D1A20),
        teal: Color(hex: 0xE0959C),
        onTeal: Color(hex: 0x3D1A20),
        fill: Color(hex: 0xC65C69),
        fillHover: Color(hex: 0xCE6F79),
        onFill: .white,
        accent: Color(hex: 0xC65C69),
        focusRing: Color(hex: 0xD78289),
        cardEdge: Color(hex: 0xF3C3C5),
        hoverFill: Color(hex: 0xF3C3C5)
    )
}

/// The active palette. Views read it through `Theme`, so Observation redraws them when the
/// Appearance setting switches palettes.
@MainActor @Observable
final class ThemeStore {
    static let shared = ThemeStore()
    var palette = Palette.standard
}

/// Design tokens: a warm canvas, ink text, hairline borders, softly rounded corners, and a
/// single accent used only for selected states and the focused-input glow. Flat surfaces,
/// weights 400–500 only, compact 4 pt spacing. Colors come from the active `Palette`.
@MainActor
enum Theme {
    private static var palette: Palette { ThemeStore.shared.palette }

    static var parchment: Color { palette.parchment }
    static var softPaper: Color { palette.softPaper }
    static var warmMist: Color { palette.warmMist }
    static var ash: Color { palette.ash }
    static var graphite: Color { palette.graphite }
    static var ink: Color { palette.ink }
    static var teal: Color { palette.teal }
    static var onTeal: Color { palette.onTeal }
    static var fill: Color { palette.fill }
    static var fillHover: Color { palette.fillHover }
    static var onInk: Color { palette.onFill }
    static var accent: Color { palette.accent }
    static var focusRing: Color { palette.focusRing }
    static var cardEdge: Color { palette.cardEdge }
    static var hoverFill: Color { palette.hoverFill }

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
            appearance.isDark ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
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

@MainActor
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
            .tint(Theme.accent)
            .background(Theme.parchment)
    }
}
