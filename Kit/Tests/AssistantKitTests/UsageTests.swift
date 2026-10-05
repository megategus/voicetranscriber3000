import Foundation
import Testing
import TranscriptCore
@testable import AssistantKit

private let sample = TokenUsage(input: 1000, cacheWrite5m: 0, cacheWrite1h: 2000, cacheRead: 10000, output: 500)

@Test func opusCostUsesPublishedRates() {
    // 1000×$4 + 2000×$8 (1-hour write = 2×) + 10000×$0.20 + 500×$20, per million
    #expect(abs(ClaudeModel.opus55.pricing.cost(of: sample) - 0.032) < 1e-9)
}

@Test func sonnetCostUsesPublishedRates() {
    // 1000×$2 + 2000×$4 + 10000×$0.20 + 500×$10, per million
    #expect(abs(ClaudeModel.sonnet55.pricing.cost(of: sample) - 0.017) < 1e-9)
}

@Test func fiveMinuteWritesCostOneAndAQuarter() {
    let usage = TokenUsage(input: 0, cacheWrite5m: 1_000_000, cacheWrite1h: 0, cacheRead: 0, output: 0)
    #expect(abs(ClaudeModel.opus55.pricing.cost(of: usage) - 5.0) < 1e-9)
}

@Test func pricingIsFoundForFallbackModels() {
    #expect(Pricing.forModel("claude-opus-5-5") == ClaudeModel.opus55.pricing)
    #expect(Pricing.forModel("claude-sonnet-5-5") == ClaudeModel.sonnet55.pricing)
    #expect(Pricing.forModel("claude-opus-4-8")?.output == 25)
    #expect(Pricing.forModel("claude-unknown") == nil)
}

@Test func parserCollectsUsageAndModel() throws {
    var parser = SSEParser()
    for line in try fixture("usage").split(separator: "\n", omittingEmptySubsequences: false) {
        _ = parser.feed(line: String(line))
    }
    #expect(parser.model == "claude-opus-5-5")
    #expect(parser.usage == TokenUsage(input: 120, cacheWrite5m: 0, cacheWrite1h: 2000, cacheRead: 10000, output: 500))
}

@Test func usageWithoutBreakdownCountsWritesAsFiveMinute() {
    var parser = SSEParser()
    _ = parser.feed(line: #"data: {"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":5,"cache_creation_input_tokens":300,"cache_read_input_tokens":0,"output_tokens":1}}}"#)
    #expect(parser.usage.cacheWrite5m == 300)
    #expect(parser.usage.cacheWrite1h == 0)
}

@Test func encodesOneHourCacheTTL() throws {
    let block = TextBlock(text: "x", cached: true, ttl: .oneHour)
    let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(block)) as? [String: Any])
    let control = try #require(json["cache_control"] as? [String: Any])
    #expect(control["type"] as? String == "ephemeral")
    #expect(control["ttl"] as? String == "1h")
}

extension StubbedNetworkTests {
    @Suite
    struct ClientUsageTests {
        let client = ClaudeClient(apiKey: { "test-key" }, session: StubProtocol.session, retryDelays: [.zero, .zero])

        @Test func clientReportsUsageWithCost() async throws {
            StubProtocol.reset([.init(status: 200, body: try fixture("usage"))])
            let box = UsageBox()
            _ = try await client.complete(simpleRequest()) { box.set($0) }
            let report = try #require(box.value)
            #expect(report.model == "claude-opus-5-5")
            #expect(report.tokens.output == 500)
            // 120×4 + 2000×8 + 10000×0.2 + 500×20 = 28480 per million
            #expect(abs(report.cost - 0.02848) < 1e-9)
        }

        @Test func clientReportsUsageEvenOnRefusal() async throws {
            StubProtocol.reset([.init(status: 200, body: try fixture("refusal"))])
            let box = UsageBox()
            await #expect(throws: ClaudeError.refusal) { _ = try await client.complete(simpleRequest()) { box.set($0) } }
            #expect(box.value?.tokens.output == 3)
        }
    }
}

final class UsageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: UsageReport?
    var value: UsageReport? { lock.withLock { _value } }
    func set(_ report: UsageReport) { lock.withLock { _value = report } }
}
