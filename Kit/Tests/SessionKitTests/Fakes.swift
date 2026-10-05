import AVFoundation
import Testing
import CaptureKit
import Foundation
import SessionKit
import TranscriptCore

/// Yields scripted chunks as soon as it starts, more on `push`, and finishes on `stop`.
final class FakeSource: AudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private let initial: [AudioChunk]
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var nextSample: Int64 = 0

    init(seconds: Double = 2, amplitude: Float = 0.5) {
        initial = FakeSource.chunks(seconds: seconds, amplitude: amplitude, from: 0)
        nextSample = Int64(seconds * sampleRate)
    }

    func start() async throws -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        lock.withLock { self.continuation = continuation }
        initial.forEach { continuation.yield($0) }
        return stream
    }

    func push(seconds: Double, amplitude: Float) {
        lock.withLock {
            Self.chunks(seconds: seconds, amplitude: amplitude, from: nextSample).forEach { continuation?.yield($0) }
            nextSample += Int64(seconds * sampleRate)
        }
    }

    func stop() async {
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
    }

    /// 0.5 s chunks of a 440 Hz sine (or silence when `amplitude` is 0).
    static func chunks(seconds: Double, amplitude: Float, from start: Int64) -> [AudioChunk] {
        let size = Int(sampleRate / 2)
        let total = Int(seconds * sampleRate)
        return stride(from: 0, to: total, by: size).map { offset in
            let samples = (0..<min(size, total - offset)).map { i in
                amplitude * Float(sin(2 * .pi * 440 * Double(Int(start) + offset + i) / sampleRate))
            }
            return AudioChunk(samples: samples, startSample: start + Int64(offset))
        }
    }
}

struct FakeSourceFailure: Error {}

final class FailingSource: AudioSource {
    func start() async throws -> AsyncStream<AudioChunk> { throw FakeSourceFailure() }
    func stop() async {}
}

/// Emits scripted live events, then finishes when the audio ends. The file pass returns
/// scripted segments, throws, or (with `fileHangs`) waits until cancelled.
final class FakeTranscriber: Transcriber, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    let liveEvents: [TranscriptEvent]
    let fileResult: Result<[Segment], Error>
    let fileHangs: Bool
    private var _fileCalls = 0

    init(live: [TranscriptEvent] = [], file: Result<[Segment], Error> = .success([]), fileHangs: Bool = false) {
        liveEvents = live
        fileResult = file
        self.fileHangs = fileHangs
    }

    var fileCalls: Int { lock.withLock { _fileCalls } }

    func load(progress: @escaping @Sendable (Double) -> Void) async throws {}

    private var _received: [AudioChunk] = []
    /// Every chunk the live pass was given.
    var received: [AudioChunk] { lock.withLock { _received } }

    func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptEvent> {
        let events = liveEvents
        return AsyncStream { continuation in
            Task {
                events.forEach { continuation.yield($0) }
                for await chunk in audio {
                    self.lock.withLock { self._received.append(chunk) }
                }
                continuation.finish()
            }
        }
    }

    func transcribeFile(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [Segment] {
        lock.withLock { _fileCalls += 1 }
        progress(0.5)
        if fileHangs {
            try await Task.sleep(for: .seconds(60))
        }
        return try fileResult.get()
    }
}

actor FakeNotes: NotesMaking {
    struct Failure: Error {}

    private let result: Result<(String, String), Error>
    private(set) var calls: [[Segment]] = []

    init(title: String = "Derivatives Intro", markdown: String = "# Derivatives Intro\n") {
        result = .success((title, markdown))
    }

    init(failing: Void) {
        result = .failure(Failure())
    }

    func makeNotes(transcript: [Segment], progress: @escaping @Sendable (Int) -> Void) async throws -> (title: String, markdown: String) {
        calls.append(transcript)
        progress(10)
        let (title, markdown) = try result.get()
        return (title, markdown)
    }
}

func makeTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SessionKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Polls until `condition` holds or the timeout passes.
@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// Scripted HTTP replies for the Claude client, shared by the ask tests (run serialized).
final class HTTPStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [(Int, String)] = []
    nonisolated(unsafe) private static var count = 0

    static func reset(_ replies: [(Int, String)]) {
        lock.withLock {
            self.replies = replies
            count = 0
        }
    }

    static var requestCount: Int { lock.withLock { count } }

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.lock.withLock {
            Self.count += 1
            return Self.replies.isEmpty ? (500, "{}") : Self.replies.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func sse(_ text: String, stop: String = "end_turn") -> String {
        """
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\(text)"}}

        data: {"type":"message_delta","delta":{"stop_reason":"\(stop)"}}

        """
    }
}

/// Suites that use `HTTPStub` share its static state, so they are nested here and run one
/// at a time.
@Suite(.serialized)
struct StubbedNetworkTests {}

struct FakePermissions: PermissionChecking {
    var microphoneStatus: PermissionStatus = .granted
    var screenStatus: PermissionStatus = .granted
    var grantOnRequest = false

    func microphone() async -> PermissionStatus { microphoneStatus }
    func screenRecording() async -> PermissionStatus { screenStatus }
    func request(_ kind: AudioSourceKind) async -> Bool { grantOnRequest }
}
