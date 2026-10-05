import SessionKit
import SwiftUI

/// Offered on launch for sessions interrupted by a crash or quit (they still have
/// `audio.caf` and no notes).
struct RecoveryView: View {
    let folders: [URL]
    let canRecover: Bool
    let recover: (URL) -> Void
    let ignore: (URL) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Unfinished sessions")
                .font(.title2)
            Text("These sessions were interrupted. Recover finishes them: it saves the audio, writes transcript.md, and generates notes.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(folders, id: \.self) { folder in
                HStack {
                    Text(folder.lastPathComponent)
                    Spacer()
                    Button("Ignore") { ignore(folder) }
                    Button("Recover") { recover(folder) }
                        .disabled(!canRecover)
                }
            }
            if !canRecover {
                Text("Recover is available once the speech model has loaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Later", action: close)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
