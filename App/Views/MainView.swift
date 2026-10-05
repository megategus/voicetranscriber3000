import AppKit
import CaptureKit
import SwiftUI
import TranscriptCore

struct MainView: View {
    @State private var recording = DebugRecording()

    var body: some View {
        VStack(spacing: 16) {
            Text("VoiceTranscriber")
                .font(.largeTitle)
            Button(recording.isRecording ? "Stop" : "Start") {
                Task {
                    if recording.isRecording {
                        await recording.stop()
                    } else {
                        await recording.start()
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

/// Temporary microphone recording for Task 5; replaced by SessionController in Task 8.
@MainActor @Observable
final class DebugRecording {
    private(set) var isRecording = false
    private(set) var isBusy = false
    private(set) var status = "Records the microphone to audio.m4a."
    private(set) var folder: URL?

    private var source: MicrophoneSource?
    private var recorder: AudioRecorder?
    private var writer: SessionWriter?
    private var pump: Task<Void, Never>?

    func start() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/Transcripts", isDirectory: true)
            let writer = try SessionWriter.create(root: root, date: .now)
            let recorder = try AudioRecorder(cafURL: writer.audioCAF)
            let source = MicrophoneSource()
            let chunks = try await source.start()
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
