import AVFoundation
import ScreenCaptureKit
import TranscriptCore

/// Captures everything the Mac plays (except this app) with ScreenCaptureKit.
///
/// The first `start()` makes macOS ask for Screen Recording permission. Video is
/// configured as small and slow as allowed, since only the audio is used.
public final class SystemAudioSource: NSObject, AudioSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "VoiceTranscriber.SystemAudioSource")
    private var stream: SCStream?
    private var converter: PCMConverter?
    private var converterFormat: AVAudioFormat?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var nextSample: Int64 = 0

    public override init() {}

    public func start() async throws -> AsyncStream<AudioChunk> {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw AudioCaptureError.conversionFailed("no display to capture")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let (chunks, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        lock.withLock {
            self.stream = stream
            self.continuation = continuation
            nextSample = 0
        }
        do {
            try await stream.startCapture()
        } catch {
            lock.withLock {
                self.stream = nil
                self.continuation = nil
            }
            continuation.finish()
            throw error
        }
        return chunks
    }

    public func stop() async {
        let stream = lock.withLock { self.stream }
        try? await stream?.stopCapture()
        finish()
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0,
              let pcm = try? AVAudioPCMBuffer.from(sampleBuffer)
        else { return }
        lock.withLock {
            guard let continuation else { return }
            if converterFormat != pcm.format {
                converter = try? PCMConverter(from: pcm.format)
                converterFormat = pcm.format
            }
            guard let samples = try? converter?.convert(pcm), !samples.isEmpty else { return }
            continuation.yield(AudioChunk(samples: samples, startSample: nextSample))
            nextSample += Int64(samples.count)
        }
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        finish()
    }

    // MARK: - Private

    private func finish() {
        lock.withLock {
            stream = nil
            converter = nil
            converterFormat = nil
            continuation?.finish()
            continuation = nil
        }
    }
}
