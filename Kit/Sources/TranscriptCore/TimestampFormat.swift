import Foundation

/// `mm:ss` under one hour, `h:mm:ss` at or past one hour. Fractions are truncated.
public func formatTimestamp(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%02d:%02d", m, s)
}

/// One transcript line: `[mm:ss] text`.
public func formatLine(_ segment: Segment) -> String {
    "[\(formatTimestamp(segment.start))] \(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))"
}

/// Reads `[mm:ss] text` / `[h:mm:ss] text` lines back into segments, in file order.
/// Other lines are ignored. End times are not stored in the file, so `end == start`.
public func parseTranscript(_ text: String) -> [Segment] {
    text.split(separator: "\n").compactMap { line in
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let parts = line[line.index(after: line.startIndex)..<close].split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        let seconds = numbers.reduce(0) { $0 * 60 + $1 }
        let body = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        return Segment(start: TimeInterval(seconds), end: TimeInterval(seconds), text: body)
    }
}
