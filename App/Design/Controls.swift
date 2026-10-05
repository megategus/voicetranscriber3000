import SwiftUI

// The pill buttons below adapt the "Skiper 25" micro-interaction (Skiper UI, by
// @gurvinder-singh02, https://gxuri.me): a rounded pill whose padding springs outward on
// hover and press, with a five-bar waveform. Free version, attribution required.

/// Five thin bars. When `live`, they bounce to random heights scaled by the audio level;
/// otherwise they rest flat.
struct WaveformView: View {
    var live: Bool
    var level: Float = 0.5
    var color: Color

    private static let bars = 5
    @State private var heights = Array(repeating: 0.1, count: bars)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<Self.bars, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 1.5, height: max(4, heights[index] * 14))
            }
        }
        .frame(height: 18)
        .animation(.interpolatingSpring(stiffness: 300, damping: 10), value: heights)
        .task(id: live && !reduceMotion) {
            guard live, !reduceMotion else {
                heights = Array(repeating: 0.1, count: Self.bars)
                return
            }
            while !Task.isCancelled {
                // Quiet audio gives small movement; speech fills the 0.2–1.0 range.
                let loudness = min(1, Double(level) * 8)
                let scale = 0.35 + 0.65 * loudness
                heights = (0..<Self.bars).map { _ in Double.random(in: 0.2...1.0) * scale }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The main pill: filled (ink on parchment) or outlined (hairline warm-mist border). Padding
/// springs outward on hover and press.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case filled, outlined }

    var kind: Kind = .filled
    var large = true

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, kind: kind, large: large)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let kind: Kind
        let large: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let expanded = (hovering || configuration.isPressed) && isEnabled
            let vertical: CGFloat = large ? (expanded ? 13 : 10) : (expanded ? 8 : 6)
            let horizontal: CGFloat = large ? (expanded ? 24 : 18) : (expanded ? 16 : 12)
            configuration.label
                .font(large ? Theme.label : Theme.small.weight(.medium))
                .foregroundStyle(kind == .filled ? Theme.parchment : Theme.ink)
                .padding(.vertical, vertical)
                .padding(.horizontal, horizontal)
                .background {
                    Capsule().fill(kind == .filled ? Theme.ink : Theme.softPaper)
                }
                .overlay {
                    if kind == .outlined {
                        Capsule().strokeBorder(Theme.warmMist, lineWidth: 1)
                    }
                }
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.4)
                .animation(.spring(duration: 1, bounce: 0.6), value: expanded)
                .onHover { hovering = $0 }
        }
    }
}

/// Low-emphasis action: transparent, graphite text, hairline border, 6 pt corners.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GhostBody(configuration: configuration)
    }

    private struct GhostBody: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(Theme.body)
                .foregroundStyle(hovering && isEnabled ? Theme.ink : Theme.graphite)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: Theme.buttonRadius)
                        .fill(configuration.isPressed ? Theme.warmMist.opacity(0.35) : .clear)
                )
                .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(Theme.warmMist))
                .contentShape(RoundedRectangle(cornerRadius: Theme.buttonRadius))
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }
    }
}

/// Pill chip: ink text on a transparent pill; selected chips fill with deep teal.
struct ChipButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, selected: selected)
    }

    private struct ChipBody: View {
        let configuration: Configuration
        let selected: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(Theme.body)
                .foregroundStyle(selected ? Color.white : Theme.ink)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background {
                    Capsule().fill(selected ? Theme.teal : (hovering || configuration.isPressed ? Theme.warmMist.opacity(0.35) : .clear))
                }
                .overlay {
                    if !selected { Capsule().strokeBorder(Theme.warmMist) }
                }
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }
    }
}

/// Small status pill (paused, lagging): hairline outline, graphite text.
struct StatusPill: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(Theme.small.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(Theme.graphite)
            .padding(.vertical, 3)
            .padding(.horizontal, 10)
            .overlay(Capsule().strokeBorder(Theme.warmMist))
    }
}

/// Text field styled as the hero input: parchment, 12 pt corners, hairline border, teal glow
/// when focused.
struct InputFieldStyle: ViewModifier {
    var focused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(Theme.body)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Theme.parchment, in: RoundedRectangle(cornerRadius: Theme.inputRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.inputRadius)
                    .strokeBorder(focused ? Theme.teal.opacity(0.4) : Theme.warmMist, lineWidth: focused ? 2 : 1)
            )
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}
