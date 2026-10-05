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
