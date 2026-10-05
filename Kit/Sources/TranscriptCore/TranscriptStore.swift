import Foundation

/// Finalized segments in time order plus the current partial line.
/// The single source of truth for the UI, the session writer, and the assistant.
public actor TranscriptStore {
    public let blockDuration: TimeInterval
    public private(set) var segments: [Segment] = []
    public private(set) var partial: String = ""

    public init(blockDuration: TimeInterval = 300) {
        self.blockDuration = blockDuration
    }

    public var isEmpty: Bool { segments.isEmpty }

    public func append(_ segment: Segment) {
        let index = segments.lastIndex(where: { $0.start <= segment.start }).map { $0 + 1 } ?? 0
        segments.insert(segment, at: index)
    }

    public func setPartial(_ text: String) {
        partial = text
    }

    public func reset() {
        segments = []
        partial = ""
    }

    /// Text of every completed block, one string per window in order. A window with no
    /// speech is an empty string, so indices are stable.
    ///
    /// A block is complete when its window has elapsed at `now` *and* a segment from a later
    /// window exists. Final segments arrive seconds after their audio, so the clock alone
    /// would let a late segment change a block that was already sent (and cached).
    public func completedBlocks(now: TimeInterval) -> [String] {
        let count = completedBlockCount(now: now)
        return (0..<count).map(blockText)
    }

    /// Text of everything after the completed blocks.
    public func currentBlock(now: TimeInterval) -> String {
        let first = completedBlockCount(now: now)
        return segments
            .filter { blockIndex(of: $0) >= first }
            .map(formatLine)
            .joined(separator: "\n")
    }

    /// Lines for segments starting at or after `start`.
    public func text(from start: TimeInterval) -> String {
        segments.filter { $0.start >= start }.map(formatLine).joined(separator: "\n")
    }

    private func completedBlockCount(now: TimeInterval) -> Int {
        guard let last = segments.last else { return 0 }
        return max(0, min(Int(now / blockDuration), blockIndex(of: last)))
    }

    private func blockIndex(of segment: Segment) -> Int {
        Int(segment.start / blockDuration)
    }

    private func blockText(_ index: Int) -> String {
        segments
            .filter { blockIndex(of: $0) == index }
            .map(formatLine)
            .joined(separator: "\n")
    }
}
