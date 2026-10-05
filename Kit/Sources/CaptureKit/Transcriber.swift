import Foundation
import TranscriptCore

/// Speech-to-text for a session: live from a stream of chunks, or from a file after Stop.
public protocol Transcriber: Sendable {
    /// Downloads (first run) and loads the model. `progress` goes from 0 to 1.
    func load(progress: @escaping @Sendable (Double) -> Void) async throws
    /// Live transcription. Times in the events are seconds since the first chunk's
    /// `startSample`. The stream ends after the input ends and the rest is flushed.
    func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptEvent>
    /// Transcribes a whole file (the final pass).
    func transcribeFile(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [Segment]
}

public enum TranscriberError: Error, Equatable {
    case notLoaded
}
