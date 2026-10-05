import CaptureKit
import SwiftUI

@main
struct VoiceTranscriberApp: App {
    @State private var speechModel = SpeechModel()

    var body: some Scene {
        WindowGroup("VoiceTranscriber") {
            MainView(speechModel: speechModel)
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
