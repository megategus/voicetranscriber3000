import Foundation
import Testing
@testable import CaptureKit

@Test func rmsOfSilenceIsZero() {
    #expect(AudioLevel.rms([Float](repeating: 0, count: 1600)) == 0)
    #expect(AudioLevel.rms([]) == 0)
}

@Test func rmsOfFullScaleSineIsAbout0_707() {
    let samples = sine(frequency: 440, seconds: 1)
    #expect(abs(AudioLevel.rms(samples) - 0.7071) < 0.01)
}

/// A full-scale sine at 16 kHz.
func sine(frequency: Double, seconds: Double, sampleRate: Double = 16_000) -> [Float] {
    let count = Int(seconds * sampleRate)
    return (0..<count).map { Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
}
