import Foundation
import TranscriptCore

/// The live decode loop, kept apart from WhisperKit so it can be tested with a fake decoder.
///
/// About every second of new audio it decodes the unconfirmed part of the buffer (at most
/// 30 s, taken from the front so audio is never skipped), confirms the words two decodes
/// agree on, groups confirmed words into lines, and trims the buffer past them.
enum LiveTranscription {
    /// Decodes 16 kHz samples into words; times are relative to the first sample.
    typealias Decode = @Sendable ([Float]) async throws -> [Word]

    static let decodeInterval = Int(sampleRate)            // 1 s
    static let maxWindow = Int(30 * sampleRate)            // 30 s
    static let stallLimit = Int(25 * sampleRate)           // 25 s
    static let silenceKeep = Int(0.5 * sampleRate)         // context kept when skipping silence
    /// Audio kept before the last confirmed word, so a word whose timestamp is a little
    /// early is not cut off; words decoded again from it are dropped by `WordConfirmer`.
    static let contextKeep: TimeInterval = 0.5
    static let levelFrame = Int(sampleRate / 10)           // 0.1 s energy frames

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
        var bufferStart: Int64 = 0      // sample index of buffer[0], counted from the first chunk
        var confirmer = WordConfirmer()
        var lines = LineBuilder()
        var levels = EnergyHistory(frame: levelFrame)
        let filter = HallucinationFilter()
        var partial = ""
        var ended = false

        func emit(_ segments: [Segment]) {
            for line in segments where !filter.shouldDrop(line, rmsEnergy: levels.rms(from: line.start, to: line.end)) {
                output.yield(.final(line))
            }
        }

        func updatePartial() {
            let text = ([lines.openText] + confirmer.pending.map { $0.text.trimmingCharacters(in: .whitespaces) })
                .filter { !$0.isEmpty }
                .joined(separator: " ")
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
                buffer += taken.samples
                levels.append(taken.samples)
                ended = taken.ended
            }
            if buffer.isEmpty {
                if ended { break }
                continue
            }

            // Skip silence while nothing is pending, keeping a little context for the next
            // word. A pause also ends the open line.
            if !ended, confirmer.pending.isEmpty,
               AudioLevel.rms(Array(buffer.suffix(decodeInterval))) < HallucinationFilter.speechThreshold {
                emit(lines.finish().map { [$0] } ?? [])
                updatePartial()
                let drop = max(0, buffer.count - silenceKeep)
                buffer.removeFirst(drop)
                bufferStart += Int64(drop)
                continue
            }

            let windowCount = min(buffer.count, maxWindow)
            let capped = buffer.count > windowCount
            let offset = Double(bufferStart) / sampleRate
            var decoded = ((try? await decode(Array(buffer.prefix(windowCount)))) ?? [])
                .map { Word(start: $0.start + offset, end: $0.end + offset, text: $0.text) }
                .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            // The last word of a capped window may be cut off; it is decoded again from
            // the next window instead.
            if capped, decoded.count > 1 {
                decoded.removeLast()
            }

            let before = confirmer.confirmedEnd
            var confirmed = confirmer.ingest(decoded)
            let unconfirmed = buffer.count - clamp(Int((confirmer.confirmedEnd * sampleRate).rounded()) - Int(bufferStart), buffer.count)
            let stalled = unconfirmed > stallLimit
            if stalled {
                // Decodes keep disagreeing; take this one as it is rather than let the
                // buffer outgrow the window.
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
            emit(lines.add(confirmed))

            if confirmed.isEmpty, ended || stalled {
                // Whisper found no new speech in this window (music, noise): move past it
                // so the buffer can't grow without bound and the loop always finishes.
                // Keep the last second while live in case a word is just starting.
                trim(to: offset + Double(windowCount) / sampleRate - (ended ? 0 : 1))
            } else {
                trim(to: confirmer.confirmedEnd - contextKeep)
            }
            updatePartial()

            if ended, !progressed, !capped {
                break
            }
        }
        emit(lines.finish().map { [$0] } ?? [])
        if !partial.isEmpty {
            output.yield(.partial(""))
        }
    }

    private static func clamp(_ value: Int, _ upper: Int) -> Int {
        min(max(value, 0), upper)
    }
}

/// RMS energy per short frame for the whole session, so the hallucination filter can
/// measure a line's loudness after its audio has been trimmed from the buffer.
private struct EnergyHistory {
    let frame: Int
    private var frames: [Float] = []
    private var tail: [Float] = []

    init(frame: Int) {
        self.frame = frame
    }

    mutating func append(_ samples: [Float]) {
        tail += samples
        while tail.count >= frame {
            frames.append(AudioLevel.rms(Array(tail.prefix(frame))))
            tail.removeFirst(frame)
        }
    }

    func rms(from start: TimeInterval, to end: TimeInterval) -> Float {
        let perSecond = sampleRate / Double(frame)
        let lower = max(0, min(frames.count, Int(start * perSecond)))
        let upper = max(lower, min(frames.count, Int((end * perSecond).rounded(.up))))
        guard upper > lower else { return 0 }
        let meanSquare = frames[lower..<upper].reduce(Float(0)) { $0 + $1 * $1 } / Float(upper - lower)
        return meanSquare.squareRoot()
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
