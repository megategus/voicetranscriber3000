import Foundation
import Testing
import TranscriptCore
@testable import CaptureKit

/// Each sample holds its own absolute index, so the fake decoder knows which part of the
/// "recording" it was given. The ground truth is one word every 0.5 s ("w0", "w1", …), with
/// a full stop after every sixth word. A word cut off by the end of the window comes back
/// as "wN-", like a half-heard word in real Whisper output.
private func groundTruth(_ samples: [Float], prefix: String? = nil) -> [Word] {
    guard let firstValue = samples.first else { return [] }
    let first = Double(firstValue) / sampleRate
    let last = first + Double(samples.count) / sampleRate
    var result: [Word] = []
    var n = Int((first / 0.5).rounded(.up))
    while Double(n) * 0.5 < last {
        let start = Double(n) * 0.5
        let end = start + 0.4
        let text = "w\(n)" + (n % 6 == 5 ? "." : "")
        result.append(Word(start: start - first, end: min(end, last) - first, text: end <= last ? text : "w\(n)-"))
        n += 1
    }
    if let prefix, let head = result.first {
        result.insert(Word(start: max(0, head.start - 0.2), end: head.start, text: prefix), at: 0)
    }
    return result
}

private let fakeDecode: LiveTranscription.Decode = { groundTruth($0) }

/// `holdOpen` keeps the stream unfinished for a while after the last chunk, like a live
/// session that is still running.
private func audio(seconds: Int, holdOpen: Duration = .zero) -> AsyncStream<AudioChunk> {
    AsyncStream { continuation in
        let chunk = Int(sampleRate / 2)
        for start in stride(from: 0, to: seconds * Int(sampleRate), by: chunk) {
            let samples = (start..<start + chunk).map { Float($0) }
            continuation.yield(AudioChunk(samples: samples, startSample: Int64(start)))
        }
        Task {
            try? await Task.sleep(for: holdOpen)
            continuation.finish()
        }
    }
}

private func finals(_ events: AsyncStream<TranscriptEvent>) async -> [Segment] {
    var result: [Segment] = []
    for await event in events {
        if case .final(let segment) = event { result.append(segment) }
    }
    return result
}

private func words(in lines: [Segment]) -> [String] {
    lines.flatMap { $0.text.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) } }
}

private func expected(_ count: Int) -> [String] {
    (0..<count).map { "w\($0)" }
}

@Test func liveLoopConfirmsEveryWordOnce() async {
    let lines = await finals(LiveTranscription.run(audio(seconds: 21), decode: fakeDecode))
    #expect(words(in: lines) == expected(42))
    // Lines break at the full stops: six words each.
    #expect(lines.count == 7)
    #expect(lines.first?.text == "w0 w1 w2 w3 w4 w5.")
    #expect(lines.first?.start == 0)
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
    let lines = await finals(LiveTranscription.run(audio(seconds: 90), decode: slowFirst))
    #expect(words(in: lines) == expected(180))
    #expect(zip(lines, lines.dropFirst()).allSatisfy { $0.start < $1.start })
}

/// If decodes never agree (here every decode starts with a different filler word), text
/// must still come out once the buffer passes the stall limit, not be thrown away.
@Test func liveLoopEmitsEverythingWhenDecodesNeverAgree() async {
    let calls = Counter()
    let restless: LiveTranscription.Decode = { samples in
        let call = await calls.next()
        if call == 0 {
            try await Task.sleep(for: .milliseconds(200))
        }
        return groundTruth(samples, prefix: call.isMultiple(of: 2) ? "uh" : "um")
    }
    let lines = await finals(LiveTranscription.run(audio(seconds: 60, holdOpen: .seconds(1)), decode: restless))
    #expect(words(in: lines).filter { $0 != "uh" && $0 != "um" } == expected(120))
}

private actor Counter {
    private var value = 0
    func next() -> Int {
        defer { value += 1 }
        return value
    }
}
