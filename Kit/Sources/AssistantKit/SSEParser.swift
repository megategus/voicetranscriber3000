import Foundation

public enum StreamEvent: Equatable, Sendable {
    case textDelta(String)
    case stop(reason: String)
    case error(type: String, message: String)
    /// Thinking, signatures, pings, block starts/stops (including `fallback` blocks), etc.
    case ignored
}

/// Turns server-sent-event lines from the Messages API into `StreamEvent`s. Only `data:`
/// lines carry information; `event:` lines, comments, and blank lines return nil.
public struct SSEParser: Sendable {
    public init() {}

    public mutating func feed(line: String) -> StreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)) else { return .ignored }
        switch json["type"]?.stringValue {
        case "content_block_delta":
            if json["delta"]?["type"]?.stringValue == "text_delta", let text = json["delta"]?["text"]?.stringValue {
                return .textDelta(text)
            }
            return .ignored
        case "message_delta":
            if let reason = json["delta"]?["stop_reason"]?.stringValue {
                return .stop(reason: reason)
            }
            return .ignored
        case "error":
            return .error(
                type: json["error"]?["type"]?.stringValue ?? "unknown",
                message: json["error"]?["message"]?.stringValue ?? "Unknown error"
            )
        default:
            return .ignored
        }
    }
}
