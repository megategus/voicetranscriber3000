import Foundation
import TranscriptCore

/// The live decode loop, kept apart from WhisperKit so it can be tested with a fake decoder.
///
/// About every second of new audio it decodes the unconfirmed part of the buffer (at most
/// 30 s, taken from the front so audio is never skipped), confirms segments that two
/// decodes agree on, and trims the buffer past them.
enum LiveTranscription {
    /// Decodes 16 kHz samples; segment times are relative to the first sample.
    typealias Decode = @Sendable ([Float]) async throws -> [Segment]

    static let decodeInterval = Int(sampleRate)            // 1 s
    static let maxWindow = Int(30 * sampleRate)            // 30 s
    static let stallLimit = Int(25 * sampleRate)           // 25 s
    static let silenceKeep = Int(0.5 * sampleRate)         // context kept when skipping silence

    static func run(
        _ audio: AsyncStream<AudioChunk>,
        decode: @escaping Decode
    ) -> AsyncStream<TranscriptEvent> {
        let (events, output) = AsyncStream<TranscriptEvent>.makeStream(bufferingPolicy: .unbounded)
        let inbox = AudioInbox()
        let feeder = Task {
            for await chunk in audio {
                inbox.append(chunk)
            }
            inbox.finish()
        }
        let worker = Task {
            await loop(inbox: inbox, decode: decode, output: output)
            output.finish()
        }
        output.onTermination = { _ in
            feeder.cancel()
            worker.cancel()
        }
        return events
    }

    private static func loop(
        inbox: AudioInbox,
        decode: Decode,
        output: AsyncStream<TranscriptEvent>.Continuation
    ) async {
        var buffer: [Float] = []
        var bufferStart: Int64 = 0      // session sample index of buffer[0]
        var origin: Int64?              // startSample of the first chunk; times are relative to it
        var confirmer = SegmentConfirmer()
        let filter = HallucinationFilter()
        var partial = ""
        var ended = false

        func emit(_ segments: [Segment]) {
            for segment in segments where !segment.text.trimmingCharacters(in: .whitespaces).isEmpty {
                let from = clamp(Int(segment.start * sampleRate) - Int(bufferStart), buffer.count)
                let to = clamp(Int(segment.end * sampleRate) - Int(bufferStart), buffer.count)
                let energy = AudioLevel.rms(Array(buffer[from..<max(from, to)]))
                if !filter.shouldDrop(segment, rmsEnergy: energy) {
                    output.yield(.final(segment))
                }
            }
        }

        func setPartial(_ text: String) {
            if text != partial {
                partial = text
                output.yield(.partial(text))
            }
        }

        func trim(to time: TimeInterval) {
            let cut = clamp(Int((time * sampleRate).rounded()) - Int(bufferStart), buffer.count)
            buffer.removeFirst(cut)
            bufferStart += Int64(cut)
        }

        while !Task.isCancelled {
            if !ended {
                let taken = await inbox.take(atLeast: decodeInterval)
                if origin == nil, let first = taken.firstSample {
                    origin = first
                    bufferStart = 0
                }
                buffer += taken.samples
                ended = taken.ended
            }
            if buffer.isEmpty {
                if ended { break }
                continue
            }

            // Skip silence while nothing is pending, keeping a little context for the next word.
            if !ended, partial.isEmpty,
               AudioLevel.rms(Array(buffer.suffix(decodeInterval))) < HallucinationFilter.speechThreshold {
                let drop = max(0, buffer.count - silenceKeep)
                buffer.removeFirst(drop)
                bufferStart += Int64(drop)
                continue
            }

            let windowCount = min(buffer.count, maxWindow)
            let capped = buffer.count > windowCount
            let offset = Double(bufferStart) / sampleRate
            var decoded = ((try? await decode(Array(buffer.prefix(windowCount)))) ?? [])
                .map { Segment(start: $0.start + offset, end: $0.end + offset, text: $0.text) }
                .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            // The last segment of a capped window may be cut off mid-word; it is decoded
            // again from the next window instead.
            if capped, decoded.count > 1 {
                decoded.removeLast()
            }

            let before = confirmer.confirmedEnd
            var (confirmed, _) = confirmer.ingest(decoded)
            let unconfirmed = buffer.count - clamp(Int((confirmer.confirmedEnd * sampleRate).rounded()) - Int(bufferStart), buffer.count)
            let stalled = unconfirmed > stallLimit
            if stalled {
                // Decodes keep disagreeing (Whisper re-splits the same speech differently),
                // so take this decode as it is rather than let the buffer outgrow the window.
                confirmed += confirmer.confirmAllButLast()
                if confirmed.isEmpty {
                    confirmed = confirmer.flush()
                }
            }
            let progressed = confirmer.confirmedEnd > before

            if ended, !progressed {
                // Input is over and decoding has settled: everything decoded is final.
                confirmed += confirmer.flush()
            }
            emit(confirmed)

            if confirmed.isEmpty, ended || stalled {
                // Whisper found no new speech in this window (music, noise): move past it
                // so the buffer can't grow without bound and the loop always finishes.
                // Keep the last second while live in case a word is just starting.
                let keep = ended ? 0 : 1.0
                trim(to: offset + Double(windowCount) / sampleRate - keep)
            } else {
                trim(to: confirmer.confirmedEnd)
            }

            let pending = decoded.filter { $0.start >= confirmer.confirmedEnd - 0.1 }
            setPartial(ended && !progressed ? "" : pending.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " "))

            if ended, !progressed, !capped {
                break
            }
        }
        setPartial("")
    }

    private static func clamp(_ value: Int, _ upper: Int) -> Int {
        min(max(value, 0), upper)
    }
}

/// Collects incoming audio and hands it to the decode loop in batches.
private final class AudioInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var firstSample: Int64?
    private var ended = false
    private var wanted = 0
    private var waiter: CheckedContinuation<Void, Never>?

    func append(_ chunk: AudioChunk) {
        lock.withLock {
            if firstSample == nil { firstSample = chunk.startSample }
            samples += chunk.samples
            if samples.count >= wanted { wake() }
        }
    }

    func finish() {
        lock.withLock {
            ended = true
            wake()
        }
    }

    /// Waits until at least `count` samples are queued or the input has ended, then
    /// returns everything queued.
    func take(atLeast count: Int) async -> (samples: [Float], firstSample: Int64?, ended: Bool) {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if samples.count >= count || ended {
                    continuation.resume()
                } else {
                    wanted = count
                    waiter = continuation
                }
            }
        }
        return lock.withLock {
            let taken = samples
            samples = []
            return (taken, firstSample, ended)
        }
    }

    /// Call with `lock` held.
    private func wake() {
        waiter?.resume()
        waiter = nil
    }
}
