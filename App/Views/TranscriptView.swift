import SwiftUI
import TranscriptCore

/// Final lines with their timestamps, then the partial line in graphite. Follows new text
/// while the bottom is visible; stays put once the user scrolls up.
struct TranscriptView: View {
    let segments: [Segment]
    let partial: String

    @State private var atBottom = true
    private let bottomID = "bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if segments.isEmpty, partial.isEmpty {
                        Text("The live transcript appears here.")
                            .foregroundStyle(Theme.ash)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, Theme.sectionGap)
                    }
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(formatTimestamp(segment.start))
                                .font(Theme.timestamp)
                                .foregroundStyle(Theme.ash)
                                .frame(minWidth: 40, alignment: .trailing)
                            Text(segment.text)
                                .font(Theme.bodyLarge)
                                .lineSpacing(4)
                                .foregroundStyle(Theme.ink)
                                .textSelection(.enabled)
                        }
                    }
                    if !partial.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("")
                                .frame(minWidth: 40)
                            Text(partial)
                                .font(Theme.bodyLarge)
                                .lineSpacing(4)
                                .foregroundStyle(Theme.graphite)
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.cardPadding)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: segments.count) { follow(proxy) }
            .onChange(of: partial) { follow(proxy) }
        }
    }

    private func follow(_ proxy: ScrollViewProxy) {
        guard atBottom else { return }
        proxy.scrollTo(bottomID, anchor: .bottom)
    }
}

#Preview {
    TranscriptView(
        segments: [
            Segment(start: 3, end: 6, text: "Today we look at derivatives."),
            Segment(start: 6, end: 9, text: "The derivative of x squared is two x."),
        ],
        partial: "Next, the chain rule"
    )
    .parchmentSurface()
}
