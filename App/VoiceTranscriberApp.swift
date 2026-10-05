import CaptureKit
import SessionKit
import SwiftUI

@main
struct VoiceTranscriberApp: App {
    @State private var speechModel: SpeechModel
    @State private var session: SessionController

    init() {
        let speechModel = SpeechModel()
        _speechModel = State(initialValue: speechModel)
        _session = State(initialValue: SessionController(
            root: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/Transcripts", isDirectory: true),
            transcriber: speechModel.transcriber,
            makeSource: { kind in
                switch kind {
                case .computerAudio: SystemAudioSource()
                case .microphone: MicrophoneSource()
                }
            },
            notes: nil,               // Claude notes arrive in Task 12
            retranscribe: { true }    // Settings toggle arrives in Task 9
        ))
    }

    var body: some Scene {
        WindowGroup("VoiceTranscriber") {
            MainView(speechModel: speechModel, session: session)
                .frame(minWidth: 560, minHeight: 420)
                .task { await speechModel.load() }
        }
    }
}

/// The Whisper model, loaded once at launch.
@MainActor @Observable
final class SpeechModel {
    let transcriber = WhisperKitTranscriber()
    private(set) var progress: Double = 0
    private(set) var isLoaded = false
    private(set) var error: String?

    func load() async {
        guard !isLoaded else { return }
        error = nil
        do {
            try await transcriber.load { [weak self] value in
                Task { @MainActor in self?.progress = value }
            }
            isLoaded = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}
