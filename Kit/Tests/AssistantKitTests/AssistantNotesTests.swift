import Foundation
import Testing
import TranscriptCore
@testable import AssistantKit

private let transcript = [
    Segment(start: 5, end: 9, text: "Today we look at limits."),
    Segment(start: 3725, end: 3730, text: "That is all for today."),
]

private func assistant(key: String? = "test-key") -> Assistant {
    Assistant(client: ClaudeClient(apiKey: { key }, session: StubProtocol.session, retryDelays: [.zero, .zero]),
              store: TranscriptStore())
}

extension StubbedNetworkTests {
    @Suite
    struct AssistantNotesTests {
        @Test func notesRequestShape() throws {
            let request = assistant().buildNotesRequest(transcript: transcript)
            #expect(request.effort == "high")
            #expect(request.maxTokens == 64000)
            #expect(request.jsonSchema == Prompts.notesSchema)
            #expect(request.system.map(\.text) == [Prompts.notesSystem])
            #expect(request.messages.count == 1)
            let content = request.messages[0].content
            #expect(content.count == 1)
            #expect(content[0].text.contains("[00:05] Today we look at limits.\n[1:02:05] That is all for today."))
        }

        @Test func notesSchemaRequiresTitleAndMarkdown() {
            let schema = Prompts.notesSchema
            #expect(schema["type"] == .string("object"))
            #expect(schema["required"] == .array([.string("title"), .string("notes_markdown")]))
            #expect(schema["additionalProperties"] == .bool(false))
            #expect(schema["properties"]?["title"]?["type"] == .string("string"))
            #expect(schema["properties"]?["notes_markdown"]?["type"] == .string("string"))
        }

        @Test func decodesNotesJSON() async throws {
            let json = ##"{"title":"Limits","notes_markdown":"# Limits\n## TL;DR\n- x"}"##
            StubProtocol.reset([.init(status: 200, body: sseBody(text: json))])
            let notes = try await assistant().makeNotes(transcript: transcript) { _ in }
            #expect(notes.title == "Limits")
            #expect(notes.markdown == "# Limits\n## TL;DR\n- x")
        }

        @Test func reportsProgressAsCharacters() async throws {
            let json = ##"{"title":"Limits","notes_markdown":"# Limits"}"##
            StubProtocol.reset([.init(status: 200, body: sseBody(text: json))])
            let counter = Counter()
            _ = try await assistant().makeNotes(transcript: transcript) { count in counter.set(count) }
            #expect(counter.value == json.count)
        }

        @Test func invalidJSONThrows() async throws {
            StubProtocol.reset([.init(status: 200, body: sseBody(text: #"{"title":"Lim"#))])
            await #expect(throws: NotesError.invalidResponse) {
                _ = try await assistant().makeNotes(transcript: transcript) { _ in }
            }
        }

        @Test func emptyFieldsAreInvalid() async throws {
            StubProtocol.reset([.init(status: 200, body: sseBody(text: #"{"title":" ","notes_markdown":""}"#))])
            await #expect(throws: NotesError.invalidResponse) {
                _ = try await assistant().makeNotes(transcript: transcript) { _ in }
            }
        }

        @Test func missingKeyMakesNoRequest() async throws {
            StubProtocol.reset([])
            await #expect(throws: AskError.missingKey) {
                _ = try await assistant(key: nil).makeNotes(transcript: transcript) { _ in }
            }
            #expect(StubProtocol.requests.isEmpty)
        }
    }
}

@Test func notesPromptContainsFixedStructure() {
    let prompt = Prompts.notesSystem
    for phrase in ["## TL;DR", "## Key concepts", "## Detailed notes", "## Examples & formulas", "## Action items",
                   "In simple terms:", "Explanation:", "Why it matters:", "⚠ unclear in recording", "(background)",
                   "LaTeX", "# <Title>"] {
        #expect(prompt.contains(phrase), "\(phrase)")
    }
    #expect(!prompt.contains("Open questions"))
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func set(_ new: Int) { lock.withLock { _value = new } }
}
