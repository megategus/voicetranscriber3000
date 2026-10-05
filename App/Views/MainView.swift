import AppKit
import CaptureKit
import SwiftUI
import TranscriptCore

struct MainView: View {
    @State private var recording = DebugRecording()
    @State private var sourceKind: AudioSourceKind = .computerAudio

    var body: some View {
        VStack(spacing: 16) {
            Text("VoiceTranscriber")
                .font(.largeTitle)
            Picker("Source", selection: $sourceKind) {
                ForEach(AudioSourceKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(recording.isRecording || recording.isBusy)
            Button(recording.isRecording ? "Stop" : "Start") {
                Task {
                    if recording.isRecording {
                        await recording.stop()
                    } else {
                        await recording.start(kind: sourceKind)
                    }
                }
            }
            .disabled(recording.isBusy)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            Text(recording.status)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)

            if let folder = recording.folder, !recording.isRecording {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
            }
        }
        .padding()
    }
}

/// Temporary recording for Tasks 5–6; replaced by SessionController in Task 8.
@MainActor @Observable
final class DebugRecording {
    private(set) var isRecording = false
    private(set) var isBusy = false
    private(set) var status = "Records the chosen source to audio.m4a."
    private(set) var folder: URL?

    private var source: (any AudioSource)?
    private var recorder: AudioRecorder?
    private var writer: SessionWriter?
    private var pump: Task<Void, Never>?

    func start(kind: AudioSourceKind) async {
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
            pump = Task {
                for await chunk in chunks {
                    try? await recorder.write(chunk)
                }
            }
            self.writer = writer
            self.recorder = recorder
            self.source = source
            folder = writer.folder
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
        status = "Saving audio…"
        await source.stop()
        await pump?.value
        do {
            try await recorder.finish(m4aURL: writer.audioM4A)
            status = "Saved \(writer.audioM4A.path)"
        } catch {
            status = "Could not save audio: \(error). The raw audio is in \(writer.audioCAF.lastPathComponent)."
        }
        isRecording = false
        self.source = nil
        self.recorder = nil
        self.writer = nil
        pump = nil
    }
}

#Preview {
    MainView()
}
