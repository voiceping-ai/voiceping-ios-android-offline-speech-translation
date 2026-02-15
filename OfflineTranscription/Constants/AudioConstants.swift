import Foundation

/// Audio-related constants shared across AudioRecorder, SystemAudioSource, and WhisperService.
enum AudioConstants {
    /// Standard sample rate for all ASR engines (16 kHz mono).
    static let sampleRate: Double = 16000
    static let sampleRateFloat: Float = 16000

    /// AVAudioEngine tap buffer size.
    static let bufferSize: UInt32 = 4096

    /// Cap audioSamples to prevent unbounded memory growth during long recordings.
    /// 16000 samples/sec x 1800 sec = 28.8M samples ~ 30 minutes (~115 MB max).
    static let maxAudioSamples = 28_800_000

    /// Cap energy array to prevent unbounded memory growth.
    /// ~100 frames/sec x 600 sec = 60k frames ~ 10 minutes of visualization data.
    static let maxEnergyFrames = 60_000

    // MARK: - dBFS Normalization

    /// dBFS logarithmic scale factor: 20 * log10(rms).
    static let dbfsScaleFactor: Float = 20
    /// Minimum value to prevent log10(0).
    static let dbfsFloor: Float = 1e-10
    /// Minimum dBFS value (silence floor).
    static let dbfsMin: Float = -60
    /// dBFS range used to normalize energy to 0-1.
    static let dbfsRange: Float = 60

    /// Compute RMS energy of samples and normalize to 0–1 on a dBFS scale.
    static func normalizedEnergy(of samples: [Float]) -> Float {
        let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = sqrt(sumSquares / Float(samples.count))
        let dbFS = dbfsScaleFactor * log10(max(rms, dbfsFloor))
        return max(0, min(1, (dbFS - dbfsMin) / dbfsRange))
    }
}
