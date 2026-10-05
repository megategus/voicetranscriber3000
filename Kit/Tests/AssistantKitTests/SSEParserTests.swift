import Testing
@testable import AssistantKit

private func events(_ text: String) -> [StreamEvent] {
    var parser = SSEParser()
    return text.split(separator: "\n", omittingEmptySubsequences: false)
        .compactMap { parser.feed(line: String($0)) }
        .filter { $0 != .ignored }
}

@Test func parsesTextFixture() throws {
    #expect(events(try fixture("text")) == [.textDelta("Hello"), .textDelta(" world"), .stop(reason: "end_turn")])
}

@Test func ignoresThinkingDeltas() throws {
    #expect(events(try fixture("thinking-then-text")) == [
        .textDelta("The derivative"), .textDelta(" is 2x [03:12]."), .stop(reason: "end_turn"),
    ])
}

@Test func parsesErrorEvent() throws {
    #expect(events(try fixture("error-event")) == [
        .error(type: "invalid_request_error", message: "Something went wrong mid-stream"),
    ])
}

@Test func fallbackBlockIsIgnored() throws {
    #expect(events(try fixture("fallback-midstream")) == [
        .textDelta("First part, "), .textDelta("second part."), .stop(reason: "end_turn"),
    ])
}

@Test func nonDataLinesReturnNil() {
    var parser = SSEParser()
    #expect(parser.feed(line: "event: ping") == nil)
    #expect(parser.feed(line: "") == nil)
    #expect(parser.feed(line: ": comment") == nil)
    #expect(parser.feed(line: "data: not json") == .ignored)
}
