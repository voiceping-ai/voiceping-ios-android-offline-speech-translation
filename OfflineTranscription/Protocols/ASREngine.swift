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

// MARK: - ASR Engine Type

/// Which runtime backend a model uses.
enum ASREngineType: String, Codable, Sendable {
    case whisperKit
    case sherpaOnnxOffline
    case sherpaOnnxStreaming
    case fluidAudio
}

// MARK: - Model Family

enum ModelFamily: String, Codable, Sendable, Hashable {
    case whisper
    case moonshine
    case senseVoice
    case zipformer
    case omnilingual
    case parakeet

    var displayName: String {
        switch self {
        case .whisper: "Whisper"
        case .moonshine: "Moonshine"
        case .senseVoice: "SenseVoice"
        case .zipformer: "Zipformer"
        case .omnilingual: "Omnilingual"
        case .parakeet: "Parakeet"
        }
    }
}

// MARK: - ASR Engine Protocol

/// Abstraction over different ASR backends (WhisperKit, sherpa-onnx offline, sherpa-onnx streaming).
@MainActor
protocol ASREngine: AnyObject {
    /// Whether this engine uses streaming (incremental) transcription.
    var isStreaming: Bool { get }

    /// Current model state.
    var modelState: ASRModelState { get }

    /// Download progress (0.0–1.0).
    var downloadProgress: Double { get }

    /// Set up (download + load) the model.
    func setupModel(_ model: ModelInfo) async throws

    /// Load a previously downloaded model.
    func loadModel(_ model: ModelInfo) async throws

    /// Check if a model's files are already downloaded.
    func isModelDownloaded(_ model: ModelInfo) -> Bool

    /// Unload the current model and free resources.
    func unloadModel() async

    // MARK: - Recording

    /// Start live audio recording.
    func startRecording() async throws

    /// Stop recording.
    func stopRecording()

    /// Current audio samples buffer.
    var audioSamples: [Float] { get }

    /// Relative energy levels for visualization.
    var relativeEnergy: [Float] { get }

    // MARK: - Offline Transcription

    /// Transcribe a slice of the audio buffer (offline engines).
    func transcribe(audioArray: [Float], options: ASRTranscriptionOptions) async throws -> ASRResult

    // MARK: - Streaming Transcription

    /// Feed audio samples to a streaming engine. No-op for offline engines.
    func feedAudio(_ samples: [Float]) throws

    /// Poll the streaming engine for the latest partial result. Returns nil for offline engines.
    func getStreamingResult() -> ASRResult?

    /// Whether the streaming engine detected an endpoint (end of utterance).
    func isEndpointDetected() -> Bool

    /// Reset the streaming decoder state for the next utterance.
    func resetStreamingState()
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
    // Offline engines: streaming methods are no-ops
    func feedAudio(_ samples: [Float]) throws {}
    func getStreamingResult() -> ASRResult? { nil }
    func isEndpointDetected() -> Bool { false }
    func resetStreamingState() {}
}
