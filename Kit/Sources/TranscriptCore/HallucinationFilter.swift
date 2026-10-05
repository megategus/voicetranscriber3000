import Foundation

/// Drops phrases Whisper tends to invent over silence or music, but only when the
/// segment's audio is quiet, so a speaker who really says "Thank you." is kept.
public struct HallucinationFilter: Sendable {
    /// RMS energy below which audio is treated as non-speech.
    public static let speechThreshold: Float = 0.01

    /// Matched against the whole segment text after lowercasing, trimming, and removing
    /// trailing punctuation.
    public static let phrases: [String] = [
        "thank you",
        "thanks for watching",
        "thank you for watching",
        "you",
        "bye",
    ]

    /// Matched against the start of the normalized text.
    public static let prefixes: [String] = [
        "subtitles by",
    ]

    public init() {}

    public func shouldDrop(_ segment: Segment, rmsEnergy: Float) -> Bool {
        guard rmsEnergy < Self.speechThreshold else { return false }
        let text = Self.normalize(segment.text)
        return Self.phrases.contains(text) || Self.prefixes.contains { text.hasPrefix($0) }
    }

    static func normalize(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while let last = t.last, last.isPunctuation || last.isWhitespace {
            t.removeLast()
        }
        return t
    }
}
