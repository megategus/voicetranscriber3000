import AVFoundation
import TranscriptCore

/// Something that produces 16 kHz mono Float32 audio for a session.
public protocol AudioSource: Sendable {
    /// Starts capturing. Chunks carry a running sample offset that starts at 0.
    func start() async throws -> AsyncStream<AudioChunk>
    /// Stops capturing and finishes the stream.
    func stop() async
}

public enum AudioCaptureError: Error, Equatable {
    case unsupportedFormat
    case conversionFailed(String)
    case permissionDenied
}

/// Converts buffers in any PCM format to 16 kHz mono Float32.
///
/// Keeps resampler state between calls, so consecutive buffers from one stream join
/// without clicks. Create a new converter when the input format changes.
public final class PCMConverter {
    public static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )!

    private let converter: AVAudioConverter
    private let ratio: Double

    public init(from format: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: format, to: Self.outputFormat) else {
            throw AudioCaptureError.unsupportedFormat
        }
        // Without priming the output starts immediately instead of after the
        // resampler's latency, so sample counts stay in step with the input.
        converter.primeMethod = .none
        self.converter = converter
        ratio = sampleRate / format.sampleRate
    }

    public func convert(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else {
            throw AudioCaptureError.conversionFailed("could not allocate output buffer")
        }
        nonisolated(unsafe) var supplied = false
        nonisolated(unsafe) let input = buffer
        var samples: [Float] = []
        samples.reserveCapacity(Int(capacity))
        // The converter pulls input in slices of its own size, so one call may return
        // only part of the buffer. Keep calling until it has nothing more to give.
        while true {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error {
                throw AudioCaptureError.conversionFailed(error?.localizedDescription ?? "unknown")
            }
            guard output.frameLength > 0, let data = output.floatChannelData else { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
            if status != .haveData { break }
        }
        return samples
    }
}
