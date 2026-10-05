import AssistantKit
import SessionKit
import SwiftUI

/// Questions about the transcript while recording. One question at a time; the answer
/// streams in and is saved to `qa.md` when complete.
struct AskPanel: View {
    let session: SessionController
    @State private var question = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Ask about what was said…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Button("Ask", action: submit)
                    .disabled(!session.canAsk || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack {
                quickButton("Summarize last 5 min", .summarizeLast5)
                quickButton("What did I miss?", .whatDidIMiss(since: nil))
                quickButton("Explain the last term", .explainLastTerm)
            }
            .controlSize(.small)

            answer

            if session.cost.questionCount > 0 {
                Text("\(session.cost.questionCount) questions this session: \(SessionCost.dollars(session.cost.questions))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func quickButton(_ title: String, _ action: QuickAction) -> some View {
        Button(title) { Task { await session.ask(action) } }
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
                VStack(alignment: .leading, spacing: 8) {
                    Text(session.askQuestion)
                        .font(.headline)
                    if session.isAsking, session.askAnswer.isEmpty {
                        ProgressView().controlSize(.small)
                    }
                    Text(Self.markdown(session.askAnswer))
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if session.askProblem == nil {
            Text(session.canAsk ? "Answers come from the transcript so far." : "Start a session to ask questions.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func problemView(_ problem: AskProblem) -> some View {
        HStack {
            switch problem {
            case .nothingYet:
                Text("Nothing transcribed yet")
            case .missingKey:
                Text("Add your API key in Settings")
                SettingsLink { Text("Open Settings") }
            case .unauthorized:
                Text("API key rejected")
                SettingsLink { Text("Open Settings") }
            case .refused:
                Text("Claude declined to answer this question.")
                retryButton
            case .failed(let message):
                Text(message)
                retryButton
            }
        }
        .foregroundStyle(.red)
        .font(.callout)
    }

    private var retryButton: some View {
        Button("Retry") { Task { await session.retryAsk() } }
            .disabled(!session.canAsk)
    }

    /// Renders inline Markdown (bold, italics, code) and keeps line breaks.
    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
