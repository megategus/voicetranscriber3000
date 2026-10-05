import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ClaudeError: Error, Equatable {
    case missingKey
    case unauthorized
    case rateLimited
    case server(Int)
    case network(String)
    /// Claude (and the fallback model) declined. Any partial text should be discarded.
    case refusal
    case api(String)
    /// Hit `max_tokens`, or the stream ended without a stop reason.
    case truncated
}

/// Minimal Messages API client: streams text deltas over SSE, maps errors, and retries
/// 429 / 5xx / network failures (twice, 1 s then 2 s) before any of the response is read.
public struct ClaudeClient: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private let apiKey: @Sendable () -> String?
    private let session: URLSession
    private let retryDelays: [Duration]

    public init(
        apiKey: @escaping @Sendable () -> String?,
        session: URLSession = .shared,
        retryDelays: [Duration] = [.seconds(1), .seconds(2)]
    ) {
        self.apiKey = apiKey
        self.session = session
        self.retryDelays = retryDelays
    }

    /// Whether an API key is configured (checked without making a request).
    public var hasKey: Bool {
        !(apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// Yields text deltas as they arrive; throws a `ClaudeError` on failure.
    public func stream(_ request: MessagesRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The whole response text.
    public func complete(_ request: MessagesRequest) async throws -> String {
        var text = ""
        for try await delta in stream(request) {
            text += delta
        }
        return text
    }

    // MARK: - Private

    private func run(_ request: MessagesRequest, onText: (String) -> Void) async throws {
        guard let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw ClaudeError.missingKey
        }
        let urlRequest = try makeURLRequest(request, key: key)
        var attempt = 0
        while true {
            do {
                try await attemptOnce(urlRequest, onText: onText)
                return
            } catch let failure as Failure {
                guard failure.retryable, attempt < retryDelays.count, !Task.isCancelled else { throw failure.error }
                try await Task.sleep(for: retryDelays[attempt])
                attempt += 1
            }
        }
    }

    /// An error plus whether it may be retried (only before any of a 2xx stream was read).
    private struct Failure: Error {
        let error: ClaudeError
        let retryable: Bool
    }

    private func attemptOnce(_ urlRequest: URLRequest, onText: (String) -> Void) async throws {
        let response: HTTPURLResponse
        let lines: AsyncThrowingStream<String, Error>
        do {
            (response, lines) = try await openLines(urlRequest)
        } catch let error as URLError {
            throw Failure(error: .network(error.localizedDescription), retryable: true)
        }

        guard (200..<300).contains(response.statusCode) else {
            var body = ""
            for try await line in lines { body += line }
            throw Self.failure(status: response.statusCode, body: body)
        }

        var parser = SSEParser()
        var stopped = false
        do {
            for try await line in lines {
                switch parser.feed(line: line) {
                case .textDelta(let text):
                    onText(text)
                case .stop(let reason):
                    switch reason {
                    case "refusal": throw ClaudeError.refusal
                    case "max_tokens": throw ClaudeError.truncated
                    default: stopped = true
                    }
                case .error(let type, let message):
                    throw Self.streamError(type: type, message: message)
                case .ignored, nil:
                    break
                }
            }
        } catch let error as URLError {
            throw ClaudeError.network(error.localizedDescription)
        }
        if !stopped {
            throw ClaudeError.truncated
        }
    }

    private func makeURLRequest(_ request: MessagesRequest, key: String) throws -> URLRequest {
        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 300   // seconds between bytes; high-effort thinking can be quiet
        urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        return urlRequest
    }

    private static func failure(status: Int, body: String) -> Failure {
        let message = (try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8)))?["error"]?["message"]?.stringValue
            ?? "HTTP \(status)"
        switch status {
        case 401: return Failure(error: .unauthorized, retryable: false)
        case 429: return Failure(error: .rateLimited, retryable: true)
        case 500...599: return Failure(error: .server(status), retryable: true)
        default: return Failure(error: .api(message), retryable: false)
        }
    }

    private static func streamError(type: String, message: String) -> ClaudeError {
        switch type {
        case "overloaded_error": .server(529)
        case "rate_limit_error": .rateLimited
        case "authentication_error": .unauthorized
        default: .api(message)
        }
    }

    /// Opens the request and returns its body as lines.
    private func openLines(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation has no async byte stream: read the whole body, then split.
        let (data, response) = try await session.data(for: request)
        let text = String(decoding: data, as: UTF8.self)
        let lines = AsyncThrowingStream<String, Error> { continuation in
            text.split(separator: "\n", omittingEmptySubsequences: false).forEach { continuation.yield(String($0)) }
            continuation.finish()
        }
        #else
        let (bytes, response) = try await session.bytes(for: request)
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        #endif
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (http, lines)
    }
}
