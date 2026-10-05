import SwiftUI
import TranscriptCore

/// Final lines as `[mm:ss] text`, then the partial line in gray. Follows new text while
/// the bottom is visible; stays put once the user scrolls up.
struct TranscriptView: View {
    let segments: [Segment]
    let partial: String

    @State private var atBottom = true
    private let bottomID = "bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        Text(formatLine(segment))
                            .textSelection(.enabled)
                    }
                    if !partial.isEmpty {
                        Text(partial)
                            .foregroundStyle(.secondary)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
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
}
