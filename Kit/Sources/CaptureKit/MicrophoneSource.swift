import AVFoundation
import TranscriptCore

/// Captures the default input device with `AVAudioEngine`.
///
/// When the device or its format changes (headphones plugged in, AirPods connect),
/// the engine posts a configuration change; the tap is reinstalled with a new converter
/// and the sample counter continues, so timestamps stay continuous.
public final class MicrophoneSource: AudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var converter: PCMConverter?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var observer: NSObjectProtocol?
    private var nextSample: Int64 = 0

    public init() {}

    public func start() async throws -> AsyncStream<AudioChunk> {
        try await Self.requestPermission()

        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        let engine = AVAudioEngine()
        try lock.withLock {
            self.engine = engine
            self.continuation = continuation
            nextSample = 0
            try installTapAndStart(engine)
        }
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.restart()
        }
        lock.withLock { self.observer = observer }
        return stream
    }

    public func stop() async {
        let (engine, observer) = lock.withLock {
            let taken = (self.engine, self.observer)
            self.engine = nil
            self.observer = nil
            converter = nil
            continuation?.finish()
            continuation = nil
            return taken
        }
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        // Outside the lock: removeTap waits for a running tap callback, which takes the lock.
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
    }

    // MARK: - Private

    private static func requestPermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
            throw AudioCaptureError.permissionDenied
        default:
            throw AudioCaptureError.permissionDenied
        }
    }

    /// Call with `lock` held.
    private func installTapAndStart(_ engine: AVAudioEngine) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.unsupportedFormat
        }
        converter = try PCMConverter(from: format)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard let converter, let continuation,
                  let samples = try? converter.convert(buffer), !samples.isEmpty
            else { return }
            continuation.yield(AudioChunk(samples: samples, startSample: nextSample))
            nextSample += Int64(samples.count)
        }
    }

    private func restart() {
        guard let engine = lock.withLock({ self.engine }) else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock {
            // Stopped in the meantime.
            guard self.engine === engine else { return }
            // If the new device can't start (e.g. unplugged with no fallback), the stream
            // stays open and silent; the no-audio banner covers that case.
            try? installTapAndStart(engine)
        }
    }
}
