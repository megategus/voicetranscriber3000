import AVFoundation
import CaptureKit
import Foundation
import Testing
import TranscriptCore
@testable import SessionKit

private let lines = [
    Segment(start: 1, end: 3, text: "Today we cover derivatives."),
    Segment(start: 4, end: 6, text: "The slope of a curve."),
]
private let fileLines = [
    Segment(start: 1, end: 3, text: "Today we cover derivatives (file)."),
    Segment(start: 4, end: 6, text: "The slope of a curve (file)."),
]

@MainActor
private func makeController(
    root: URL,
    transcriber: FakeTranscriber,
    source: AudioSource = FakeSource(),
    notes: NotesMaking? = FakeNotes(),
    retranscribe: Bool = true
) -> SessionController {
    SessionController(
        root: root,
        transcriber: transcriber,
        makeSource: { _ in source },
        notes: notes,
        retranscribe: { retranscribe }
    )
}

private func read(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

private func doneInfo(_ state: SessionState) -> DoneInfo? {
    if case .done(let info) = state { return info }
    return nil
}

@MainActor @Test func startStopHappyPath() async throws {
    let root = try makeTempRoot()
    let transcriber = FakeTranscriber(live: lines.map { .final($0) }, file: .success(fileLines))
    let controller = makeController(root: root, transcriber: transcriber)

    await controller.start(.microphone)
    #expect(controller.state == .recording)
    await controller.stop()

    let info = try #require(doneInfo(controller.state))
    #expect(info.notesWritten)
    #expect(info.folder.lastPathComponent.hasSuffix(" Derivatives Intro"))
    let fm = FileManager.default
    for file in ["transcript.live.md", "transcript.md", "notes.md", "audio.m4a"] {
        #expect(fm.fileExists(atPath: info.folder.appendingPathComponent(file).path), "\(file)")
    }
    #expect(!fm.fileExists(atPath: info.folder.appendingPathComponent("audio.caf").path))
    #expect(try read(info.folder.appendingPathComponent("transcript.live.md")) == "[00:01] Today we cover derivatives.\n[00:04] The slope of a curve.\n")
    #expect(try read(info.folder.appendingPathComponent("transcript.md")).contains("(file)"))
    #expect(controller.segments == lines)
}

@MainActor @Test func notesUseFinalTranscript() async throws {
    let notes = FakeNotes()
    let controller = makeController(root: try makeTempRoot(),
                                    transcriber: FakeTranscriber(live: lines.map { .final($0) }, file: .success(fileLines)),
                                    notes: notes)
    await controller.start(.microphone)
    await controller.stop()
    #expect(await notes.calls == [fileLines])
}

@MainActor @Test func retranscribeOffCopiesLive() async throws {
    let transcriber = FakeTranscriber(live: lines.map { .final($0) }, file: .success(fileLines))
    let controller = makeController(root: try makeTempRoot(), transcriber: transcriber, retranscribe: false)
    await controller.start(.microphone)
    await controller.stop()
    let folder = try #require(doneInfo(controller.state)).folder
    #expect(transcriber.fileCalls == 0)
    #expect(try read(folder.appendingPathComponent("transcript.md")) == read(folder.appendingPathComponent("transcript.live.md")))
}

@MainActor @Test func retranscribeFailureFallsBackToLive() async throws {
    let notes = FakeNotes()
    let transcriber = FakeTranscriber(live: lines.map { .final($0) }, file: .failure(FakeTranscriber.Failure()))
    let controller = makeController(root: try makeTempRoot(), transcriber: transcriber, notes: notes)
    await controller.start(.microphone)
    await controller.stop()
    let info = try #require(doneInfo(controller.state))
    #expect(try read(info.folder.appendingPathComponent("transcript.md")) == read(info.folder.appendingPathComponent("transcript.live.md")))
    #expect(info.notesWritten)
    #expect(await notes.calls == [lines])
}

@MainActor @Test func cancelRetranscriptionFallsBackToLive() async throws {
    let transcriber = FakeTranscriber(live: lines.map { .final($0) }, file: .success(fileLines), fileHangs: true)
    let controller = makeController(root: try makeTempRoot(), transcriber: transcriber)
    await controller.start(.microphone)
    let stopping = Task { await controller.stop() }
    #expect(await waitUntil {
        if case .finalizing(.retranscribing) = controller.state { return true }
        return false
    })
    controller.cancelRetranscription()
    await stopping.value
    let info = try #require(doneInfo(controller.state))
    #expect(try read(info.folder.appendingPathComponent("transcript.md")) == read(info.folder.appendingPathComponent("transcript.live.md")))
    #expect(info.notesWritten)
}

@MainActor @Test func notesFailureEndsDoneWithoutNotes() async throws {
    let controller = makeController(root: try makeTempRoot(),
                                    transcriber: FakeTranscriber(live: lines.map { .final($0) }),
                                    notes: FakeNotes(failing: ()))
    await controller.start(.microphone)
    await controller.stop()
    let info = try #require(doneInfo(controller.state))
    #expect(!info.notesWritten)
    #expect(!FileManager.default.fileExists(atPath: info.folder.appendingPathComponent("notes.md").path))
    #expect(controller.canGenerateNotes)

    controller.notes = FakeNotes(title: "Second Try")
    await controller.generateNotes()
    let retried = try #require(doneInfo(controller.state))
    #expect(retried.notesWritten)
    #expect(retried.folder.lastPathComponent.hasSuffix(" Second Try"))
    #expect(FileManager.default.fileExists(atPath: retried.folder.appendingPathComponent("notes.md").path))
}

@MainActor @Test func noNotesMakerEndsDoneWithoutNotes() async throws {
    let controller = makeController(root: try makeTempRoot(),
                                    transcriber: FakeTranscriber(live: lines.map { .final($0) }),
                                    notes: nil)
    await controller.start(.microphone)
    await controller.stop()
    let info = try #require(doneInfo(controller.state))
    #expect(!info.notesWritten)
    #expect(info.message == "Add your API key in Settings to generate notes")
}

@MainActor @Test func finalizeWithEmptyTranscriptSkipsNotes() async throws {
    let notes = FakeNotes()
    let controller = makeController(root: try makeTempRoot(), transcriber: FakeTranscriber(), notes: notes)
    await controller.start(.microphone)
    await controller.stop()
    let info = try #require(doneInfo(controller.state))
    #expect(!info.notesWritten)
    #expect(info.message == "No speech detected")
    #expect(!controller.canGenerateNotes)
    #expect(await notes.calls.isEmpty)
    #expect(try read(info.folder.appendingPathComponent("transcript.live.md")) == "")
    #expect(try read(info.folder.appendingPathComponent("transcript.md")) == "")
}

@MainActor @Test func sourceFailureLeavesNoFolder() async throws {
    let root = try makeTempRoot()
    let controller = makeController(root: root, transcriber: FakeTranscriber(), source: FailingSource())
    await controller.start(.computerAudio)
    guard case .failed = controller.state else {
        Issue.record("expected .failed, got \(controller.state)")
        return
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@MainActor @Test func lagFlagSetAfterTenSeconds() async throws {
    let controller = makeController(root: try makeTempRoot(), transcriber: FakeTranscriber(),
                                    source: FakeSource(seconds: 15, amplitude: 0.5))
    await controller.start(.microphone)
    #expect(await waitUntil { controller.isLagging })
    #expect(await waitUntil { controller.elapsed >= 15 })
    await controller.stop()
}

@MainActor @Test func noLagWhileFinalsKeepUp() async throws {
    let finals = (0..<7).map { TranscriptEvent.final(Segment(start: Double($0) * 2, end: Double($0) * 2 + 2, text: "line \($0)")) }
    let controller = makeController(root: try makeTempRoot(), transcriber: FakeTranscriber(live: finals),
                                    source: FakeSource(seconds: 15, amplitude: 0.5))
    await controller.start(.microphone)
    #expect(await waitUntil { controller.elapsed >= 15 && controller.segments.count == 7 })
    #expect(!controller.isLagging)
    await controller.stop()
}

@MainActor @Test func noAudioFlagAfterThirtySecondsOfSilence() async throws {
    let source = FakeSource(seconds: 31, amplitude: 0)
    let controller = makeController(root: try makeTempRoot(), transcriber: FakeTranscriber(), source: source)
    await controller.start(.microphone)
    #expect(await waitUntil { controller.noAudio })
    source.push(seconds: 0.5, amplitude: 0.5)
    #expect(await waitUntil { !controller.noAudio })
    await controller.stop()
}

@MainActor @Test func recoverRunsFinalizeOnFolder() async throws {
    let root = try makeTempRoot()
    let folder = root.appendingPathComponent("2026-10-05 09-00", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "[00:01] Today we cover derivatives.\n".write(to: folder.appendingPathComponent("transcript.live.md"), atomically: true, encoding: .utf8)
    do {
        // A crash leaves a CAF that was written but never converted.
        let file = try AVAudioFile(forWriting: folder.appendingPathComponent("audio.caf"),
                                   settings: PCMConverter.outputFormat.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = FakeSource.chunks(seconds: 1, amplitude: 0.5, from: 0)[0]
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: PCMConverter.outputFormat, frameCapacity: AVAudioFrameCount(chunk.samples.count)))
        buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
        chunk.samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        try file.write(from: buffer)
    }
    let notes = FakeNotes()
    let controller = makeController(root: root, transcriber: FakeTranscriber(file: .failure(FakeTranscriber.Failure())), notes: notes)

    await controller.recover(folder)

    let info = try #require(doneInfo(controller.state))
    #expect(info.notesWritten)
    let fm = FileManager.default
    #expect(fm.fileExists(atPath: info.folder.appendingPathComponent("audio.m4a").path))
    #expect(fm.fileExists(atPath: info.folder.appendingPathComponent("notes.md").path))
    #expect(!fm.fileExists(atPath: info.folder.appendingPathComponent("audio.caf").path))
    #expect(await notes.calls.first?.map(\.text) == ["Today we cover derivatives."])
}
