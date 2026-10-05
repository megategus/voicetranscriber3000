import Foundation

/// Sample rate of all audio inside the app: 16 kHz mono Float32.
public let sampleRate: Double = 16_000

/// A run of 16 kHz mono samples. `startSample` counts samples since the session began.
public struct AudioChunk: Sendable, Equatable {
    public let samples: [Float]
    public let startSample: Int64

    public init(samples: [Float], startSample: Int64) {
        self.samples = samples
        self.startSample = startSample
    }

    public var startTime: TimeInterval { Double(startSample) / sampleRate }
    public var endTime: TimeInterval { Double(startSample + Int64(samples.count)) / sampleRate }
}

/// A piece of transcribed text. Times are seconds since the session began.
public struct Segment: Sendable, Equatable, Codable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum TranscriptEvent: Sendable, Equatable {
    case partial(String)
    case final(Segment)
}

public enum AudioSourceKind: String, CaseIterable, Sendable {
    case computerAudio
    case microphone

    public var displayName: String {
        switch self {
        case .computerAudio: "Computer audio"
        case .microphone: "Microphone"
        }
    }
}
