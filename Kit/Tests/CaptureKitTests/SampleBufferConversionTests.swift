import AVFoundation
import CoreMedia
import Testing
@testable import CaptureKit

/// ScreenCaptureKit delivers 48 kHz stereo Float32 non-interleaved audio as CMSampleBuffers.
@Test func pcmBufferFromSampleBufferKeepsFramesAndSamples() throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
    source.frameLength = 1_024
    for i in 0..<1_024 {
        source.floatChannelData![0][i] = Float(i) / 1_024
        source.floatChannelData![1][i] = -Float(i) / 1_024
    }
    let sampleBuffer = try makeSampleBuffer(from: source)

    let pcm = try AVAudioPCMBuffer.from(sampleBuffer)

    #expect(pcm.frameLength == 1_024)
    #expect(pcm.format.sampleRate == 48_000)
    #expect(pcm.format.channelCount == 2)
    #expect(pcm.floatChannelData![0][512] == 0.5)
    #expect(pcm.floatChannelData![1][512] == -0.5)
}

private func makeSampleBuffer(from buffer: AVAudioPCMBuffer) throws -> CMSampleBuffer {
    var asbd = buffer.format.streamDescription.pointee
    var formatDescription: CMAudioFormatDescription?
    #expect(CMAudioFormatDescriptionCreate(
        allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &formatDescription
    ) == noErr)
    let description = try #require(formatDescription)
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: Int32(buffer.format.sampleRate)),
        presentationTimeStamp: .zero,
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    #expect(CMSampleBufferCreate(
        allocator: nil, dataBuffer: nil, dataReady: false,
        makeDataReadyCallback: nil, refcon: nil,
        formatDescription: description,
        sampleCount: CMItemCount(buffer.frameLength),
        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil,
        sampleBufferOut: &sampleBuffer
    ) == noErr)
    let result = try #require(sampleBuffer)
    #expect(CMSampleBufferSetDataBufferFromAudioBufferList(
        result, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
        flags: 0, bufferList: buffer.audioBufferList
    ) == noErr)
    return result
}
