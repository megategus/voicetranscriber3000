import AssistantKit
import CaptureKit
import Foundation
import Observation
import TranscriptCore

/// Writes study notes from a finished transcript. `progress` receives the number of
/// characters generated so far.
public protocol NotesMaking: Sendable {
    func makeNotes(
        transcript: [Segment],
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> (title: String, markdown: String)
}

extension Assistant: NotesMaking {}

public enum FinalizeStep: Equatable, Sendable {
    case savingAudio
    case retranscribing(Double)
    case writingNotes
}

public struct DoneInfo: Equatable, Sendable {
    public let folder: URL
    public let notesWritten: Bool
    public let message: String?
    /// The API key is missing or was rejected; the done screen offers Open Settings.
    public var needsSettings = false
}

/// Why the last question got no answer, for the Ask panel.
public enum AskProblem: Equatable, Sendable {
    case nothingYet
    case missingKey
    case unauthorized
    case refused
    case failed(String)

    public var message: String {
        switch self {
        case .nothingYet: "Nothing transcribed yet"
        case .missingKey: "Add your API key in Settings"
        case .unauthorized: "API key rejected"
        case .refused: "Claude declined to answer"
        case .failed(let message): message
        }
    }
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
    /// Seconds of audio recorded in this session (paused time not included).
    public private(set) var elapsed: TimeInterval = 0
    /// Smoothed RMS level of the incoming audio (0 when not recording or paused), for the
    /// waveform on the Stop button.
    public private(set) var level: Float = 0
    /// While paused, audio is discarded: not recorded, not transcribed, not timed.
    public private(set) var isPaused = false
    /// Seconds of audio discarded while paused.
    public private(set) var skippedDuration: TimeInterval = 0

    /// Settable so Settings can change them between sessions.
    public var root: URL
    public var notes: (any NotesMaking)?

    /// Questions during recording and notes; nil when no Claude client was given.
    public private(set) var assistant: Assistant?
    /// Claude cost for this session (questions and notes), at list prices.
    public private(set) var cost = SessionCost()
    private let costs = CostAccumulator()
    public private(set) var askQuestion = ""
    public private(set) var askAnswer = ""
    public private(set) var askProblem: AskProblem?
    public private(set) var isAsking = false
    /// Characters of notes received so far, shown while writing notes.
    public private(set) var notesCharacters = 0
    /// The source whose permission blocked the last Start, for the Open System Settings button.
    public private(set) var blockedPermission: AudioSourceKind?

    private let transcriber: any Transcriber
    private let makeSource: (AudioSourceKind) -> any AudioSource
    private let retranscribe: () -> Bool
    private let clock: () -> Date
    private let permissions: (any PermissionChecking)?

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
    private var recordedSamples: Int64 = 0
    private var skippedSamples: Int64 = 0

    // Asking
    private var lastQuestionTime: TimeInterval?
    private var lastAsked: String?
    private var askGeneration = 0

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
        clock: @escaping () -> Date = Date.init,
        claude: ClaudeClient? = nil,
        permissions: (any PermissionChecking)? = nil
    ) {
        self.permissions = permissions
        self.root = root
        self.transcriber = transcriber
        self.makeSource = makeSource
        self.notes = notes
        self.retranscribe = retranscribe
        self.clock = clock
        if let claude {
            let costs = costs
            assistant = Assistant(client: claude, store: store) { [weak self] kind, report in
                costs.add(kind, report)
                Task { @MainActor in self?.cost = costs.value }
            }
        }
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

    public var canAsk: Bool { state == .recording && assistant != nil }

    // MARK: - Asking

    /// Asks about the transcript so far. The answer streams into `askAnswer`; a finished
    /// answer is appended to `qa.md`. A new question replaces one still streaming.
    public func ask(_ question: String) async {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAsk, let assistant, !question.isEmpty else { return }
        askGeneration += 1
        let generation = askGeneration
        let now = elapsed
        let writer = writer
        askQuestion = question
        askAnswer = ""
        askProblem = nil
        isAsking = true
        lastAsked = question
        lastQuestionTime = now
        defer {
            if generation == askGeneration { isAsking = false }
        }
        do {
            let stream = try await assistant.ask(question, now: now)
            for try await delta in stream {
                guard generation == askGeneration else { return }
                askAnswer += delta
            }
            guard generation == askGeneration else { return }
            try? writer?.appendQA(question: question, answer: askAnswer, at: now)
        } catch {
            guard generation == askGeneration else { return }
            if error as? ClaudeError == .refusal {
                askAnswer = ""   // a declined answer's partial text is not kept
            }
            askProblem = Self.problem(for: error)
        }
    }

    public func ask(_ action: QuickAction) async {
        guard let assistant else { return }
        var action = action
        if case .whatDidIMiss(nil) = action {
            action = .whatDidIMiss(since: lastQuestionTime)
        }
        await ask(assistant.question(for: action, now: elapsed))
    }

    public func retryAsk() async {
        guard let lastAsked else { return }
        await ask(lastAsked)
    }

    private static func problem(for error: Error) -> AskProblem {
        switch error {
        case AskError.nothingYet: return .nothingYet
        case AskError.missingKey, ClaudeError.missingKey: return .missingKey
        case ClaudeError.unauthorized: return .unauthorized
        case ClaudeError.refusal: return .refused
        case ClaudeError.rateLimited: return .failed("Claude is busy right now. Try again in a moment.")
        case ClaudeError.server(let code): return .failed("Claude had a server problem (\(code)). Try again.")
        case ClaudeError.network(let message): return .failed("Network problem: \(message)")
        case ClaudeError.truncated: return .failed("The answer was cut off. Try again.")
        case ClaudeError.api(let message): return .failed(message)
        default: return .failed(error.localizedDescription)
        }
    }

    // MARK: - Recording

    public func start(_ kind: AudioSourceKind) async {
        guard !isBusy else { return }
        resetLiveState()
        await store.reset()
        blockedPermission = nil
        if let permissions {
            var status = await permissions.status(for: kind)
            if status == .notDetermined {
                status = await permissions.request(kind) ? .granted : .denied
            }
            guard status == .granted else {
                blockedPermission = kind
                state = .failed(SystemPermissions.deniedMessage(for: kind))
                return
            }
        }
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
                    guard let admitted = self?.admit(chunk) else { continue }
                    feed.yield(admitted)
                    try? await recorder.write(admitted)
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

    /// Stops recording and transcribing until `resume`, e.g. during an ad. The paused audio
    /// is dropped, so the recording, transcripts, and notes skip it entirely.
    public func pause() {
        guard state == .recording else { return }
        isPaused = true
        level = 0
        noAudio = false
        isLagging = false
    }

    public func resume() {
        guard state == .recording, isPaused else { return }
        isPaused = false
        silenceStart = elapsed
        lastLoudWall = clock()
    }

    public func togglePause() {
        isPaused ? resume() : pause()
    }

    public func stop() async {
        guard state == .recording, let source, let recorder, let writer else { return }
        isPaused = false
        state = .finalizing(.savingAudio)
        level = 0
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
        func done(_ written: Bool, _ message: String? = nil, needsSettings: Bool = false) {
            if let message { messages.append(message) }
            cost = costs.value
            if !cost.isEmpty {
                try? writer.writeUsage(cost.markdown)
            }
            state = .done(DoneInfo(
                folder: writer.folder,
                notesWritten: written,
                message: messages.isEmpty ? nil : messages.joined(separator: " "),
                needsSettings: needsSettings
            ))
        }
        let missingKey = "Add your API key in Settings to generate notes"
        guard !transcript.isEmpty else { return done(false, "No speech detected") }
        guard let notes else { return done(false, missingKey, needsSettings: true) }
        state = .finalizing(.writingNotes)
        notesCharacters = 0
        do {
            let result = try await notes.makeNotes(transcript: transcript) { count in
                Task { @MainActor in self.updateNotesCharacters(count) }
            }
            try writer.writeNotes(result.markdown)
            try writer.rename(title: result.title)
            done(true)
        } catch AskError.missingKey, ClaudeError.missingKey {
            done(false, missingKey, needsSettings: true)
        } catch ClaudeError.unauthorized {
            done(false, "API key rejected. Check it in Settings, then Generate notes.", needsSettings: true)
        } catch ClaudeError.refusal {
            done(false, "Claude declined to write notes for this session.")
        } catch ClaudeError.truncated {
            done(false, "The notes were cut off before they were complete. Try Generate notes again.")
        } catch NotesError.invalidResponse {
            done(false, "Claude's response could not be read as notes. Try Generate notes again.")
        } catch {
            done(false, "Could not write notes. \(Self.problem(for: error).message)")
        }
    }

    private func updateNotesCharacters(_ count: Int) {
        // Progress callbacks hop here asynchronously and may arrive out of order.
        notesCharacters = max(notesCharacters, count)
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

    /// Drops a chunk while paused; otherwise gives it the next position in the recording
    /// (so time skips the paused stretch) and updates the level monitor.
    private func admit(_ chunk: AudioChunk) -> AudioChunk? {
        let count = Int64(chunk.samples.count)
        if isPaused {
            skippedSamples += count
            skippedDuration = Double(skippedSamples) / sampleRate
            return nil
        }
        let admitted = AudioChunk(samples: chunk.samples, startSample: recordedSamples)
        recordedSamples += count
        observe(admitted)
        return admitted
    }

    private func observe(_ chunk: AudioChunk) {
        elapsed = chunk.endTime
        let rms = AudioLevel.rms(chunk.samples)
        level = level * 0.5 + rms * 0.5
        if rms >= HallucinationFilter.speechThreshold {
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
        if state == .recording, !isPaused, clock().timeIntervalSince(lastLoudWall) >= Self.noAudioThreshold {
            noAudio = true
        }
    }

    private func resetLiveState() {
        costs.reset()
        cost = SessionCost()
        askGeneration += 1
        askQuestion = ""
        askAnswer = ""
        askProblem = nil
        isAsking = false
        lastQuestionTime = nil
        lastAsked = nil
        segments = []
        partial = ""
        isLagging = false
        noAudio = false
        elapsed = 0
        level = 0
        isPaused = false
        skippedDuration = 0
        recordedSamples = 0
        skippedSamples = 0
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
