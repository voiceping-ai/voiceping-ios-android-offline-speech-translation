import Foundation

// MARK: - ASR Segment

/// A segment of transcribed speech with timing info.
/// Replaces WhisperKit's `TranscriptionSegment` as the app's universal type.
struct ASRSegment: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
    let start: Float  // seconds
    let end: Float    // seconds
}

// MARK: - ASR Result

/// The result of a single transcription pass.
/// Replaces WhisperKit's `TranscriptionResult`.
struct ASRResult: Sendable {
    let text: String
    let segments: [ASRSegment]
    let language: String?
}

// MARK: - ASR Model State

/// Lifecycle state for an ASR model. Replaces WhisperKit's `ModelState`.
enum ASRModelState: String, Equatable, Sendable {
    case unloaded
    case downloading
    case downloaded
    case loading
    case loaded
    case error
}

// MARK: - Audio Capture Mode

/// Where audio input comes from for transcription.
enum AudioCaptureMode: String, Sendable {
    case microphone      // Default — voice recording via mic
    case systemBroadcast // ReplayKit Broadcast Extension (digital system audio)
}

// MARK: - ASR Engine Type

/// Which runtime backend a model uses.
enum ASREngineType: String, Codable, Sendable {
    case sherpaOnnxOffline
    case appleSpeech
}

// MARK: - Model Family

enum ModelFamily: String, Codable, Sendable, Hashable {
    case senseVoice
    case parakeet
    case appleSpeech

    var displayName: String {
        switch self {
        case .senseVoice: "SenseVoice"
        case .parakeet: "Parakeet"
        case .appleSpeech: "Apple Speech"
        }
    }
}

// MARK: - ASR Engine Protocol

/// Abstraction over different ASR backends.
@MainActor
protocol ASREngine: AnyObject {
    /// Whether this engine uses streaming (incremental) transcription.
    var isStreaming: Bool { get }

    /// Current model state.
    var modelState: ASRModelState { get }

    /// Download progress (0.0–1.0).
    var downloadProgress: Double { get }

    /// Human-readable status during model loading.
    var loadingStatusMessage: String { get }

    /// Set up (download + load) the model.
    func setupModel(_ model: ModelInfo) async throws

    /// Load a previously downloaded model.
    func loadModel(_ model: ModelInfo) async throws

    /// Check if a model's files are already downloaded.
    func isModelDownloaded(_ model: ModelInfo) -> Bool

    /// Unload the current model and free resources.
    func unloadModel() async

    // MARK: - Recording

    /// Start live audio recording with the specified capture mode.
    func startRecording(captureMode: AudioCaptureMode) async throws

    /// Stop recording.
    func stopRecording()

    /// Current audio samples buffer.
    var audioSamples: [Float] { get }

    /// Relative energy levels for visualization.
    var relativeEnergy: [Float] { get }

    // MARK: - Offline Transcription

    /// Transcribe a slice of the audio buffer (offline engines).
    func transcribe(audioArray: [Float], options: ASRTranscriptionOptions) async throws -> ASRResult
}

// MARK: - ASR Transcription Options

struct ASRTranscriptionOptions: Sendable {
    var language: String?
    var withTimestamps: Bool = true
    var temperature: Float = 0.0
    var task: ASRTask = .transcribe
}

enum ASRTask: Sendable {
    case transcribe
    case translate
}

// MARK: - Default implementations

extension ASREngine {
    var loadingStatusMessage: String { "" }

    // Backward compatibility: default to microphone mode
    func startRecording() async throws {
        try await startRecording(captureMode: .microphone)
    }
}
