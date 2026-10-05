import Foundation

/// Minimal JSON value, used for the notes JSON schema and for parsing stream events.
public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

public enum CacheTTL: String, Sendable {
    case fiveMinutes = "5m"
    case oneHour = "1h"
}

/// A text content block; `cached` adds a cache breakpoint after it.
public struct TextBlock: Encodable, Sendable, Equatable {
    public var text: String
    public var cached: Bool
    public var ttl: CacheTTL

    public init(text: String, cached: Bool, ttl: CacheTTL = .fiveMinutes) {
        self.text = text
        self.cached = cached
        self.ttl = ttl
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, cacheControl = "cache_control"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("text", forKey: .type)
        try container.encode(text, forKey: .text)
        if cached {
            var control = ["type": "ephemeral"]
            if ttl == .oneHour { control["ttl"] = "1h" }
            try container.encode(control, forKey: .cacheControl)
        }
    }
}

public struct Message: Encodable, Sendable, Equatable {
    public var role: String
    public var content: [TextBlock]

    public init(role: String, content: [TextBlock]) {
        self.role = role
        self.content = content
    }
}

/// Body of `POST /v1/messages`. Always streamed, with adaptive thinking and the server-side
/// refusal fallback (`fallbacks: "default"`; the client sends the matching beta header).
public struct MessagesRequest: Encodable, Sendable, Equatable {
    public var model = "claude-opus-5-5"
    public var maxTokens: Int
    public var system: [TextBlock]
    public var messages: [Message]
    /// `low` … `max`. Opus 5.5 defaults to `medium`, so it is always sent explicitly.
    public var effort: String
    /// When set, the response is JSON matching this schema.
    public var jsonSchema: JSONValue?

    public init(
        model: String = "claude-opus-5-5",
        maxTokens: Int,
        system: [TextBlock],
        messages: [Message],
        effort: String,
        jsonSchema: JSONValue? = nil
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        self.messages = messages
        self.effort = effort
        self.jsonSchema = jsonSchema
    }

    private enum CodingKeys: String, CodingKey {
        case model, maxTokens = "max_tokens", stream, thinking, fallbacks, system, messages, outputConfig = "output_config"
    }

    private struct OutputConfig: Encodable {
        struct Format: Encodable {
            let type = "json_schema"
            let schema: JSONValue
        }
        let effort: String
        let format: Format?
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(maxTokens, forKey: .maxTokens)
        try container.encode(true, forKey: .stream)
        try container.encode(["type": "adaptive"], forKey: .thinking)
        try container.encode("default", forKey: .fallbacks)
        try container.encode(system, forKey: .system)
        try container.encode(messages, forKey: .messages)
        try container.encode(OutputConfig(effort: effort, format: jsonSchema.map { .init(schema: $0) }), forKey: .outputConfig)
    }
}
