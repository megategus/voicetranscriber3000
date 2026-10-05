import Foundation
import Testing
import TranscriptCore
@testable import AssistantKit

private func store(_ starts: [Double]) async -> TranscriptStore {
    let store = TranscriptStore()
    for start in starts {
        await store.append(Segment(start: start, end: start + 3, text: "at \(Int(start))"))
    }
    return store
}

private let keyedClient = ClaudeClient(apiKey: { "test-key" }, session: StubProtocol.session, retryDelays: [.zero, .zero])

private func transcriptBlocks(_ request: MessagesRequest) -> [TextBlock] {
    Array(request.messages[0].content.dropLast())
}

extension StubbedNetworkTests {
    @Suite
    struct AssistantAskTests {
        @Test func askRequestPutsCacheOnLastCompletedBlock() async throws {
            let assistant = Assistant(client: keyedClient, store: await store([10, 290, 310, 650]))
            let request = await assistant.buildAskRequest(question: "What is a derivative?", now: 700)

            #expect(request.messages.count == 1)
            #expect(request.messages[0].role == "user")
            let content = request.messages[0].content
            #expect(content.count == 4)
            #expect(content[0].text.contains("[00:10] at 10") && content[0].text.contains("[04:50] at 290"))
            #expect(content[1].text.contains("[05:10] at 310"))
            #expect(content[2].text.contains("[10:50] at 650"))
            #expect(content[3].text.contains("What is a derivative?"))
            #expect(content.map(\.cached) == [false, true, false, false])
            #expect(content[0].text.hasPrefix("<transcript_part>") && content[0].text.hasSuffix("</transcript_part>"))
            #expect(request.system == [TextBlock(text: Prompts.askSystem, cached: true, ttl: .oneHour)])
            #expect(request.effort == "low")
            #expect(request.maxTokens == 4000)
            #expect(request.jsonSchema == nil)
        }

        @Test func askRequestSkipsEmptyBlocks() async throws {
            let assistant = Assistant(client: keyedClient, store: await store([10, 650]))
            let content = await assistant.buildAskRequest(question: "Q", now: 700).messages[0].content
            #expect(content.count == 3)
            #expect(content.map(\.cached) == [true, false, false])
            #expect(content[0].text.contains("at 10"))
            #expect(content[1].text.contains("at 650"))
        }

        @Test func askRequestWithNoCompletedBlocks() async throws {
            let assistant = Assistant(client: keyedClient, store: await store([10, 200]))
            let request = await assistant.buildAskRequest(question: "Q", now: 250)
            // No 5-minute block is complete; the current part is split by minute and the
            // finished minute (0) gets the breakpoint.
            let blocks = transcriptBlocks(request)
            #expect(blocks.count == 2)
            #expect(blocks.map(\.cached) == [true, false])
            #expect(blocks[0].text.contains("at 10") && blocks[1].text.contains("at 200"))
            #expect(request.system.first?.cached == true)
        }

        @Test func currentPartIsSplitByMinute() async throws {
            let assistant = Assistant(client: keyedClient, store: await store([10, 290, 310, 330, 400, 650]))
            let blocks = transcriptBlocks(await assistant.buildAskRequest(question: "Q", now: 700))
            // [block0] [block1] then the current part (block 2: 600–899 s) has only 650.
            #expect(blocks.count == 3)
            #expect(blocks.map(\.cached) == [false, true, false])

            let early = Assistant(client: keyedClient, store: await store([310, 330, 400, 470]))
            let parts = transcriptBlocks(await early.buildAskRequest(question: "Q", now: 480))
            // Minutes 5, 6 complete (a later line exists); minute 7 is still growing.
            #expect(parts.map { $0.text.contains("at 470") } == [false, false, true])
            #expect(parts.map(\.cached) == [false, true, false])
        }

        @Test func askBreakpointsUseOneHourCacheAndStayWithinLimit() async throws {
            let assistant = Assistant(client: keyedClient, store: await store([10, 290, 310, 330, 400, 650, 700, 760]))
            let request = await assistant.buildAskRequest(question: "Q", now: 800)
            let marked = (request.system + request.messages[0].content).filter(\.cached)
            #expect(marked.count <= 4)
            #expect(marked.allSatisfy { $0.ttl == .oneHour })
        }

        @Test func configurationChoosesModelAndNotesEffort() async throws {
            let assistant = Assistant(client: keyedClient, store: await store([10]))
            assistant.configuration = .init(model: .sonnet55, notesEffort: "medium")
            #expect(await assistant.buildAskRequest(question: "Q", now: 20).model == "claude-sonnet-5-5")
            let notes = assistant.buildNotesRequest(transcript: [Segment(start: 1, end: 2, text: "x")])
            #expect(notes.model == "claude-sonnet-5-5")
            #expect(notes.effort == "medium")
        }

        @Test func askRequestNeverSendsEmptyText() async throws {
            for (starts, now) in [([10.0, 650], 700.0), ([10, 620, 1300], 1400), ([5], 3600)] {
                let assistant = Assistant(client: keyedClient, store: await store(starts))
                let request = await assistant.buildAskRequest(question: "Q", now: now)
                #expect(request.messages[0].content.allSatisfy { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
        }

        /// Completed blocks must be byte-identical between questions, or the cache misses.
        @Test func completedBlocksStayIdenticalBetweenQuestions() async throws {
            let store = await store([10, 290, 310])
            let assistant = Assistant(client: keyedClient, store: store)
            let first = await assistant.buildAskRequest(question: "One", now: 620)
            await store.append(Segment(start: 640, end: 643, text: "later"))
            let second = await assistant.buildAskRequest(question: "Two", now: 660)
            #expect(first.messages[0].content[0].text == second.messages[0].content[0].text)
        }

        @Test func askWithEmptyTranscriptDoesNotCallAPI() async throws {
            StubProtocol.reset([])
            let assistant = Assistant(client: keyedClient, store: TranscriptStore())
            await #expect(throws: AskError.nothingYet) { _ = try await assistant.ask("Anything?", now: 10) }
            #expect(StubProtocol.requests.isEmpty)
        }

        @Test func askWithoutKeyReturnsMissingKey() async throws {
            StubProtocol.reset([])
            let noKey = ClaudeClient(apiKey: { nil }, session: StubProtocol.session)
            let assistant = Assistant(client: noKey, store: await store([10]))
            await #expect(throws: AskError.missingKey) { _ = try await assistant.ask("Anything?", now: 20) }
            #expect(StubProtocol.requests.isEmpty)
        }

        @Test func askStreamsTheAnswer() async throws {
            StubProtocol.reset([.init(status: 200, body: try fixture("text"))])
            let assistant = Assistant(client: keyedClient, store: await store([10]))
            var answer = ""
            for try await delta in try await assistant.ask("Say hello", now: 20) {
                answer += delta
            }
            #expect(answer == "Hello world")
            let body = try #require(StubProtocol.requests.first.flatMap { $0.httpBodyStreamData ?? $0.httpBody })
            #expect(String(decoding: body, as: UTF8.self).contains("Say hello"))
        }

        @Test func quickActionsBuildExpectedQuestions() {
            let assistant = Assistant(client: keyedClient, store: TranscriptStore())
            #expect(assistant.question(for: .summarizeLast5, now: 900).contains("from [10:00]"))
            #expect(assistant.question(for: .summarizeLast5, now: 100).contains("from [00:00]"))
            #expect(assistant.question(for: .whatDidIMiss(since: 120), now: 900).contains("since [02:00]"))
            #expect(assistant.question(for: .whatDidIMiss(since: nil), now: 900).contains("since [10:00]"))
            #expect(assistant.question(for: .explainLastTerm, now: 900).localizedCaseInsensitiveContains("term"))
        }

        @Test func askSystemPromptCoversTheRules() {
            let prompt = Prompts.askSystem
            for phrase in ["[mm:ss]", "(background)", "transcript_part", "machine-generated"] {
                #expect(prompt.contains(phrase), "\(phrase)")
            }
        }
    }
}

extension URLRequest {
    /// URLProtocol receives POST bodies as a stream; read it back for assertions.
    var httpBodyStreamData: Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
