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

private func sseJSON(_ json: String) -> String {
    let event: [String: Any] = ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": json]]
    let data = try! JSONSerialization.data(withJSONObject: event)
    return "data: \(String(decoding: data, as: UTF8.self))\n\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n"
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
