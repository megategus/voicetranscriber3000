import SwiftUI

struct MainView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("VoiceTranscriber")
                .font(.largeTitle)
            Button("Start") {}
                .disabled(true)
                .controlSize(.large)
        }
        .padding()
    }
}

#Preview {
    MainView()
}
