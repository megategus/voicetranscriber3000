import AssistantKit
import CaptureKit
import SessionKit
import SwiftUI

@main
struct VoiceTranscriberApp: App {
    @State private var speechModel: SpeechModel
    @State private var session: SessionController
    @State private var settings: AppSettings

    init() {
        let speechModel = SpeechModel()
        let settings = AppSettings()
        _speechModel = State(initialValue: speechModel)
        _settings = State(initialValue: settings)
        _session = State(initialValue: SessionController(
            root: settings.outputFolder,
            transcriber: speechModel.transcriber,
            makeSource: { kind in
                switch kind {
                case .computerAudio: SystemAudioSource()
                case .microphone: MicrophoneSource()
                }
            },
            notes: nil,               // Claude notes arrive in Task 12
            retranscribe: { settings.retranscribeAfterStop },
            // The key is read from the Keychain for each request, never stored elsewhere.
            claude: ClaudeClient(apiKey: { KeychainStore.apiKey.load() })
        ))
    }

    var body: some Scene {
        WindowGroup("VoiceTranscriber") {
            MainView(speechModel: speechModel, session: session)
                .frame(minWidth: 820, minHeight: 480)
                .task { await speechModel.load() }
                .onChange(of: settings.outputFolder, initial: true) { _, folder in
                    session.root = folder
                }
        }
        Settings {
            SettingsView(settings: settings)
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
