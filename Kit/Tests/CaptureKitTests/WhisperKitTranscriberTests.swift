import AVFoundation
import Foundation
import Testing
import TranscriptCore
@testable import CaptureKit

/// Uses the real model (downloaded on first run, ~1.6 GB) and a public-domain LibriVox clip.
@Suite(.serialized, .timeLimit(.minutes(10)))
struct WhisperKitTranscriberTests {
    static let transcriber = WhisperKitTranscriber()

    var clipURL: URL {
        get throws {
            try #require(Bundle.module.url(forResource: "librivox-clip", withExtension: "m4a", subdirectory: "Fixtures"))
        }
    }

    var reference: String {
        get throws {
            let url = try #require(Bundle.module.url(forResource: "librivox-clip", withExtension: "txt", subdirectory: "Fixtures"))
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    @Test func fileTranscriptionAccuracy() async throws {
        let clip = try clipURL
        let reference = try reference
        try await Self.transcriber.load { _ in }
        let segments = try await Self.transcriber.transcribeFile(clip) { _ in }
        let text = segments.map(\.text).joined(separator: " ")
        let wer = wordErrorRate(reference: reference, hypothesis: text)
        #expect(wer < 0.10, "WER \(wer): \(text)")
    }

    @Test func liveTranscriptionMatchesFile() async throws {
        let samples = try loadSamples(try clipURL)
        let reference = try reference
        try await Self.transcriber.load { _ in }
        let chunks = AsyncStream<AudioChunk> { continuation in
            let size = Int(sampleRate / 2)
            for start in stride(from: 0, to: samples.count, by: size) {
                continuation.yield(AudioChunk(
                    samples: Array(samples[start..<min(start + size, samples.count)]),
                    startSample: Int64(start)
                ))
            }
            continuation.finish()
        }
        var segments: [Segment] = []
        for await event in Self.transcriber.transcribe(chunks) {
            if case .final(let segment) = event { segments.append(segment) }
        }
        let text = segments.map(\.text).joined(separator: " ")
        let wer = wordErrorRate(reference: reference, hypothesis: text)
        #expect(wer < 0.15, "WER \(wer): \(text)")
        #expect(zip(segments, segments.dropFirst()).allSatisfy { $0.start < $1.start })
    }

    private func loadSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: buffer)
        let converter = try PCMConverter(from: file.processingFormat)
        return try converter.convert(buffer)
    }
}
