import Foundation
import Testing
@testable import AssistantKit

private func encode(_ request: MessagesRequest) throws -> [String: Any] {
    let data = try JSONEncoder().encode(request)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func encodesAskRequest() throws {
    let json = try encode(simpleRequest())
    #expect(json["model"] as? String == "claude-opus-5-5")
    #expect(json["max_tokens"] as? Int == 4000)
    #expect(json["stream"] as? Bool == true)
    #expect((json["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
    #expect(json["fallbacks"] as? String == "default")
    let output = try #require(json["output_config"] as? [String: Any])
    #expect(output["effort"] as? String == "low")
    #expect(output["format"] == nil)
    let system = try #require(json["system"] as? [[String: Any]])
    #expect(system[0]["type"] as? String == "text")
    #expect((system[0]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
    let messages = try #require(json["messages"] as? [[String: Any]])
    #expect(messages[0]["role"] as? String == "user")
    let content = try #require(messages[0]["content"] as? [[String: Any]])
    #expect(content[0]["text"] as? String == "Say OK.")
    #expect(content[0]["cache_control"] == nil)
}

@Test func encodesNotesSchema() throws {
    var request = simpleRequest(effort: "high", maxTokens: 64000)
    request.jsonSchema = .object([
        "type": .string("object"),
        "properties": .object([
            "title": .object(["type": .string("string")]),
            "notes_markdown": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("title"), .string("notes_markdown")]),
        "additionalProperties": .bool(false),
    ])
    let json = try encode(request)
    #expect(json["max_tokens"] as? Int == 64000)
    let format = try #require((json["output_config"] as? [String: Any])?["format"] as? [String: Any])
    #expect(format["type"] as? String == "json_schema")
    let schema = try #require(format["schema"] as? [String: Any])
    #expect(schema["required"] as? [String] == ["title", "notes_markdown"])
    #expect(schema["additionalProperties"] as? Bool == false)
}

@Test func jsonValueRoundTrips() throws {
    let value = JSONValue.object(["a": .array([.number(1.5), .null, .bool(true), .string("x")])])
    let decoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    #expect(decoded == value)
}
