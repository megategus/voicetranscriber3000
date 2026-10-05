import SwiftUI

@main
struct VoiceTranscriberApp: App {
    var body: some Scene {
        WindowGroup("VoiceTranscriber") {
            MainView()
                .frame(minWidth: 560, minHeight: 420)
        }
    }
}
