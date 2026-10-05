import Foundation

/// Decides when live transcription text is final.
///
/// Each `ingest` call receives the segments from one decode of the unconfirmed audio window,
/// with absolute timestamps. A segment is confirmed when the previous decode had a segment at
/// the same index that starts within 0.5 s and has the same text (ignoring case and
/// surrounding whitespace). Only an agreeing prefix is confirmed: once one segment disagrees,
/// everything after it stays partial. Confirmed segments are never emitted again.
public struct SegmentConfirmer: Sendable {
    public static let startTolerance: TimeInterval = 0.5

    /// End time of the last confirmed segment. Audio before this point is final.
    public private(set) var confirmedEnd: TimeInterval = 0
    private var previous: [Segment] = []

    public init() {}

    public mutating func ingest(_ decode: [Segment]) -> (confirmed: [Segment], partial: String) {
        let fresh = decode.filter { $0.start >= confirmedEnd - 0.1 }

        var agreed = 0
        while agreed < fresh.count, agreed < previous.count,
              Self.agree(fresh[agreed], previous[agreed]) {
            agreed += 1
        }

        let confirmed = Array(fresh.prefix(agreed))
        let remaining = Array(fresh.dropFirst(agreed))
        if let last = confirmed.last {
            confirmedEnd = last.end
        }
        previous = remaining
        return (confirmed, Self.join(remaining))
    }

    /// Confirms everything left from the last decode. Call when the audio has ended.
    public mutating func flush() -> [Segment] {
        let rest = previous
        previous = []
        if let last = rest.last {
            confirmedEnd = last.end
        }
        return rest
    }

    /// Confirms every unconfirmed segment from the last decode except its final one, which
    /// may still be growing. Used when confirmation stalls because Whisper keeps shifting
    /// segment boundaries, so the decode window never has to drop audio.
    public mutating func confirmAllButLast() -> [Segment] {
        guard previous.count > 1 else { return [] }
        let confirmed = Array(previous.dropLast())
        previous = Array(previous.suffix(1))
        confirmedEnd = confirmed.last!.end
        return confirmed
    }

    private static func agree(_ a: Segment, _ b: Segment) -> Bool {
        abs(a.start - b.start) <= startTolerance && normalize(a.text) == normalize(b.text)
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func join(_ segments: [Segment]) -> String {
        segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
