import AVFoundation
import CaptureKit
import Foundation
import Testing
import TranscriptCore
@testable import SessionKit

@MainActor
private func recording(source: FakeSource, transcriber: FakeTranscriber = FakeTranscriber()) async throws -> SessionController {
    let session = SessionController(root: try makeTempRoot(), transcriber: transcriber,
                                    makeSource: { _ in source }, notes: nil, retranscribe: { false })
    await session.start(.microphone)
    #expect(await waitUntil { session.elapsed >= 2 })
    return session
}

/// Paused audio (an ad, an interruption) is not recorded, not transcribed, and not timed.
@MainActor @Test func pausedAudioIsDiscarded() async throws {
    let source = FakeSource(seconds: 2)
    let transcriber = FakeTranscriber()
    let session = try await recording(source: source, transcriber: transcriber)

    session.pause()
    #expect(session.isPaused)
    source.push(seconds: 3, amplitude: 0.5)
    #expect(await waitUntil { session.skippedDuration >= 3 })
    session.resume()
    #expect(!session.isPaused)
    source.push(seconds: 1, amplitude: 0.5)
    #expect(await waitUntil { session.elapsed >= 3 })

    #expect(session.elapsed == 3)
    #expect(session.skippedDuration == 3)
    await session.stop()

    // The live pass saw 3 s, with contiguous sample positions across the pause.
    let received = transcriber.received
    #expect(received.reduce(0) { $0 + $1.samples.count } == 3 * 16_000)
    #expect(zip(received, received.dropFirst()).allSatisfy { $0.startSample + Int64($0.samples.count) == $1.startSample })

    // The recording holds the same 3 s.
    guard case .done(let info) = session.state else { Issue.record("not done: \(session.state)"); return }
    let file = try AVAudioFile(forReading: info.folder.appendingPathComponent("audio.m4a"))
    #expect(abs(Double(file.length) / file.processingFormat.sampleRate - 3) < 0.1)
}

@MainActor @Test func silenceWhilePausedDoesNotRaiseNoAudio() async throws {
    let source = FakeSource(seconds: 2)
    let session = try await recording(source: source)
    session.pause()
    source.push(seconds: 31, amplitude: 0)
    #expect(await waitUntil { session.skippedDuration >= 31 })
    #expect(!session.noAudio)
    await session.stop()
}

@MainActor @Test func pauseOnlyWhileRecording() async throws {
    let session = SessionController(root: try makeTempRoot(), transcriber: FakeTranscriber(),
                                    makeSource: { _ in FakeSource() }, notes: nil, retranscribe: { false })
    session.pause()
    #expect(!session.isPaused)
    await session.start(.microphone)
    session.pause()
    #expect(session.isPaused)
    await session.stop()
    #expect(!session.isPaused)
    await session.start(.microphone)
    #expect(!session.isPaused)
    #expect(session.skippedDuration == 0)
    await session.stop()
}

@MainActor @Test func togglePauseSwitches() async throws {
    let session = try await recording(source: FakeSource(seconds: 2))
    session.togglePause()
    #expect(session.isPaused)
    session.togglePause()
    #expect(!session.isPaused)
    await session.stop()
}
