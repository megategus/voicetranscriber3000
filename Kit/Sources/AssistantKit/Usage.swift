import Foundation

/// The models the app can use. Prices are USD per million tokens (public list prices).
public enum ClaudeModel: String, CaseIterable, Sendable {
    case opus55 = "claude-opus-5-5"
    case sonnet55 = "claude-sonnet-5-5"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .opus55: "Claude Opus 5.5"
        case .sonnet55: "Claude Sonnet 5.5"
        }
    }

    public var pricing: Pricing {
        switch self {
        case .opus55: Pricing(input: 4, output: 20, cacheRead: 0.20)
        case .sonnet55: Pricing(input: 2, output: 10, cacheRead: 0.20)
        }
    }
}

public struct Pricing: Equatable, Sendable {
    public let input: Double
    public let output: Double
    public let cacheRead: Double

    /// Cache writes cost 1.25× input for the 5-minute TTL and 2× for the 1-hour TTL.
    public var cacheWrite5m: Double { input * 1.25 }
    public var cacheWrite1h: Double { input * 2 }

    public func cost(of usage: TokenUsage) -> Double {
        (Double(usage.input) * input
            + Double(usage.cacheWrite5m) * cacheWrite5m
            + Double(usage.cacheWrite1h) * cacheWrite1h
            + Double(usage.cacheRead) * cacheRead
            + Double(usage.output) * output) / 1_000_000
    }

    /// Prices for the model that served a response, including refusal-fallback models.
    public static func forModel(_ id: String) -> Pricing? {
        if let model = ClaudeModel(rawValue: id) { return model.pricing }
        switch id {
        case "claude-opus-5", "claude-opus-4-8": return Pricing(input: 5, output: 25, cacheRead: 0.50)
        default: return nil
        }
    }
}

/// Billed tokens for one response. Thinking counts as output.
public struct TokenUsage: Equatable, Sendable {
    public var input = 0
    public var cacheWrite5m = 0
    public var cacheWrite1h = 0
    public var cacheRead = 0
    public var output = 0

    public init(input: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0, cacheRead: Int = 0, output: Int = 0) {
        self.input = input
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.output = output
    }

    public static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input: a.input + b.input, cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m,
                   cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h, cacheRead: a.cacheRead + b.cacheRead,
                   output: a.output + b.output)
    }
}

/// Usage of one request, priced by the model that served it. When a refusal fallback
/// served the request, only the serving attempt's usage is reported by the API.
public struct UsageReport: Equatable, Sendable {
    public let model: String
    public let tokens: TokenUsage
    public let cost: Double

    public init(model: String, tokens: TokenUsage, cost: Double) {
        self.model = model
        self.tokens = tokens
        self.cost = cost
    }
}
