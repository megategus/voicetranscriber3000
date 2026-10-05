import AVFoundation
import TranscriptCore

/// Writes session audio to a crash-safe `.caf` while recording, then converts it to
/// AAC `.m4a` when the session stops.
public actor AudioRecorder {
    private let cafURL: URL
    private var file: AVAudioFile?

    public init(cafURL: URL) throws {
        self.cafURL = cafURL
        file = try AVAudioFile(
            forWriting: cafURL,
            settings: PCMConverter.outputFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    public func write(_ chunk: AudioChunk) throws {
        guard let file, !chunk.samples.isEmpty else { return }
        let count = AVAudioFrameCount(chunk.samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: PCMConverter.outputFormat, frameCapacity: count) else {
            throw AudioCaptureError.conversionFailed("could not allocate buffer")
        }
        buffer.frameLength = count
        chunk.samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: src.count)
        }
        try file.write(from: buffer)
    }

    /// Closes the `.caf`, exports `m4aURL`, and deletes the `.caf` only if the export
    /// succeeded. Further writes are ignored.
    public func finish(m4aURL: URL) async throws {
        // Releasing the AVAudioFile closes it (AVAudioFile.close() needs macOS 15).
        file = nil
        try await Self.exportM4A(from: cafURL, to: m4aURL)
        try FileManager.default.removeItem(at: cafURL)
    }

    /// Converts any audio file to AAC `.m4a`. Also used to finish recovered sessions.
    public static func exportM4A(from source: URL, to destination: URL) async throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioCaptureError.conversionFailed("could not create export session")
        }
        if #available(macOS 15, *) {
            try await session.export(to: destination, as: .m4a)
        } else {
            session.outputURL = destination
            session.outputFileType = .m4a
            nonisolated(unsafe) let session = session
            await session.export()
            if session.status != .completed {
                throw session.error ?? AudioCaptureError.conversionFailed("export ended with status \(session.status.rawValue)")
            }
        }
    }
}
