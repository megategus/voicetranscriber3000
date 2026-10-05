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
                .font(Theme.title)
            Text("These sessions were interrupted. Recover finishes them: it saves the audio, writes transcript.md, and generates notes.")
                .foregroundStyle(Theme.graphite)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(folders, id: \.self) { folder in
                HStack(spacing: Theme.gap) {
                    Text(folder.lastPathComponent)
                    Spacer()
                    Button("Ignore") { ignore(folder) }
                        .buttonStyle(GhostButtonStyle())
                    Button("Recover") { recover(folder) }
                        .buttonStyle(PillButtonStyle(kind: .filled, large: false))
                        .disabled(!canRecover)
                }
                .card(padding: 12)
            }
            if !canRecover {
                Text("Recover is available once the speech model has loaded.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.ash)
            }
            HStack {
                Spacer()
                Button("Later", action: close)
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .parchmentSurface()
    }
}
