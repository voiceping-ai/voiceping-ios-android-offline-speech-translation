import Foundation
import FluidAudio

/// ASREngine implementation for FluidAudio (Parakeet-TDT, CoreML).
@MainActor
final class FluidAudioEngine: ASREngine {
    var isStreaming: Bool { false }
    private(set) var modelState: ASRModelState = .unloaded
    private(set) var downloadProgress: Double = 0.0
    var audioSamples: [Float] { recorder.audioSamples }
    var relativeEnergy: [Float] { recorder.relativeEnergy }

    private var asrManager: AsrManager?
    private let recorder = AudioRecorder()
    private var segmentIdCounter: Int = 0

    private static let downloadedKey = "fluidAudio_downloaded_v3"

    // MARK: - ASREngine

    func setupModel(_ model: ModelInfo) async throws {
        modelState = .downloading
        downloadProgress = 0.5 // FluidAudio manages its own download; show indeterminate progress

        do {
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            modelState = .downloaded
            downloadProgress = 1.0
            UserDefaults.standard.set(true, forKey: Self.downloadedKey)

            modelState = .loading
            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)
            self.asrManager = manager
            modelState = .loaded
        } catch {
            modelState = .error
            throw AppError.modelLoadFailed(underlying: error)
        }
    }

    func loadModel(_ model: ModelInfo) async throws {
        try await setupModel(model)
    }

    func isModelDownloaded(_ model: ModelInfo) -> Bool {
        UserDefaults.standard.bool(forKey: Self.downloadedKey)
    }

    func unloadModel() async {
        recorder.stopRecording()
        asrManager = nil
        modelState = .unloaded
    }

    func startRecording() async throws {
        try await recorder.startRecording()
    }

    func stopRecording() {
        recorder.stopRecording()
    }

    func transcribe(audioArray: [Float], options: ASRTranscriptionOptions) async throws -> ASRResult {
        guard let asrManager else {
            throw AppError.modelNotReady
        }

        let result = try await asrManager.transcribe(audioArray, source: .system)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            return ASRResult(text: "", segments: [], language: nil)
        }

        let duration = Float(audioArray.count) / 16000.0
        let segId = segmentIdCounter
        segmentIdCounter += 1
        let segment = ASRSegment(
            id: segId,
            text: " " + text,
            start: 0,
            end: duration
        )

        return ASRResult(
            text: text,
            segments: [segment],
            language: options.language
        )
    }
}
