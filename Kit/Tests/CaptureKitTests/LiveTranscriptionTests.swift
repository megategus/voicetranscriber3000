import Foundation
import Testing
import TranscriptCore
@testable import CaptureKit

/// Each sample holds its own absolute index, so the fake decoder knows which part of the
/// "recording" it was given. The ground truth is one segment every 3 s ("word 0", "word 1", …);
/// a segment cut off by the end of the window comes back as "partial N", like a growing
/// sentence in real Whisper output.
private let fakeDecode: LiveTranscription.Decode = { samples in
    guard let firstValue = samples.first else { return [] }
    let first = Double(firstValue) / sampleRate
    let last = first + Double(samples.count) / sampleRate
    var result: [Segment] = []
    var n = Int(first / 3)
    while Double(n) * 3 < last {
        let start = max(Double(n) * 3, first)
        let end = Double(n + 1) * 3
        if end <= last + 0.001 {
            result.append(Segment(start: start - first, end: end - first, text: "word \(n)"))
        } else if last - start > 0.2 {
            result.append(Segment(start: start - first, end: last - first, text: "partial \(n)"))
        }
        n += 1
    }
    return result
}

private func audio(seconds: Int) -> AsyncStream<AudioChunk> {
    AsyncStream { continuation in
        let chunk = Int(sampleRate / 2)
        for start in stride(from: 0, to: seconds * Int(sampleRate), by: chunk) {
            let samples = (start..<start + chunk).map { Float($0) }
            continuation.yield(AudioChunk(samples: samples, startSample: Int64(start)))
        }
        continuation.finish()
    }
}

private func finals(_ events: AsyncStream<TranscriptEvent>) async -> [Segment] {
    var result: [Segment] = []
    for await event in events {
        if case .final(let segment) = event { result.append(segment) }
    }
    return result
}

@Test func liveLoopConfirmsEverySegmentOnce() async {
    let segments = await finals(LiveTranscription.run(audio(seconds: 21), decode: fakeDecode))
    #expect(segments.map(\.text) == (0..<7).map { "word \($0)" })
    #expect(segments.map(\.start) == (0..<7).map { Double($0) * 3 })
}

/// The first decode is slow, so all 90 s pile up — far more than one 30 s window.
/// Nothing may be skipped.
@Test func liveLoopNeverDropsAudioWhenBehind() async {
    let calls = Counter()
    let slowFirst: LiveTranscription.Decode = { samples in
        if await calls.next() == 0 {
            try await Task.sleep(for: .milliseconds(200))
        }
        return try await fakeDecode(samples)
    }
    let segments = await finals(LiveTranscription.run(audio(seconds: 90), decode: slowFirst))
    #expect(segments.map(\.text) == (0..<30).map { "word \($0)" })
    #expect(zip(segments, segments.dropFirst()).allSatisfy { $0.start < $1.start })
}

private actor Counter {
    private var value = 0
    func next() -> Int {
        defer { value += 1 }
        return value
    }
}
