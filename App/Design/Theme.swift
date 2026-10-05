import SwiftUI

/// Design tokens: a warm parchment canvas, ink text, hairline warm-gray borders, and a single
/// deep teal used only for selected states and the focused-input glow. Flat surfaces, weights
/// 400–500 only, compact 4 pt spacing.
enum Theme {
    // Colors
    static let parchment = Color(hex: 0xFAF8F5)   // canvas
    static let softPaper = Color(hex: 0xFDFBFA)   // cards, one step above the canvas
    static let warmMist = Color(hex: 0xD1D1CD)    // hairline borders
    static let ash = Color(hex: 0x92918B)         // helper text, timestamps
    static let graphite = Color(hex: 0x72706B)    // secondary text and icons
    static let ink = Color(hex: 0x27251E)         // primary text, filled buttons
    static let teal = Color(hex: 0x016A71)        // selected state only

    // Radii
    static let cardRadius: CGFloat = 16
    static let inputRadius: CGFloat = 12
    static let buttonRadius: CGFloat = 6

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
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension View {
    /// A card: soft paper, 16 pt corners, the system's single subtle shadow.
    func card(padding: CGFloat = Theme.cardPadding) -> some View {
        self
            .padding(padding)
            .background(Theme.softPaper, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
    }

    /// The app's surface: parchment canvas, ink text, light appearance.
    func parchmentSurface() -> some View {
        self
            .font(Theme.body)
            .foregroundStyle(Theme.ink)
            .tint(Theme.teal)
            .background(Theme.parchment)
            .preferredColorScheme(.light)
    }
}
