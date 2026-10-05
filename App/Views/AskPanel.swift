import AssistantKit
import SessionKit
import SwiftUI

/// Questions about the transcript while recording. One question at a time; the answer
/// streams in and is saved to `qa.md` when complete.
struct AskPanel: View {
    let session: SessionController
    @State private var question = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: Theme.gap) {
                TextField("Ask about what was said…", text: $question)
                    .focused($focused)
                    .onSubmit(submit)
                    .modifier(InputFieldStyle(focused: focused))
                Button("Ask", action: submit)
                    .buttonStyle(PillButtonStyle(kind: .filled, large: false))
                    .disabled(!session.canAsk || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack(spacing: 6) {
                quickButton("Summarize last 5 min", .summarizeLast5)
                quickButton("What did I miss?", .whatDidIMiss(since: nil))
                quickButton("Explain the last term", .explainLastTerm)
            }
            .font(Theme.small)

            answer

            Spacer(minLength: 0)

            if session.cost.questionCount > 0 {
                Text("\(session.cost.questionCount) questions this session · \(SessionCost.dollars(session.cost.questions))")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.ash)
            }
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func quickButton(_ title: String, _ action: QuickAction) -> some View {
        Button(title) { Task { await session.ask(action) } }
            .buttonStyle(ChipButtonStyle())
            .disabled(!session.canAsk)
    }

    private func submit() {
        let text = question
        guard session.canAsk, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        question = ""
        Task { await session.ask(text) }
    }

    @ViewBuilder
    private var answer: some View {
        if let problem = session.askProblem {
            problemView(problem)
        }
        if !session.askQuestion.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gap) {
                    Text(session.askQuestion)
                        .font(Theme.title)
                    if session.isAsking, session.askAnswer.isEmpty {
                        WaveformView(live: true, level: 0.08, color: Theme.graphite)
                    }
                    Text(Self.markdown(session.askAnswer))
                        .font(Theme.body)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
        } else if session.askProblem == nil {
            Text(session.canAsk ? "Answers come from the transcript so far." : "Start a session to ask questions.")
                .foregroundStyle(Theme.ash)
        }
    }

    @ViewBuilder
    private func problemView(_ problem: AskProblem) -> some View {
        switch problem {
        case .nothingYet:
            Notice(systemImage: "text.bubble", text: "Nothing transcribed yet") { EmptyView() }
        case .missingKey:
            Notice(systemImage: "key", text: "Add your API key in Settings") {
                SettingsLink { Text("Open Settings") }.buttonStyle(GhostButtonStyle())
            }
        case .unauthorized:
            Notice(systemImage: "key", text: "API key rejected") {
                SettingsLink { Text("Open Settings") }.buttonStyle(GhostButtonStyle())
            }
        case .refused:
            Notice(systemImage: "hand.raised", text: "Claude declined to answer this question.") { retryButton }
        case .failed(let message):
            Notice(systemImage: "exclamationmark.triangle", text: message) { retryButton }
        }
    }

    private var retryButton: some View {
        Button("Retry") { Task { await session.retryAsk() } }
            .buttonStyle(GhostButtonStyle())
            .disabled(!session.canAsk)
    }

    /// Renders inline Markdown (bold, italics, code) and keeps line breaks.
    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
