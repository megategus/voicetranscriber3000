import AssistantKit
import CaptureKit
import Foundation
import Testing
import TranscriptCore
@testable import SessionKit

private let line = Segment(start: 1, end: 2, text: "Today we cover limits.")

/// Records, stops, and lets the real Assistant write notes against the HTTP stub.
@MainActor
private func finishSession(key: String? = "test-key") async throws -> SessionController {
    let controller = SessionController(
        root: try makeTempRoot(),
        transcriber: FakeTranscriber(live: [.final(line)]),
        makeSource: { _ in FakeSource(seconds: 2) },
        notes: nil,
        retranscribe: { false },
        claude: ClaudeClient(apiKey: { key }, session: HTTPStub.session, retryDelays: [.zero, .zero])
    )
    controller.notes = controller.assistant
    await controller.start(.microphone)
    await controller.stop()
    return controller
}

/// 1000 input + 2000 output tokens on Opus 5.5 = $0.044.
private func sseJSON(_ json: String) -> String {
    let event: [String: Any] = ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": json]]
    let data = try! JSONSerialization.data(withJSONObject: event)
    return #"data: {"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":1000,"output_tokens":1}}}"# + "\n\n"
        + "data: \(String(decoding: data, as: UTF8.self))\n\n"
        + #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2000}}"# + "\n\n"
}

@MainActor
private func done(_ controller: SessionController) throws -> DoneInfo {
    guard case .done(let info) = controller.state else { throw CocoaError(.featureUnsupported) }
    return info
}

extension StubbedNetworkTests {
    @Suite @MainActor
    struct SessionNotesTests {
        @Test func assistantNotesAreWrittenAndFolderRenamed() async throws {
            let json = ##"{"title":"Limits and Continuity","notes_markdown":"# Limits and Continuity\n## TL;DR\n- x"}"##
            HTTPStub.reset([(200, sseJSON(json))])
            let controller = try await finishSession()
            let info = try done(controller)
            #expect(info.notesWritten)
            #expect(info.folder.lastPathComponent.hasSuffix(" Limits and Continuity"))
            #expect(try String(contentsOf: info.folder.appendingPathComponent("notes.md"), encoding: .utf8) == "# Limits and Continuity\n## TL;DR\n- x")
            #expect(await waitUntil { controller.notesCharacters == json.count })
            #expect(await waitUntil { abs(controller.cost.notes - 0.044) < 1e-9 })
            let usage = try String(contentsOf: info.folder.appendingPathComponent("usage.md"), encoding: .utf8)
            #expect(usage.contains("Notes: $0.044"))
            #expect(usage.contains("Total: $0.044"))
        }

        @Test func invalidJSONLeavesNoNotesFile() async throws {
            HTTPStub.reset([(200, sseJSON(#"{"title":"Lim"#))])
            let info = try done(try await finishSession())
            #expect(!info.notesWritten)
            #expect(!info.needsSettings)
            #expect(!FileManager.default.fileExists(atPath: info.folder.appendingPathComponent("notes.md").path))
            #expect(info.message?.contains("Generate notes") == true)
        }

        @Test func rejectedKeyAsksForSettings() async throws {
            HTTPStub.reset([(401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)])
            let info = try done(try await finishSession())
            #expect(!info.notesWritten)
            #expect(info.needsSettings)
            #expect(info.message == "API key rejected. Check it in Settings, then Generate notes.")
        }

        @Test func missingKeyAsksForSettingsWithoutRequest() async throws {
            HTTPStub.reset([])
            let info = try done(try await finishSession(key: nil))
            #expect(!info.notesWritten)
            #expect(info.needsSettings)
            #expect(info.message == "Add your API key in Settings to generate notes")
            #expect(HTTPStub.requestCount == 0)
        }
    }
}

@Test func usageSummaryFormatsCosts() {
    var cost = SessionCost()
    cost.add(.question, UsageReport(model: "claude-opus-5-5", tokens: TokenUsage(input: 100, cacheRead: 2000, output: 50), cost: 0.0018))
    cost.add(.question, UsageReport(model: "claude-opus-5-5", tokens: TokenUsage(input: 100, output: 50), cost: 0.0014))
    cost.add(.notes, UsageReport(model: "claude-opus-5-5", tokens: TokenUsage(input: 1000, output: 2000), cost: 0.044))
    #expect(cost.questionCount == 2)
    #expect(abs(cost.total - 0.0472) < 1e-9)
    let text = cost.markdown
    #expect(text.contains("Questions (2): $0.003"))
    #expect(text.contains("Notes: $0.044"))
    #expect(text.contains("Total: $0.047"))
    #expect(text.contains("2,000 cache read"))
}
