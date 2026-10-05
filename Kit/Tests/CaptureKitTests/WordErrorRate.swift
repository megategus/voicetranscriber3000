import Foundation

/// Word-level Levenshtein distance divided by the number of reference words.
/// Both strings are lowercased, stripped of punctuation, and have common abbreviations
/// spelled out (Whisper writes "Mr.", LibriSpeech references say "mister").
func wordErrorRate(reference: String, hypothesis: String) -> Double {
    let ref = normalizedWords(reference)
    let hyp = normalizedWords(hypothesis)
    guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
    var previous = Array(0...hyp.count)
    for i in 1...ref.count {
        var current = [i] + Array(repeating: 0, count: hyp.count)
        for j in stride(from: 1, through: hyp.count, by: 1) {
            let cost = ref[i - 1] == hyp[j - 1] ? 0 : 1
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
        }
        previous = current
    }
    return Double(previous[hyp.count]) / Double(ref.count)
}

func normalizedWords(_ text: String) -> [String] {
    let kept = text.lowercased().unicodeScalars.map { scalar -> Character in
        CharacterSet.alphanumerics.contains(scalar) || scalar == "'" ? Character(scalar) : " "
    }
    return String(kept).split(separator: " ").map { abbreviations[String($0)] ?? String($0) }
}

private let abbreviations = ["mr": "mister", "mrs": "missus", "dr": "doctor", "st": "saint"]
