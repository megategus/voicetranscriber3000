import AssistantKit
import Foundation

/// What Claude cost in this session, at list prices.
public struct SessionCost: Equatable, Sendable {
    public private(set) var questions: Double = 0
    public private(set) var questionCount = 0
    public private(set) var notes: Double = 0
    public private(set) var tokens = TokenUsage()

    public init() {}

    public var total: Double { questions + notes }
    public var isEmpty: Bool { tokens == TokenUsage() }

    public mutating func add(_ kind: UsageKind, _ report: UsageReport) {
        switch kind {
        case .question:
            questions += report.cost
            questionCount += 1
        case .notes:
            notes += report.cost
        }
        tokens = tokens + report.tokens
    }

    /// Body of `usage.md`.
    public var markdown: String {
        let t = tokens
        return """
        # Claude usage

        - Questions (\(questionCount)): \(Self.dollars(questions))
        - Notes: \(Self.dollars(notes))
        - Total: \(Self.dollars(total))

        Tokens: \(Self.count(t.input)) input · \(Self.count(t.cacheRead)) cache read · \
        \(Self.count(t.cacheWrite5m + t.cacheWrite1h)) cache write · \(Self.count(t.output)) output (includes thinking)

        Estimated at list prices; your Anthropic bill is authoritative.

        """
    }

    public static func dollars(_ amount: Double) -> String {
        String(format: "$%.3f", amount)
    }

    private static func count(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }
}

/// Collects usage reports from any thread, so a total read on the main actor right after a
/// request finishes already includes it.
final class CostAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var cost = SessionCost()

    var value: SessionCost { lock.withLock { cost } }

    func add(_ kind: UsageKind, _ report: UsageReport) {
        lock.withLock { cost.add(kind, report) }
    }

    func reset() {
        lock.withLock { cost = SessionCost() }
    }
}
