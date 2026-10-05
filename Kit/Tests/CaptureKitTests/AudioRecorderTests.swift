import AVFoundation
import Foundation
import Testing
import TranscriptCore
@testable import CaptureKit

@Test func recorderWritesAndConvertsSine() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("AudioRecorderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let caf = dir.appendingPathComponent("audio.caf")
    let m4a = dir.appendingPathComponent("audio.m4a")

    let recorder = try AudioRecorder(cafURL: caf)
    let samples = sine(frequency: 440, seconds: 3)
    let chunkSize = 8_000  // 0.5 s
    for start in stride(from: 0, to: samples.count, by: chunkSize) {
        let chunk = AudioChunk(
            samples: Array(samples[start..<min(start + chunkSize, samples.count)]),
            startSample: Int64(start)
        )
        try await recorder.write(chunk)
    }
    try await recorder.finish(m4aURL: m4a)

    #expect(FileManager.default.fileExists(atPath: m4a.path))
    #expect(!FileManager.default.fileExists(atPath: caf.path))
    let file = try AVAudioFile(forReading: m4a)
    let duration = Double(file.length) / file.processingFormat.sampleRate
    #expect(abs(duration - 3.0) < 0.1)
}

/// The converter resamples in 4096-frame slices and holds back at most one slice
/// until the next buffer arrives, so check the total over a stream rather than per buffer.
@Test func pcmConverterDownsamples48kStereo() throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let converter = try PCMConverter(from: format)
    var out: [Float] = []
    var frame = 0
    for _ in 0..<10 {  // 10 × 4800 frames = 1 s
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        for i in 0..<4_800 {
            let value = Float(sin(2 * .pi * 440 * Double(frame + i) / 48_000))
            buffer.floatChannelData![0][i] = value
            buffer.floatChannelData![1][i] = value
        }
        frame += 4_800
        out += try converter.convert(buffer)
    }
    // One held-back slice is 4096 / 3 ≈ 1366 output samples.
    #expect(out.count <= 16_000)
    #expect(out.count >= 16_000 - 1_366)
    // Identical channels mix down to the same full-scale sine.
    #expect(abs(AudioLevel.rms(Array(out.dropFirst(200))) - 0.7071) < 0.02)
}
