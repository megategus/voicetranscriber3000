import Foundation

/// One word from a decode. Times are seconds since the session began.
public struct Word: Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Decides which live words are final ("local agreement").
///
/// Each `ingest` receives the words of one decode of the unconfirmed audio, with absolute
/// times. Words that this decode and the previous one agree on, in order from the start,
/// are confirmed (compared ignoring case and punctuation). Whisper re-splits a growing
/// window into different segments almost every time, but the words themselves settle
/// quickly, so agreeing on words confirms text about two decodes after it is spoken.
public struct WordConfirmer: Sendable {
    /// End time of the last confirmed word. Audio before this point is final.
    public private(set) var confirmedEnd: TimeInterval = 0
    /// Words of the latest decode that are not confirmed yet.
    public private(set) var pending: [Word] = []
    /// The last few confirmed words, to spot Whisper repeating them in the next window.
    private var recent: [Word] = []

    /// Repeats are only checked this close after `confirmedEnd`.
    static let repeatWindow: TimeInterval = 1
    static let maxRepeat = 5

    public init() {}

    /// Returns the newly confirmed words.
    public mutating func ingest(_ decode: [Word]) -> [Word] {
        let fresh = dropRepeats(decode.filter { ($0.start + $0.end) / 2 >= confirmedEnd })
        var agreed = 0
        while agreed < fresh.count, agreed < pending.count,
              Self.normalize(fresh[agreed].text) == Self.normalize(pending[agreed].text) {
            agreed += 1
        }
        let confirmed = Array(fresh.prefix(agreed))
        pending = Array(fresh.dropFirst(agreed))
        commit(confirmed)
        return confirmed
    }

    /// Confirms every pending word. Call when the audio has ended.
    public mutating func flush() -> [Word] {
        let rest = pending
        pending = []
        commit(rest)
        return rest
    }

    /// Confirms every pending word except the last, which may still be growing. Used when
    /// decodes keep disagreeing, so the decode window never has to drop audio.
    public mutating func confirmAllButLast() -> [Word] {
        guard pending.count > 1 else { return [] }
        let confirmed = Array(pending.dropLast())
        pending = Array(pending.suffix(1))
        commit(confirmed)
        return confirmed
    }

    // MARK: - Private

    private mutating func commit(_ words: [Word]) {
        guard let last = words.last else { return }
        confirmedEnd = max(confirmedEnd, last.end)
        recent = Array((recent + words).suffix(Self.maxRepeat))
    }

    /// Drops the first k words when they repeat the last k confirmed words right after
    /// `confirmedEnd` (Whisper re-reads them from the context kept before the trim point).
    private func dropRepeats(_ words: [Word]) -> [Word] {
        guard let first = words.first, first.start - confirmedEnd < Self.repeatWindow else { return words }
        for k in stride(from: min(Self.maxRepeat, recent.count, words.count), through: 1, by: -1) {
            let head = words.prefix(k).map { Self.normalize($0.text) }
            let tail = recent.suffix(k).map { Self.normalize($0.text) }
            if head == tail {
                return Array(words.dropFirst(k))
            }
        }
        return words
    }

    static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "'"
        }.map(Character.init))
    }
}
