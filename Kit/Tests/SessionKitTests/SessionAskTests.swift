import AssistantKit
import CaptureKit
import Foundation
import Testing
import TranscriptCore
@testable import SessionKit

private let line = Segment(start: 1, end: 2, text: "Today we cover derivatives.")

@MainActor
private func recordingController(live: [TranscriptEvent] = [.final(line)], key: String? = "test-key") async throws -> SessionController {
    let controller = SessionController(
        root: try makeTempRoot(),
        transcriber: FakeTranscriber(live: live),
        makeSource: { _ in FakeSource(seconds: 2) },
        notes: nil,
        retranscribe: { false },
        claude: ClaudeClient(apiKey: { key }, session: HTTPStub.session, retryDelays: [.zero, .zero])
    )
    await controller.start(.microphone)
    _ = await waitUntil { controller.elapsed >= 2 && controller.segments.count == live.count }
    return controller
}

@Suite(.serialized) @MainActor
struct SessionAskTests {
    @Test func askStreamsAnswerAndAppendsToQAFile() async throws {
        HTTPStub.reset([(200, HTTPStub.sse("It is about derivatives [00:01]."))])
        let controller = try await recordingController()
        #expect(controller.canAsk)

        await controller.ask("What is the topic?")

        #expect(controller.askQuestion == "What is the topic?")
        #expect(controller.askAnswer == "It is about derivatives [00:01].")
        #expect(controller.askProblem == nil)
        #expect(!controller.isAsking)
        await controller.stop()
        let folder = try #require({ if case .done(let info) = controller.state { return info.folder }; return nil }())
        let qa = try String(contentsOf: folder.appendingPathComponent("qa.md"), encoding: .utf8)
        #expect(qa == "## [00:02] What is the topic?\n\nIt is about derivatives [00:01].\n\n")
    }

    @Test func askBeforeAnyTranscriptShowsNothingYet() async throws {
        HTTPStub.reset([])
        let controller = try await recordingController(live: [])
        await controller.ask("Anything?")
        #expect(controller.askProblem == .nothingYet)
        #expect(HTTPStub.requestCount == 0)
        await controller.stop()
    }

    @Test func askWithoutKeyShowsMissingKey() async throws {
        HTTPStub.reset([])
        let controller = try await recordingController(key: nil)
        await controller.ask("Anything?")
        #expect(controller.askProblem == .missingKey)
        #expect(HTTPStub.requestCount == 0)
        await controller.stop()
    }

    @Test func rejectedKeyShowsUnauthorized() async throws {
        HTTPStub.reset([(401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)])
        let controller = try await recordingController()
        await controller.ask("Anything?")
        #expect(controller.askProblem == .unauthorized)
        await controller.stop()
    }

    @Test func refusalDiscardsPartialAnswerAndSkipsQA() async throws {
        HTTPStub.reset([(200, HTTPStub.sse("Partial", stop: "refusal"))])
        let controller = try await recordingController()
        await controller.ask("Anything?")
        #expect(controller.askProblem == .refused)
        #expect(controller.askAnswer.isEmpty)
        await controller.stop()
        let folder = try #require({ if case .done(let info) = controller.state { return info.folder }; return nil }())
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("qa.md").path))
    }

    @Test func whatDidIMissStartsAtLastQuestion() async throws {
        HTTPStub.reset([(200, HTTPStub.sse("One.")), (200, HTTPStub.sse("Two."))])
        let controller = try await recordingController()
        await controller.ask("First question")            // asked at [00:02]
        await controller.ask(.whatDidIMiss(since: nil))
        #expect(controller.askQuestion.contains("since [00:02]"))
        #expect(controller.askAnswer == "Two.")
        await controller.stop()
    }

    @Test func retryRepeatsLastQuestion() async throws {
        HTTPStub.reset([(400, #"{"type":"error","error":{"type":"invalid_request_error","message":"bad"}}"#), (200, HTTPStub.sse("Fine now."))])
        let controller = try await recordingController()
        await controller.ask("Try me")
        #expect(controller.askProblem == .failed("bad"))
        await controller.retryAsk()
        #expect(controller.askProblem == nil)
        #expect(controller.askQuestion == "Try me")
        #expect(controller.askAnswer == "Fine now.")
        await controller.stop()
    }

    @Test func cannotAskWhenNotRecording() async throws {
        HTTPStub.reset([])
        let controller = try await recordingController()
        await controller.stop()
        #expect(!controller.canAsk)
        await controller.ask("Too late?")
        #expect(HTTPStub.requestCount == 0)
    }
}
