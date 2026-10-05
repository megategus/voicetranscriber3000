import Accelerate

public enum AudioLevel {
    /// Root-mean-square energy of the samples; 0 for an empty array.
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_rmsqv(samples, 1, &result, vDSP_Length(samples.count))
        return result
    }
}
