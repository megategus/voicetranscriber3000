import Foundation

/// Groups confirmed words into transcript lines. A line ends after a sentence (`.`, `?`,
/// `!`, but not "Mr."), before a pause of `pauseBreak` or more, or before it would grow
/// past `maxDuration`.
public struct LineBuilder: Sendable {
    public static let maxDuration: TimeInterval = 15
    public static let pauseBreak: TimeInterval = 1.5

    static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "st", "prof", "vs", "jr", "sr"]

    private var open: [Word] = []

    public init() {}

    /// Confirmed words that are not part of a finished line yet.
    public var openText: String { Self.join(open) }

    /// Adds confirmed words; returns the lines they completed.
    public mutating func add(_ words: [Word]) -> [Segment] {
        var lines: [Segment] = []
        for word in words {
            if let last = open.last, word.start - last.end >= Self.pauseBreak {
                lines += close()
            }
            if let first = open.first, word.end - first.start > Self.maxDuration {
                lines += close()
            }
            open.append(word)
            if Self.endsSentence(word.text) {
                lines += close()
            }
        }
        return lines
    }

    /// Ends the open line, e.g. at a pause or when the audio ends.
    public mutating func finish() -> Segment? {
        close().first
    }

    // MARK: - Private

    private mutating func close() -> [Segment] {
        guard let first = open.first, let last = open.last else { return [] }
        let line = Segment(start: first.start, end: last.end, text: Self.join(open))
        open = []
        return line.text.isEmpty ? [] : [line]
    }

    private static func join(_ words: [Word]) -> String {
        words
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func endsSentence(_ text: String) -> Bool {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = t.last, "\"')]”’".contains(last) {
            t.removeLast()
        }
        guard let last = t.last, ".?!".contains(last) else { return false }
        if last == "." {
            let stem = t.dropLast().lowercased()
            if stem.count == 1 || abbreviations.contains(String(stem)) { return false }
        }
        return true
    }
}
