import Foundation
import TranscriptCore
import WhisperKit

/// On-device Whisper via WhisperKit, English only.
///
/// The model is downloaded once to `~/Library/Application Support/VoiceTranscriber/Models`.
/// Live and file transcription must not run at the same time (the session never does).
public final class WhisperKitTranscriber: Transcriber, @unchecked Sendable {
    /// OpenAI's large-v3-turbo; WhisperKit names it by its release date.
    public static let defaultModel = "large-v3-v20240930"

    private let model: String
    private let downloadBase: URL
    private let lock = NSLock()
    private var whisper: WhisperKit?

    public init(model: String = WhisperKitTranscriber.defaultModel, downloadBase: URL? = nil) {
        self.model = model
        self.downloadBase = downloadBase ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceTranscriber/Models", isDirectory: true)
    }

    public var isLoaded: Bool { lock.withLock { whisper != nil } }

    public func load(progress: @escaping @Sendable (Double) -> Void) async throws {
        if isLoaded {
            progress(1)
            return
        }
        try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
        // Download is most of the first-run wait; compiling and loading the model is the rest.
        let folder = try await WhisperKit.download(variant: model, downloadBase: downloadBase) { p in
            progress(p.fractionCompleted * 0.9)
        }
        let config = WhisperKitConfig(
            model: model,
            downloadBase: downloadBase,
            modelFolder: folder.path,
            verbose: false,
            logLevel: .error,
            load: true,
            download: false
        )
        let whisper = try await WhisperKit(config)
        lock.withLock { self.whisper = whisper }
        progress(1)
    }

    public func transcribe(_ audio: AsyncStream<TranscriptCore.AudioChunk>) -> AsyncStream<TranscriptEvent> {
        LiveTranscription.run(audio) { [self] samples in
            try await decode(samples)
        }
    }

    public func transcribeFile(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [Segment] {
        let whisper = try loaded()
        var options = Self.decodingOptions
        options.chunkingStrategy = .vad
        let fileProgress = whisper.progress
        let results = try await whisper.transcribe(audioPath: url.path, decodeOptions: options) { _ in
            progress(fileProgress.fractionCompleted)
            return nil
        }
        progress(1)
        return Self.segments(from: results)
    }

    // MARK: - Private

    private static var decodingOptions: DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: "en",
            temperatureFallbackCount: 5,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: false
        )
    }

    /// Live decoding needs word timestamps for word-level agreement. Live windows also
    /// usually start mid-sentence, where the first token is unlikely by nature; WhisperKit's
    /// first-token check then rejects good text, retries up to temperature 1.0 (slow) and
    /// returns nothing, so that check is off.
    private static var liveDecodingOptions: DecodingOptions {
        var options = decodingOptions
        options.wordTimestamps = true
        options.firstTokenLogProbThreshold = nil
        return options
    }

    private func loaded() throws -> WhisperKit {
        guard let whisper = lock.withLock({ whisper }) else { throw TranscriberError.notLoaded }
        return whisper
    }

    private func decode(_ samples: [Float]) async throws -> [Word] {
        let whisper = try loaded()
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: Self.liveDecodingOptions)
        return results
            .flatMap(\.segments)
            .flatMap { $0.words ?? [] }
            .map { Word(start: Double($0.start), end: Double($0.end), text: $0.word) }
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.start < $1.start }
    }

    private static func segments(from results: [TranscriptionResult]) -> [Segment] {
        results
            .flatMap(\.segments)
            .map { Segment(start: Double($0.start), end: Double($0.end), text: $0.text.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.text.isEmpty }
            .sorted { $0.start < $1.start }
    }
}
