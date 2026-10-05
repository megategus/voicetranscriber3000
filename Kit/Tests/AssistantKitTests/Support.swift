import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AssistantKit

func fixture(_ name: String) throws -> String {
    guard let url = Bundle.module.url(forResource: name, withExtension: "sse", subdirectory: "Fixtures") else {
        throw CocoaError(.fileNoSuchFile)
    }
    return try String(contentsOf: url, encoding: .utf8)
}

/// Serves scripted HTTP responses and records the requests it saw.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [Reply] = []
    nonisolated(unsafe) private static var seen: [URLRequest] = []

    static func reset(_ replies: [Reply]) {
        lock.withLock {
            self.replies = replies
            seen = []
        }
    }

    static var requests: [URLRequest] { lock.withLock { seen } }

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply: Reply = Self.lock.withLock {
            Self.seen.append(request)
            return Self.replies.isEmpty ? Reply(status: 500, body: "no reply scripted") : Self.replies.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": reply.status == 200 ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func errorBody(_ type: String, _ message: String) -> String {
    #"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"}}"#
}

func simpleRequest(effort: String = "low", maxTokens: Int = 4000) -> MessagesRequest {
    MessagesRequest(
        maxTokens: maxTokens,
        system: [TextBlock(text: "You answer from the transcript.", cached: true)],
        messages: [Message(role: "user", content: [TextBlock(text: "Say OK.", cached: false)])],
        effort: effort
    )
}

/// Suites that use `StubProtocol` share its static state, so they are nested here and run
/// one at a time.
@Suite(.serialized)
struct StubbedNetworkTests {}
