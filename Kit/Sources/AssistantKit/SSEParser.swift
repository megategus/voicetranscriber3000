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
    /// Token usage so far (from `message_start`, updated by `message_delta`).
    public private(set) var usage = TokenUsage()
    /// The model that is answering (a refusal fallback can differ from the requested one).
    public private(set) var model: String?

    public init() {}

    public mutating func feed(line: String) -> StreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)) else { return .ignored }
        switch json["type"]?.stringValue {
        case "message_start":
            model = json["message"]?["model"]?.stringValue ?? model
            if let usage = json["message"]?["usage"] { record(usage) }
            return .ignored
        case "content_block_delta":
            if json["delta"]?["type"]?.stringValue == "text_delta", let text = json["delta"]?["text"]?.stringValue {
                return .textDelta(text)
            }
            return .ignored
        case "message_delta":
            if let usage = json["usage"] { record(usage) }
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

    /// Fields present in a usage object replace earlier values (stream counts are cumulative).
    private mutating func record(_ json: JSONValue) {
        func int(_ value: JSONValue?) -> Int? {
            if case .number(let n) = value { return Int(n) }
            return nil
        }
        if let value = int(json["input_tokens"]) { usage.input = value }
        if let value = int(json["cache_read_input_tokens"]) { usage.cacheRead = value }
        if let value = int(json["output_tokens"]) { usage.output = value }
        if let total = int(json["cache_creation_input_tokens"]) {
            if let breakdown = json["cache_creation"],
               let fiveMinutes = int(breakdown["ephemeral_5m_input_tokens"]),
               let oneHour = int(breakdown["ephemeral_1h_input_tokens"]) {
                usage.cacheWrite5m = fiveMinutes
                usage.cacheWrite1h = oneHour
            } else {
                usage.cacheWrite5m = total
                usage.cacheWrite1h = 0
            }
        }
    }
}
