import Foundation
import TranscriptCore

public enum QuickAction: Equatable, Sendable {
    case summarizeLast5
    /// Since the last question, or the last 5 minutes when there was none.
    case whatDidIMiss(since: TimeInterval?)
    case explainLastTerm
}

public enum AskError: Error, Equatable {
    case nothingYet
    case missingKey
}

/// Which model to use and how hard to think when writing notes. Changed from Settings.
public struct AssistantConfiguration: Equatable, Sendable {
    public var model: ClaudeModel
    public var notesEffort: String

    public init(model: ClaudeModel = .opus55, notesEffort: String = "high") {
        self.model = model
        self.notesEffort = notesEffort
    }
}

public enum UsageKind: Sendable {
    case question
    case notes
}

/// Questions about the transcript during a session, and notes afterwards. Each question is
/// independent (no chat history); the transcript is sent as 5-minute blocks so completed
/// ones are cached, with the current block split by minute.
public final class Assistant: Sendable {
    public static let recentWindow: TimeInterval = 300
    static let minute: TimeInterval = 60

    let client: ClaudeClient
    private let store: TranscriptStore
    private let onUsage: (@Sendable (UsageKind, UsageReport) -> Void)?
    private let config = LockedValue(AssistantConfiguration())

    public init(
        client: ClaudeClient,
        store: TranscriptStore,
        onUsage: (@Sendable (UsageKind, UsageReport) -> Void)? = nil
    ) {
        self.client = client
        self.store = store
        self.onUsage = onUsage
    }

    public var configuration: AssistantConfiguration {
        get { config.value }
        set { config.value = newValue }
    }

    /// Streams the answer. Throws `AskError` before any network call when there is nothing
    /// to ask about or no API key.
    public func ask(_ question: String, now: TimeInterval) async throws -> AsyncThrowingStream<String, Error> {
        guard await !store.isEmpty else { throw AskError.nothingYet }
        guard client.hasKey else { throw AskError.missingKey }
        return client.stream(await buildAskRequest(question: question, now: now)) { [onUsage] in
            onUsage?(.question, $0)
        }
    }

    public func quick(_ action: QuickAction, now: TimeInterval) async throws -> AsyncThrowingStream<String, Error> {
        try await ask(question(for: action, now: now), now: now)
    }

    /// The question text a quick action sends (also what `qa.md` records).
    public func question(for action: QuickAction, now: TimeInterval) -> String {
        switch action {
        case .summarizeLast5:
            let from = formatTimestamp(max(0, now - Self.recentWindow))
            return "Summarize what was said from [\(from)] until now: the main points, in order, with timestamps."
        case .whatDidIMiss(let since):
            let start = formatTimestamp(since ?? max(0, now - Self.recentWindow))
            return "What did I miss since [\(start)]? Give me the key points said since then so I can catch up."
        case .explainLastTerm:
            return "Explain the most recent technical term or concept mentioned in the transcript: first in one or two plain sentences, then in more detail, and say where it came up."
        }
    }

    public func buildAskRequest(question: String, now: TimeInterval) async -> MessagesRequest {
        let completed = await store.completedBlocks(now: now)
        let current = await store.segments.filter { Int($0.start / store.blockDuration) >= completed.count }
        // Breakpoints (1-hour TTL, since questions in a lecture are often more than five
        // minutes apart): the system prompt, the last completed 5-minute block with text,
        // and the last completed minute of the current block. Empty text blocks are left
        // out because the API rejects them.
        let lastWithText = completed.lastIndex { !$0.isEmpty }
        var content = completed.enumerated()
            .filter { !$0.element.isEmpty }
            .map { TextBlock(text: Self.part($0.element), cached: $0.offset == lastWithText, ttl: .oneHour) }
        content += Self.minuteBlocks(current)
        content.append(TextBlock(text: "Question: \(question)", cached: false))
        return MessagesRequest(
            model: configuration.model.id,
            maxTokens: 4000,
            system: [TextBlock(text: Prompts.askSystem, cached: true, ttl: .oneHour)],
            messages: [Message(role: "user", content: content)],
            effort: "low"
        )
    }

    /// The current 5-minute block as one block per minute. A minute is complete once a line
    /// from a later minute exists (final lines arrive late), so its text no longer changes
    /// and it can carry a cache breakpoint.
    private static func minuteBlocks(_ segments: [Segment]) -> [TextBlock] {
        guard let last = segments.last else { return [] }
        let lastMinute = Int(last.start / minute)
        let minutes = Dictionary(grouping: segments) { Int($0.start / minute) }.sorted { $0.key < $1.key }
        let lastComplete = minutes.last { $0.key < lastMinute }?.key
        return minutes.map { index, lines in
            TextBlock(text: part(lines.map(formatLine).joined(separator: "\n")),
                      cached: index == lastComplete, ttl: .oneHour)
        }
    }

    private static func part(_ text: String) -> String {
        "<transcript_part>\n\(text)\n</transcript_part>"
    }
}

public enum NotesError: Error, Equatable {
    /// The response was not the expected JSON (for example, cut off mid-object).
    case invalidResponse
}

extension Assistant {
    /// Writes study notes from the whole transcript in one request. `progress` receives the
    /// number of characters received so far.
    public func makeNotes(
        transcript: [Segment],
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> (title: String, markdown: String) {
        guard client.hasKey else { throw AskError.missingKey }
        var text = ""
        let stream = client.stream(buildNotesRequest(transcript: transcript)) { [onUsage] in
            onUsage?(.notes, $0)
        }
        for try await delta in stream {
            text += delta
            progress(text.count)
        }
        struct Notes: Decodable {
            let title: String
            let notes_markdown: String
        }
        guard let notes = try? JSONDecoder().decode(Notes.self, from: Data(text.utf8)),
              !notes.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !notes.notes_markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw NotesError.invalidResponse }
        return (notes.title.trimmingCharacters(in: .whitespacesAndNewlines), notes.notes_markdown)
    }

    public func buildNotesRequest(transcript: [Segment]) -> MessagesRequest {
        let lines = transcript.map(formatLine).joined(separator: "\n")
        let configuration = configuration
        return MessagesRequest(
            model: configuration.model.id,
            maxTokens: 64000,
            system: [TextBlock(text: Prompts.notesSystem, cached: false)],
            messages: [Message(role: "user", content: [TextBlock(text: "<transcript>\n\(lines)\n</transcript>", cached: false)])],
            effort: configuration.notesEffort,
            jsonSchema: Prompts.notesSchema
        )
    }
}

/// A value guarded by a lock, so a `Sendable` class can hold settings that change.
final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) {
        _value = value
    }

    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
