import Foundation
import SherpaOnnxKit

/// ASREngine implementation for sherpa-onnx offline models (Moonshine, SenseVoice).
@MainActor
final class SherpaOnnxOfflineEngine: ASREngine {
    var isStreaming: Bool { false }
    private(set) var modelState: ASRModelState = .unloaded
    private(set) var downloadProgress: Double = 0.0
    var audioSamples: [Float] { recorder.audioSamples }
    var relativeEnergy: [Float] { recorder.relativeEnergy }

    private var recognizer: SherpaOnnxOfflineRecognizer?
    private let recorder = AudioRecorder()
    private let downloader = ModelDownloader()
    private var currentModel: ModelInfo?
    private var segmentIdCounter: Int = 0

    // MARK: - ASREngine

    func setupModel(_ model: ModelInfo) async throws {
        guard model.sherpaModelConfig != nil else {
            throw AppError.modelLoadFailed(underlying: NSError(
                domain: "SherpaOnnxOfflineEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Missing sherpa model config"]
            ))
        }

        // Download if needed
        if !downloader.isModelDownloaded(model) {
            modelState = .downloading
            downloader.onProgress = { [weak self] progress in
                self?.downloadProgress = progress
            }
            _ = try await downloader.downloadModel(model)
        }

        modelState = .downloaded
        currentModel = model

        // Load immediately after download
        try await loadModel(model)
    }

    func loadModel(_ model: ModelInfo) async throws {
        guard let config = model.sherpaModelConfig,
              let modelDir = downloader.modelDirectory(for: model) else {
            throw AppError.modelLoadFailed(underlying: NSError(
                domain: "SherpaOnnxOfflineEngine", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Model not downloaded"]
            ))
        }

        modelState = .loading
        let dirPath = modelDir.path

        do {
            let recognizer = try await Task.detached {
                return try Self.createRecognizer(config: config, modelDir: dirPath)
            }.value

            self.recognizer = recognizer
            self.currentModel = model
            self.modelState = .loaded
        } catch {
            modelState = .error
            throw AppError.modelLoadFailed(underlying: error)
        }
    }

    func isModelDownloaded(_ model: ModelInfo) -> Bool {
        downloader.isModelDownloaded(model)
    }

    func unloadModel() async {
        recognizer = nil
        currentModel = nil
        modelState = .unloaded
    }

    func startRecording() async throws {
        try await recorder.startRecording()
    }

    func stopRecording() {
        recorder.stopRecording()
    }

    func transcribe(audioArray: [Float], options: ASRTranscriptionOptions) async throws -> ASRResult {
        guard let recognizer else {
            throw AppError.modelNotReady
        }

        // Models using the standard mel feature extractor (SenseVoice) have
        // normalize_samples=True which divides by 32768, so we must scale up.
        // Moonshine has its own preprocessor.onnx that takes [-1, 1] directly.
        let isMoonshine = currentModel?.sherpaModelConfig?.modelType == .moonshine
        let samples = isMoonshine ? audioArray : audioArray.map { $0 * 32768.0 }

        let result = await Task.detached {
            recognizer.decode(samples: samples, sampleRate: 16000)
        }.value

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return ASRResult(text: "", segments: [], language: nil)
        }

        // SenseVoice provides language detection
        let detectedLang: String? = result.lang.isEmpty ? nil : result.lang

        // Create a single segment for the entire transcription
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
            language: detectedLang ?? options.language
        )
    }

    // MARK: - Private

    private nonisolated static func createRecognizer(
        config: SherpaModelConfig,
        modelDir: String
    ) throws -> SherpaOnnxOfflineRecognizer {
        let fm = FileManager.default
        let tokensPath = "\(modelDir)/\(config.tokens)"

        guard fm.fileExists(atPath: tokensPath) else {
            throw NSError(domain: "SherpaOnnxOfflineEngine", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "tokens.txt not found at \(tokensPath)"])
        }

        var modelConfig: SherpaOnnxOfflineModelConfig

        switch config.modelType {
        case .moonshine:
            guard let preprocessor = config.preprocessor,
                  let encoder = config.encoder,
                  let uncachedDecoder = config.uncachedDecoder,
                  let cachedDecoder = config.cachedDecoder else {
                throw NSError(domain: "SherpaOnnxOfflineEngine", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "Missing moonshine model file names in config"])
            }
            let paths = [preprocessor, encoder, uncachedDecoder, cachedDecoder]
            for p in paths {
                let fullPath = "\(modelDir)/\(p)"
                guard fm.fileExists(atPath: fullPath) else {
                    throw NSError(domain: "SherpaOnnxOfflineEngine", code: -3,
                                  userInfo: [NSLocalizedDescriptionKey: "Model file not found: \(p)"])
                }
            }
            let moonshineConfig = sherpaOnnxOfflineMoonshineModelConfig(
                preprocessor: "\(modelDir)/\(preprocessor)",
                encoder: "\(modelDir)/\(encoder)",
                uncachedDecoder: "\(modelDir)/\(uncachedDecoder)",
                cachedDecoder: "\(modelDir)/\(cachedDecoder)"
            )
            modelConfig = sherpaOnnxOfflineModelConfig(
                tokens: tokensPath,
                numThreads: 2,
                debug: 0,
                moonshine: moonshineConfig
            )

        case .senseVoice:
            guard let senseVoiceModel = config.senseVoiceModel else {
                throw NSError(domain: "SherpaOnnxOfflineEngine", code: -4,
                              userInfo: [NSLocalizedDescriptionKey: "Missing SenseVoice model file name in config"])
            }
            let modelPath = "\(modelDir)/\(senseVoiceModel)"
            guard fm.fileExists(atPath: modelPath) else {
                throw NSError(domain: "SherpaOnnxOfflineEngine", code: -4,
                              userInfo: [NSLocalizedDescriptionKey: "Model file not found: \(senseVoiceModel)"])
            }
            let senseVoiceConfig = sherpaOnnxOfflineSenseVoiceModelConfig(
                model: modelPath,
                language: "",
                useInverseTextNormalization: true
            )
            modelConfig = sherpaOnnxOfflineModelConfig(
                tokens: tokensPath,
                numThreads: 2,
                debug: 0,
                senseVoice: senseVoiceConfig
            )

        case .zipformerTransducer:
            throw NSError(domain: "SherpaOnnxOfflineEngine", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "Zipformer transducer should use streaming engine"])

        case .omnilingualCtc:
            guard let omniModel = config.omnilingualModel else {
                throw NSError(domain: "SherpaOnnxOfflineEngine", code: -7,
                              userInfo: [NSLocalizedDescriptionKey: "Missing omnilingual model file name in config"])
            }
            let modelPath = "\(modelDir)/\(omniModel)"
            guard fm.fileExists(atPath: modelPath) else {
                throw NSError(domain: "SherpaOnnxOfflineEngine", code: -7,
                              userInfo: [NSLocalizedDescriptionKey: "Model file not found: \(omniModel)"])
            }
            let omniConfig = sherpaOnnxOfflineOmnilingualAsrCtcModelConfig(model: modelPath)
            modelConfig = sherpaOnnxOfflineModelConfig(
                tokens: tokensPath,
                numThreads: 2,
                debug: 0,
                omnilingual: omniConfig
            )
        }

        let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80)
        var recognizerConfig = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featConfig,
            modelConfig: modelConfig,
            decodingMethod: "greedy_search"
        )

        guard let recognizer = SherpaOnnxOfflineRecognizer(config: &recognizerConfig) else {
            throw NSError(domain: "SherpaOnnxOfflineEngine", code: -6,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create offline recognizer — model files may be invalid"])
        }
        return recognizer
    }
}
