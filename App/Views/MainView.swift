import AppKit
import SessionKit
import SwiftUI
import TranscriptCore

struct MainView: View {
    let speechModel: SpeechModel
    let session: SessionController
    let settings: AppSettings
    @State private var sourceKind: AudioSourceKind = .computerAudio
    @State private var unfinished: [URL] = []
    @State private var showRecovery = false
    @State private var floatingPanel = FloatingPanelController()

    var body: some View {
        VStack(spacing: 12) {
            controls
            modelStatus
            banners
            HSplitView {
                TranscriptView(segments: session.segments, partial: session.partial)
                    .cardSurface()
                    .padding(.trailing, 6)
                    .frame(minWidth: 380)
                AskPanel(session: session)
                    .cardSurface()
                    .padding(.leading, 6)
                    .frame(minWidth: 320, idealWidth: 380)
            }
            footer
        }
        .padding(Theme.cardPadding)
        .parchmentSurface()
        .task { findUnfinished() }
        .sheet(isPresented: $showRecovery) {
            RecoveryView(
                folders: unfinished,
                canRecover: speechModel.isLoaded && !session.isBusy,
                recover: { folder in
                    unfinished.removeAll { $0 == folder }
                    showRecovery = false
                    Task { await session.recover(folder) }
                },
                ignore: { folder in
                    settings.ignoreRecovery(folder)
                    unfinished.removeAll { $0 == folder }
                    showRecovery = !unfinished.isEmpty
                },
                close: { showRecovery = false }
            )
        }
        .onChange(of: wantsFloatingPanel, initial: true) { _, show in
            if show {
                floatingPanel.show(session: session)
            } else {
                floatingPanel.hide()
            }
        }
    }

    private var wantsFloatingPanel: Bool {
        settings.showFloatingPanel && session.state == .recording
    }

    private func findUnfinished() {
        let ignored = Set(settings.ignoredRecoveries)
        unfinished = SessionRecovery.unfinished(in: settings.outputFolder)
            .filter { !ignored.contains($0.standardizedFileURL.path) }
        showRecovery = !unfinished.isEmpty
    }

    // MARK: - Top row

    private var controls: some View {
        HStack(spacing: Theme.gap) {
            ForEach(AudioSourceKind.allCases, id: \.self) { kind in
                Button(kind.displayName) { sourceKind = kind }
                    .buttonStyle(ChipButtonStyle(selected: sourceKind == kind))
                    .disabled(session.isBusy)
            }

            Divider().frame(height: 20).padding(.horizontal, 4)

            if session.state == .recording {
                Button { Task { await session.stop() } } label: {
                    HStack(spacing: 8) {
                        WaveformView(live: !session.isPaused, level: session.level, color: Theme.onInk)
                        Text("Stop")
                    }
                }
                .buttonStyle(PillButtonStyle(kind: .filled))
                .keyboardShortcut(.defaultAction)

                Button { session.togglePause() } label: {
                    Label(session.isPaused ? "Resume" : "Pause",
                          systemImage: session.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(PillButtonStyle(kind: .outlined))
                .help("Skip an ad or interruption: paused audio is not recorded or transcribed (⇧⌘P)")

                Text(formatTimestamp(session.elapsed))
                    .font(Theme.label.monospacedDigit())
                    .foregroundStyle(Theme.graphite)
                    .padding(.leading, 4)
            } else {
                Button { Task { await session.start(sourceKind) } } label: {
                    HStack(spacing: 8) {
                        WaveformView(live: false, color: Theme.onInk)
                        Text("Start")
                    }
                }
                .buttonStyle(PillButtonStyle(kind: .filled))
                .keyboardShortcut(.defaultAction)
                .disabled(session.isBusy || !speechModel.isLoaded)
            }

            Spacer()

            if session.isPaused {
                StatusPill(text: "Paused · \(formatTimestamp(session.skippedDuration)) skipped", systemImage: "pause.circle")
            }
            if session.isLagging, !session.isPaused {
                StatusPill(text: "Transcription lagging", systemImage: "tortoise")
            }

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(GhostButtonStyle())
            .help("Settings")
        }
        .animation(.spring(duration: 0.4, bounce: 0.3), value: session.state)
    }

    @ViewBuilder
    private var modelStatus: some View {
        if let error = speechModel.error {
            Notice(systemImage: "exclamationmark.triangle", text: "Could not load the speech model: \(error)") {
                Button("Retry") { Task { await speechModel.load() } }
                    .buttonStyle(GhostButtonStyle())
            }
        } else if !speechModel.isLoaded {
            HStack(spacing: Theme.gap) {
                ProgressView(value: speechModel.progress)
                    .frame(width: 160)
                Text("Loading speech model… \(Int(speechModel.progress * 100))%")
                    .font(Theme.small)
                    .foregroundStyle(Theme.graphite)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var banners: some View {
        if session.state == .recording, session.noAudio, !session.isPaused {
            Notice(systemImage: "speaker.slash", text: "No audio detected — check the source.") { EmptyView() }
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
                .card(padding: 12)
        case .done(let info):
            done(info)
                .card()
        case .failed(let message):
            Notice(systemImage: "exclamationmark.triangle", text: message) {
                if let kind = session.blockedPermission {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(SystemPermissions.settingsURL(for: kind))
                    }
                    .buttonStyle(GhostButtonStyle())
                }
            }
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
                    .monospacedDigit()
                Button("Cancel") { session.cancelRetranscription() }
                    .buttonStyle(GhostButtonStyle())
            case .writingNotes:
                ProgressView().controlSize(.small)
                Text(session.notesCharacters > 0
                     ? "Writing notes… \(session.notesCharacters.formatted()) characters"
                     : "Writing notes…")
                    .monospacedDigit()
            }
            Spacer()
        }
        .foregroundStyle(Theme.graphite)
    }

    private func done(_ info: DoneInfo) -> some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Text(info.folder.lastPathComponent)
                .font(Theme.title)
                .textSelection(.enabled)
            if let message = info.message {
                Text(message)
                    .foregroundStyle(Theme.graphite)
            }
            if !session.cost.isEmpty {
                Text("Claude cost \(SessionCost.dollars(session.cost.total)) · notes \(SessionCost.dollars(session.cost.notes)) · \(session.cost.questionCount) questions \(SessionCost.dollars(session.cost.questions))")
                    .font(Theme.small)
                    .foregroundStyle(Theme.ash)
            }
            HStack(spacing: Theme.gap) {
                if info.notesWritten {
                    Button {
                        NSWorkspace.shared.open(info.folder.appendingPathComponent(SessionWriter.FileName.notes))
                    } label: {
                        Label("Open notes", systemImage: "doc.text")
                    }
                    .buttonStyle(PillButtonStyle(kind: .filled, large: false))
                } else if session.canGenerateNotes {
                    Button {
                        Task { await session.generateNotes() }
                    } label: {
                        Label("Generate notes", systemImage: "sparkles")
                    }
                    .buttonStyle(PillButtonStyle(kind: .filled, large: false))
                    if info.needsSettings {
                        SettingsLink { Text("Open Settings") }
                            .buttonStyle(GhostButtonStyle())
                    }
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([info.folder])
                }
                .buttonStyle(GhostButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An inline notice: icon and text in ink on a hairline-bordered strip, with optional actions.
struct Notice<Actions: View>: View {
    let systemImage: String
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: Theme.gap) {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.graphite)
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            actions
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Theme.shape(Theme.inputRadius).strokeBorder(Theme.warmMist))
    }
}
