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

/// Questions about the transcript during a session. Each question is independent (no chat
/// history); the transcript is sent as 5-minute blocks so completed ones are cached.
public final class Assistant: Sendable {
    public static let recentWindow: TimeInterval = 300

    private let client: ClaudeClient
    private let store: TranscriptStore

    public init(client: ClaudeClient, store: TranscriptStore) {
        self.client = client
        self.store = store
    }

    /// Streams the answer. Throws `AskError` before any network call when there is nothing
    /// to ask about or no API key.
    public func ask(_ question: String, now: TimeInterval) async throws -> AsyncThrowingStream<String, Error> {
        guard await !store.isEmpty else { throw AskError.nothingYet }
        guard client.hasKey else { throw AskError.missingKey }
        return client.stream(await buildAskRequest(question: question, now: now))
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
        let current = await store.currentBlock(now: now)
        // The API rejects empty text blocks, so silent windows are left out; the cache
        // breakpoint goes on the last completed window that has text.
        let lastWithText = completed.lastIndex { !$0.isEmpty }
        var content = completed.enumerated()
            .filter { !$0.element.isEmpty }
            .map { TextBlock(text: Self.part($0.element), cached: $0.offset == lastWithText) }
        if !current.isEmpty {
            content.append(TextBlock(text: Self.part(current), cached: false))
        }
        content.append(TextBlock(text: "Question: \(question)", cached: false))
        return MessagesRequest(
            maxTokens: 4000,
            system: [TextBlock(text: Prompts.askSystem, cached: true)],
            messages: [Message(role: "user", content: content)],
            effort: "low"
        )
    }

    private static func part(_ text: String) -> String {
        "<transcript_part>\n\(text)\n</transcript_part>"
    }
}
