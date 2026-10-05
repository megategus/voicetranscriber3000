import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AssistantKit

/// The stub has shared state, so these run one at a time.
extension StubbedNetworkTests {
    @Suite
    struct ClaudeClientTests {
        let client = ClaudeClient(apiKey: { "test-key" }, session: StubProtocol.session, retryDelays: [.zero, .zero])

        @Test func completeConcatenatesText() async throws {
            StubProtocol.reset([.init(status: 200, body: try fixture("text"))])
            #expect(try await client.complete(simpleRequest()) == "Hello world")
        }

        @Test func streamYieldsDeltas() async throws {
            StubProtocol.reset([.init(status: 200, body: try fixture("thinking-then-text"))])
            var deltas: [String] = []
            for try await delta in client.stream(simpleRequest()) {
                deltas.append(delta)
            }
            #expect(deltas == ["The derivative", " is 2x [03:12]."])
        }

        @Test func refusalStopReasonSurfaces() async throws {
            StubProtocol.reset([.init(status: 200, body: try fixture("refusal"))])
            await #expect(throws: ClaudeError.refusal) { try await client.complete(simpleRequest()) }
        }

        @Test func fallbackMidstreamConcatenatesText() async throws {
            StubProtocol.reset([.init(status: 200, body: try fixture("fallback-midstream"))])
            #expect(try await client.complete(simpleRequest()) == "First part, second part.")
        }

        @Test func maxTokensStopIsTruncated() async throws {
            StubProtocol.reset([.init(status: 200, body: try fixture("max-tokens"))])
            await #expect(throws: ClaudeError.truncated) { try await client.complete(simpleRequest()) }
        }

        @Test func streamWithoutStopReasonIsTruncated() async throws {
            StubProtocol.reset([.init(status: 200, body: try fixture("cut-off"))])
            await #expect(throws: ClaudeError.truncated) { try await client.complete(simpleRequest()) }
        }

        @Test func errorEventSurfacesMessage() async throws {
            StubProtocol.reset([.init(status: 200, body: try fixture("error-event"))])
            await #expect(throws: ClaudeError.api("Something went wrong mid-stream")) { try await client.complete(simpleRequest()) }
            #expect(StubProtocol.requests.count == 1)
        }

        @Test func unauthorizedIsNotRetried() async throws {
            StubProtocol.reset([.init(status: 401, body: errorBody("authentication_error", "invalid x-api-key"))])
            await #expect(throws: ClaudeError.unauthorized) { try await client.complete(simpleRequest()) }
            #expect(StubProtocol.requests.count == 1)
        }

        @Test func rateLimitRetriesThenSucceeds() async throws {
            StubProtocol.reset([
                .init(status: 429, body: errorBody("rate_limit_error", "slow down")),
                .init(status: 429, body: errorBody("rate_limit_error", "slow down")),
                .init(status: 200, body: try fixture("text")),
            ])
            #expect(try await client.complete(simpleRequest()) == "Hello world")
            #expect(StubProtocol.requests.count == 3)
        }

        @Test func serverErrorGivesUpAfterThreeAttempts() async throws {
            StubProtocol.reset(Array(repeating: .init(status: 500, body: errorBody("api_error", "boom")), count: 4))
            await #expect(throws: ClaudeError.server(500)) { try await client.complete(simpleRequest()) }
            #expect(StubProtocol.requests.count == 3)
        }

        @Test func badRequestIsNotRetried() async throws {
            StubProtocol.reset([.init(status: 400, body: errorBody("invalid_request_error", "max_tokens: too large"))])
            await #expect(throws: ClaudeError.api("max_tokens: too large")) { try await client.complete(simpleRequest()) }
            #expect(StubProtocol.requests.count == 1)
        }

        @Test func missingKeyThrowsWithoutRequest() async throws {
            StubProtocol.reset([])
            let noKey = ClaudeClient(apiKey: { nil }, session: StubProtocol.session)
            await #expect(throws: ClaudeError.missingKey) { try await noKey.complete(simpleRequest()) }
            #expect(StubProtocol.requests.isEmpty)
        }

        @Test func sendsRequiredHeaders() async throws {
            StubProtocol.reset([.init(status: 200, body: try fixture("text"))])
            _ = try await client.complete(simpleRequest())
            let request = try #require(StubProtocol.requests.first)
            #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
            #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
            #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
        }
    }
}

/// Real API call; runs only when ANTHROPIC_API_KEY is set in the environment.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil))
func liveSmokeTest() async throws {
    let client = ClaudeClient(apiKey: { ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] })
    let request = MessagesRequest(
        maxTokens: 1000,
        system: [TextBlock(text: "Reply with exactly: OK", cached: false)],
        messages: [Message(role: "user", content: [TextBlock(text: "Ready?", cached: false)])],
        effort: "low"
    )
    let text = try await client.complete(request)
    #expect(!text.isEmpty)
}
