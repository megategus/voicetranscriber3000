import AppKit
import SessionKit
import SwiftUI
import TranscriptCore

struct MainView: View {
    let speechModel: SpeechModel
    let session: SessionController
    @State private var sourceKind: AudioSourceKind = .computerAudio

    var body: some View {
        VStack(spacing: 12) {
            controls
            modelStatus
            banners
            HSplitView {
                TranscriptView(segments: session.segments, partial: session.partial)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                    .frame(minWidth: 380)
                AskPanel(session: session)
                    .frame(minWidth: 320, idealWidth: 380)
            }
            footer
        }
        .padding()
    }

    // MARK: - Top row

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Source", selection: $sourceKind) {
                ForEach(AudioSourceKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(session.isBusy)

            if session.state == .recording {
                Button("Stop") { Task { await session.stop() } }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                Text(formatTimestamp(session.elapsed))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Button("Start") { Task { await session.start(sourceKind) } }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.isBusy || !speechModel.isLoaded)
            }

            Spacer()

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .help("Settings")

            if session.isLagging {
                Label("Transcription lagging", systemImage: "tortoise")
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.2), in: Capsule())
            }
        }
    }

    @ViewBuilder
    private var modelStatus: some View {
        if let error = speechModel.error {
            HStack {
                Text("Could not load the speech model: \(error)")
                    .foregroundStyle(.red)
                Button("Retry") { Task { await speechModel.load() } }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if !speechModel.isLoaded {
            HStack {
                ProgressView(value: speechModel.progress)
                    .frame(width: 160)
                Text("Loading speech model… \(Int(speechModel.progress * 100))%")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var banners: some View {
        if session.state == .recording, session.noAudio {
            Label("No audio detected — check the source.", systemImage: "speaker.slash")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.yellow.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Bottom row

    @ViewBuilder
    private var footer: some View {
        switch session.state {
        case .idle, .recording:
            EmptyView()
        case .finalizing(let step):
            finalizing(step)
        case .done(let info):
            done(info)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func finalizing(_ step: FinalizeStep) -> some View {
        HStack(spacing: 12) {
            switch step {
            case .savingAudio:
                ProgressView().controlSize(.small)
                Text("Saving audio…")
            case .retranscribing(let progress):
                ProgressView(value: progress)
                    .frame(width: 160)
                Text("Re-transcribing full audio… \(Int(progress * 100))%")
                Button("Cancel") { session.cancelRetranscription() }
            case .writingNotes:
                ProgressView().controlSize(.small)
                Text("Writing notes…")
            }
            Spacer()
        }
        .foregroundStyle(.secondary)
    }

    private func done(_ info: DoneInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved to \(info.folder.lastPathComponent)")
                .textSelection(.enabled)
            if let message = info.message {
                Text(message)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([info.folder])
                }
                if info.notesWritten {
                    Button("Open notes") {
                        NSWorkspace.shared.open(info.folder.appendingPathComponent(SessionWriter.FileName.notes))
                    }
                } else if session.canGenerateNotes {
                    Button("Generate notes") { Task { await session.generateNotes() } }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
