import AppKit
import SessionKit
import SwiftUI
import TranscriptCore

/// A small always-on-top window with the live transcript, for keeping an eye on it while
/// another app (the video, the meeting) is in front.
@MainActor
final class FloatingPanelController {
    private var panel: NSPanel?

    func show(session: SessionController) {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.title = "Live transcript"
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: FloatingTranscript(session: session))
            panel.setFrameAutosaveName("FloatingTranscriptPanel")
            if !panel.setFrameUsingName("FloatingTranscriptPanel") {
                panel.center()
            }
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

private struct FloatingTranscript: View {
    let session: SessionController

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(formatTimestamp(session.elapsed))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if session.isPaused {
                    Text("Paused").foregroundStyle(.orange)
                }
                Spacer()
                Button(session.isPaused ? "Resume" : "Pause") { session.togglePause() }
                    .controlSize(.small)
            }
            TranscriptView(segments: session.segments, partial: session.partial)
        }
        .padding(8)
        .frame(minWidth: 280, minHeight: 140)
    }
}
