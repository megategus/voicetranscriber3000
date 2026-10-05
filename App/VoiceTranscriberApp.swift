import AppKit
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
        let session = SessionController(
            root: settings.outputFolder,
            transcriber: speechModel.transcriber,
            makeSource: { kind in
                switch kind {
                case .computerAudio: SystemAudioSource()
                case .microphone: MicrophoneSource()
                }
            },
            notes: nil,
            retranscribe: { settings.retranscribeAfterStop },
            // The key is read from the Keychain for each request, never stored elsewhere.
            claude: ClaudeClient(apiKey: { KeychainStore.apiKey.load() }),
            permissions: SystemPermissions()
        )
        // Claude writes the notes; a missing key is reported on the done screen, and
        // Generate notes works once a key is added.
        session.notes = session.assistant
        _session = State(initialValue: session)
    }

    var body: some Scene {
        WindowGroup("VoiceTranscriber") {
            MainView(speechModel: speechModel, session: session, settings: settings)
                .frame(minWidth: 820, minHeight: 480)
                .task { await speechModel.load() }
                .onChange(of: settings.outputFolder, initial: true) { _, folder in
                    session.root = folder
                }
                .onChange(of: settings.assistantConfiguration, initial: true) { _, configuration in
                    session.assistant?.configuration = configuration
                }
                .onChange(of: settings.appearance, initial: true) { _, appearance in
                    // App-wide, so Settings and the floating panel follow too. Pink is a light
                    // palette, so system controls stay in light appearance under it.
                    NSApp.appearance = switch appearance {
                    case .system: nil
                    case .light, .pink: NSAppearance(named: .aqua)
                    case .dark: NSAppearance(named: .darkAqua)
                    }
                    ThemeStore.shared.palette = appearance == .pink ? .pink : .standard
                }
        }
        .commands {
            CommandMenu("Session") {
                Button(session.isPaused ? "Resume Transcription" : "Pause Transcription") {
                    session.togglePause()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(session.state != .recording)
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
