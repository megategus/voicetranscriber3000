import AppKit
import CaptureKit
import SwiftUI
import TranscriptCore

struct MainView: View {
    let speechModel: SpeechModel
    @State private var recording = DebugRecording()
    @State private var sourceKind: AudioSourceKind = .computerAudio

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Picker("Source", selection: $sourceKind) {
                    ForEach(AudioSourceKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(recording.isRecording || recording.isBusy)

                Button(recording.isRecording ? "Stop" : "Start") {
                    Task {
                        if recording.isRecording {
                            await recording.stop()
                        } else {
                            await recording.start(kind: sourceKind, transcriber: speechModel.transcriber)
                        }
                    }
                }
                .disabled(recording.isBusy || !speechModel.isLoaded)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Spacer()

                if let folder = recording.folder, !recording.isRecording {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                }
            }

            modelStatus

            TranscriptView(segments: recording.segments, partial: recording.partial)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))

            Text(recording.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding()
    }

    @ViewBuilder
    private var modelStatus: some View {
        if let error = speechModel.error {
            HStack {
                Text("Could not load the speech model: \(error)")
                    .foregroundStyle(.red)
                Button("Retry") { Task { await speechModel.load() } }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if !speechModel.isLoaded {
            HStack {
                ProgressView(value: speechModel.progress)
                    .frame(width: 160)
                Text("Loading speech model… \(Int(speechModel.progress * 100))%")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Temporary recording for Tasks 5–7; replaced by SessionController in Task 8.
@MainActor @Observable
final class DebugRecording {
    private(set) var isRecording = false
    private(set) var isBusy = false
    private(set) var status = "Records the chosen source and transcribes it live."
    private(set) var folder: URL?
    private(set) var segments: [Segment] = []
    private(set) var partial = ""

    private var source: (any AudioSource)?
    private var recorder: AudioRecorder?
    private var writer: SessionWriter?
    private var pump: Task<Void, Never>?
    private var transcription: Task<Void, Never>?

    func start(kind: AudioSourceKind, transcriber: any Transcriber) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/Transcripts", isDirectory: true)
            let source: any AudioSource = switch kind {
            case .computerAudio: SystemAudioSource()
            case .microphone: MicrophoneSource()
            }
            // Start the source first so a denied permission leaves no empty folder;
            // chunks wait in the stream until the recorder exists.
            let chunks = try await source.start()
            let writer: SessionWriter
            let recorder: AudioRecorder
            do {
                writer = try SessionWriter.create(root: root, date: .now)
                recorder = try AudioRecorder(cafURL: writer.audioCAF)
            } catch {
                await source.stop()
                throw error
            }

            // Tee each chunk to the recorder and the transcriber.
            let (toTranscriber, feed) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
            pump = Task {
                for await chunk in chunks {
                    feed.yield(chunk)
                    try? await recorder.write(chunk)
                }
                feed.finish()
            }
            let events = transcriber.transcribe(toTranscriber)
            transcription = Task { [weak self] in
                for await event in events {
                    switch event {
                    case .final(let segment):
                        try? writer.appendLive(segment)
                        self?.segments.append(segment)
                    case .partial(let text):
                        self?.partial = text
                    }
                }
            }

            self.writer = writer
            self.recorder = recorder
            self.source = source
            folder = writer.folder
            segments = []
            partial = ""
            isRecording = true
            status = "Recording to \(writer.folder.path)"
        } catch {
            status = "Could not start: \(error)"
        }
    }

    func stop() async {
        guard let source, let recorder, let writer else { return }
        isBusy = true
        defer { isBusy = false }
        status = "Finishing transcript…"
        await source.stop()
        await pump?.value
        await transcription?.value
        status = "Saving audio…"
        do {
            try await recorder.finish(m4aURL: writer.audioM4A)
            status = "Saved \(writer.folder.path)"
        } catch {
            status = "Could not save audio: \(error). The raw audio is in \(writer.audioCAF.lastPathComponent)."
        }
        isRecording = false
        self.source = nil
        self.recorder = nil
        self.writer = nil
        pump = nil
        transcription = nil
    }
}

#Preview {
    MainView(speechModel: SpeechModel())
}
