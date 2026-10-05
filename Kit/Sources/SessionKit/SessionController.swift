import CaptureKit
import Foundation
import Observation
import TranscriptCore

/// Writes study notes from a finished transcript (Claude, in Task 12).
public protocol NotesMaking: Sendable {
    func makeNotes(transcript: [Segment]) async throws -> (title: String, markdown: String)
}

public enum FinalizeStep: Equatable, Sendable {
    case savingAudio
    case retranscribing(Double)
    case writingNotes
}

public struct DoneInfo: Equatable, Sendable {
    public let folder: URL
    public let notesWritten: Bool
    public let message: String?
}

public enum SessionState: Equatable, Sendable {
    case idle
    case recording
    case finalizing(FinalizeStep)
    case done(DoneInfo)
    case failed(String)
}

/// Runs one session at a time: idle → recording → finalizing → done (or failed).
///
/// While recording, every audio chunk goes to the recorder (`audio.caf`), the transcriber,
/// and the level monitor. Final lines go to the store and `transcript.live.md`. On Stop it
/// saves `audio.m4a`, optionally re-transcribes the whole file, writes `transcript.md`,
/// then notes, and renames the folder after the notes title.
@MainActor @Observable
public final class SessionController {
    public static let lagThreshold: TimeInterval = 10
    public static let noAudioThreshold: TimeInterval = 30

    public private(set) var state: SessionState = .idle
    public let store = TranscriptStore()
    /// Mirrors of the store for SwiftUI, which can't read an actor synchronously.
    public private(set) var segments: [Segment] = []
    public private(set) var partial = ""
    public private(set) var isLagging = false
    public private(set) var noAudio = false
    /// Seconds of audio recorded in this session.
    public private(set) var elapsed: TimeInterval = 0

    /// Settable so Settings can change them between sessions.
    public var root: URL
    public var notes: (any NotesMaking)?

    private let transcriber: any Transcriber
    private let makeSource: (AudioSourceKind) -> any AudioSource
    private let retranscribe: () -> Bool
    private let clock: () -> Date

    // Recording
    private var source: (any AudioSource)?
    private var recorder: AudioRecorder?
    private var writer: SessionWriter?
    private var pump: Task<Void, Never>?
    private var transcription: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var lastFinalEnd: TimeInterval = 0
    private var lastSpeech: TimeInterval?
    private var silenceStart: TimeInterval = 0
    private var lastLoudWall = Date()

    // Finalizing
    private var fileResume: CheckedContinuation<[Segment]?, Never>?
    private var fileTask: Task<Void, Never>?
    /// What notes are generated from; kept for **Generate notes**.
    private var finished: (writer: SessionWriter, transcript: [Segment])?

    public init(
        root: URL,
        transcriber: any Transcriber,
        makeSource: @escaping (AudioSourceKind) -> any AudioSource,
        notes: (any NotesMaking)?,
        retranscribe: @escaping () -> Bool,
        clock: @escaping () -> Date = Date.init
    ) {
        self.root = root
        self.transcriber = transcriber
        self.makeSource = makeSource
        self.notes = notes
        self.retranscribe = retranscribe
        self.clock = clock
    }

    public var isBusy: Bool {
        switch state {
        case .recording, .finalizing: true
        default: false
        }
    }

    /// True on the done screen when there is a transcript to write notes from.
    public var canGenerateNotes: Bool {
        guard case .done(let info) = state, !info.notesWritten else { return false }
        return finished.map { !$0.transcript.isEmpty } ?? false
    }

    // MARK: - Recording

    public func start(_ kind: AudioSourceKind) async {
        guard !isBusy else { return }
        resetLiveState()
        await store.reset()
        let source = makeSource(kind)
        do {
            // Start the source first so a denied permission leaves no empty folder;
            // chunks wait in the stream until the recorder exists.
            let chunks = try await source.start()
            let writer: SessionWriter
            let recorder: AudioRecorder
            do {
                writer = try SessionWriter.create(root: root, date: clock())
                recorder = try AudioRecorder(cafURL: writer.audioCAF)
            } catch {
                await source.stop()
                throw error
            }
            self.source = source
            self.writer = writer
            self.recorder = recorder
            finished = nil

            let (toTranscriber, feed) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
            pump = Task { [weak self] in
                for await chunk in chunks {
                    feed.yield(chunk)
                    try? await recorder.write(chunk)
                    self?.observe(chunk)
                }
                feed.finish()
            }
            let events = transcriber.transcribe(toTranscriber)
            transcription = Task { [weak self] in
                for await event in events {
                    await self?.handle(event, writer: writer)
                }
            }
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    self?.checkWallClockSilence()
                }
            }
            state = .recording
        } catch {
            state = .failed("Could not start recording: \(error.localizedDescription)")
        }
    }

    public func stop() async {
        guard state == .recording, let source, let recorder, let writer else { return }
        state = .finalizing(.savingAudio)
        watchdog?.cancel()
        await source.stop()
        await pump?.value
        await transcription?.value
        isLagging = false
        noAudio = false
        await store.setPartial("")
        partial = ""

        var messages: [String] = []
        var audio = writer.audioM4A
        do {
            try await recorder.finish(m4aURL: writer.audioM4A)
        } catch {
            audio = writer.audioCAF
            messages.append("Could not convert the audio; the raw recording is kept as audio.caf.")
        }
        clearRecording()
        await finalize(writer: writer, audio: audio, live: segments, messages: messages)
    }

    // MARK: - Finalizing

    public func cancelRetranscription() {
        fileTask?.cancel()
        resumeFile(nil)
    }

    /// Retries notes after a failure, or after an API key was added.
    public func generateNotes() async {
        guard case .done = state, let finished else { return }
        await writeNotes(writer: finished.writer, transcript: finished.transcript, messages: [])
    }

    /// Runs the finalizing steps on a session folder left by a crash or quit.
    public func recover(_ folder: URL) async {
        guard !isBusy else { return }
        resetLiveState()
        await store.reset()
        let writer = SessionWriter(folder: folder)
        state = .finalizing(.savingAudio)
        var messages: [String] = []
        var audio = writer.audioM4A
        if FileManager.default.fileExists(atPath: writer.audioCAF.path) {
            do {
                try await AudioRecorder.exportM4A(from: writer.audioCAF, to: writer.audioM4A)
                try FileManager.default.removeItem(at: writer.audioCAF)
            } catch {
                audio = writer.audioCAF
                messages.append("Could not convert the audio; the raw recording is kept as audio.caf.")
            }
        }
        let liveText = (try? String(contentsOf: writer.liveTranscriptURL, encoding: .utf8)) ?? ""
        let live = parseTranscript(liveText)
        segments = live
        for segment in live {
            await store.append(segment)
        }
        await finalize(writer: writer, audio: audio, live: live, messages: messages)
    }

    private func finalize(writer: SessionWriter, audio: URL, live: [Segment], messages: [String]) async {
        var transcript = live
        var usedFilePass = false
        if retranscribe(), FileManager.default.fileExists(atPath: audio.path) {
            state = .finalizing(.retranscribing(0))
            if let fileSegments = await transcribeFile(audio), !fileSegments.isEmpty || live.isEmpty {
                // An empty file pass is only trusted when the live pass heard nothing too.
                do {
                    try writer.writeFinalTranscript(fileSegments)
                    transcript = fileSegments
                    usedFilePass = true
                } catch {}
            }
        }
        if !usedFilePass {
            try? writer.copyLiveToFinal()
        }
        finished = (writer, transcript)
        await writeNotes(writer: writer, transcript: transcript, messages: messages)
    }

    private func writeNotes(writer: SessionWriter, transcript: [Segment], messages: [String]) async {
        var messages = messages
        func done(_ written: Bool, _ message: String? = nil) {
            if let message { messages.append(message) }
            state = .done(DoneInfo(
                folder: writer.folder,
                notesWritten: written,
                message: messages.isEmpty ? nil : messages.joined(separator: " ")
            ))
        }
        guard !transcript.isEmpty else { return done(false, "No speech detected") }
        guard let notes else { return done(false, "Add your API key in Settings to generate notes") }
        state = .finalizing(.writingNotes)
        do {
            let result = try await notes.makeNotes(transcript: transcript)
            try writer.writeNotes(result.markdown)
            try writer.rename(title: result.title)
            done(true)
        } catch {
            done(false, "Could not write notes: \(error.localizedDescription)")
        }
    }

    /// Runs the file pass; returns nil if it failed or was cancelled. Cancel returns at
    /// once instead of waiting for the transcriber to notice.
    private func transcribeFile(_ url: URL) async -> [Segment]? {
        let transcriber = transcriber
        // Strong capture: the file pass ends (or is cancelled) before the session does.
        let onProgress: @Sendable (Double) -> Void = { progress in
            Task { @MainActor in self.updateRetranscribeProgress(progress) }
        }
        return await withCheckedContinuation { continuation in
            fileResume = continuation
            fileTask = Task {
                let result = try? await transcriber.transcribeFile(url, progress: onProgress)
                self.resumeFile(result)
            }
        }
    }

    private func resumeFile(_ result: [Segment]?) {
        fileResume?.resume(returning: result)
        fileResume = nil
        fileTask = nil
    }

    private func updateRetranscribeProgress(_ progress: Double) {
        if case .finalizing(.retranscribing) = state {
            state = .finalizing(.retranscribing(progress))
        }
    }

    // MARK: - Live updates

    private func handle(_ event: TranscriptEvent, writer: SessionWriter) async {
        switch event {
        case .final(let segment):
            await store.append(segment)
            try? writer.appendLive(segment)
            segments.append(segment)
            lastFinalEnd = max(lastFinalEnd, segment.end)
            updateLag()
        case .partial(let text):
            await store.setPartial(text)
            partial = text
        }
    }

    private func observe(_ chunk: AudioChunk) {
        elapsed = chunk.endTime
        if AudioLevel.rms(chunk.samples) >= HallucinationFilter.speechThreshold {
            lastSpeech = chunk.endTime
            silenceStart = chunk.endTime
            lastLoudWall = clock()
            noAudio = false
        } else if chunk.endTime - silenceStart >= Self.noAudioThreshold {
            noAudio = true
        }
        updateLag()
    }

    /// Lagging: speech was heard more than 10 s after the end of the newest final line.
    private func updateLag() {
        guard let lastSpeech else {
            isLagging = false
            return
        }
        isLagging = lastSpeech - lastFinalEnd > Self.lagThreshold
    }

    /// Catches a source that stops delivering audio entirely.
    private func checkWallClockSilence() {
        if state == .recording, clock().timeIntervalSince(lastLoudWall) >= Self.noAudioThreshold {
            noAudio = true
        }
    }

    private func resetLiveState() {
        segments = []
        partial = ""
        isLagging = false
        noAudio = false
        elapsed = 0
        lastFinalEnd = 0
        lastSpeech = nil
        silenceStart = 0
        lastLoudWall = clock()
    }

    private func clearRecording() {
        source = nil
        recorder = nil
        writer = nil
        pump = nil
        transcription = nil
        watchdog = nil
    }
}
