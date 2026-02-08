import Foundation
@preconcurrency import SherpaOnnxKit

/// ASREngine implementation for sherpa-onnx streaming models (Zipformer transducer).
@MainActor
final class SherpaOnnxStreamingEngine: ASREngine {
    var isStreaming: Bool { true }
    private(set) var modelState: ASRModelState = .unloaded
    private(set) var downloadProgress: Double = 0.0
    var audioSamples: [Float] { recorder.audioSamples }
    var relativeEnergy: [Float] { recorder.relativeEnergy }

    /// Use nonisolated(unsafe) so we can hand the recognizer to the serial decode queue.
    nonisolated(unsafe) private var recognizer: SherpaOnnxRecognizer?
    private let recorder = AudioRecorder()
    private let downloader = ModelDownloader()
    private var currentModel: ModelInfo?

    /// Latest streaming result text (updated from decode queue).
    private var latestText: String = ""

    /// Sequential ID counter for stable segment identity.
    private var segmentIdCounter: Int = 0

    /// Serial queue for decode work — keeps heavy processing off the main actor.
    private let decodeQueue = DispatchQueue(label: "sherpa.streaming.decode", qos: .userInteractive)

    // MARK: - ASREngine

    func setupModel(_ model: ModelInfo) async throws {
        guard let config = model.sherpaModelConfig else {
            throw AppError.modelLoadFailed(underlying: NSError(
                domain: "SherpaOnnxStreamingEngine", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Missing sherpa model config"]
            ))
        }

        if !downloader.isModelDownloaded(model) {
            modelState = .downloading
            downloader.onProgress = { [weak self] progress in
                self?.downloadProgress = progress
            }
            _ = try await downloader.downloadModel(model)
        }

        modelState = .downloaded
        currentModel = model
        try await loadModel(model)
    }

    func loadModel(_ model: ModelInfo) async throws {
        guard let config = model.sherpaModelConfig,
              let modelDir = downloader.modelDirectory(for: model) else {
            throw AppError.modelLoadFailed(underlying: NSError(
                domain: "SherpaOnnxStreamingEngine", code: -2,
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
        // Stop recording first to prevent callbacks from firing after cleanup
        recorder.onNewAudio = nil
        recorder.stopRecording()

        // Drain the decode queue so no tasks reference recognizer after nil
        await withCheckedContinuation { continuation in
            decodeQueue.async {
                continuation.resume()
            }
        }

        recognizer = nil
        currentModel = nil
        modelState = .unloaded
        latestText = ""
    }

    func startRecording() async throws {
        try await recorder.startRecording()
        latestText = ""
        recognizer?.reset(hotwords: "")

        // Set up audio callback — dispatches decode to background queue
        recorder.onNewAudio = { [weak self] samples in
            self?.enqueueAudio(samples)
        }
    }

    func stopRecording() {
        recorder.onNewAudio = nil
        recorder.stopRecording()

        // Final decode — drain asynchronously to avoid blocking the main thread
        guard let recognizer else { return }
        let capturedRecognizer = recognizer
        Task { @MainActor in
            let finalText = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                decodeQueue.async {
                    capturedRecognizer.inputFinished()
                    while capturedRecognizer.isReady() {
                        capturedRecognizer.decode()
                    }
                    let text = capturedRecognizer.getResult().text
                    continuation.resume(returning: text)
                }
            }
            self.latestText = finalText
        }
    }

    func transcribe(audioArray: [Float], options: ASRTranscriptionOptions) async throws -> ASRResult {
        // For streaming, transcribe is not the primary path.
        enqueueAudio(audioArray)
        return getStreamingResult() ?? ASRResult(text: "", segments: [], language: nil)
    }

    /// Dispatch audio to the serial decode queue so decoding stays off the main actor.
    private func enqueueAudio(_ samples: [Float]) {
        guard let recognizer else { return }

        // sherpa-onnx C API expects int16-scaled float samples [-32768, 32768];
        // internally it divides by 32768 (normalize_samples=True, not settable).
        // Our audio is already float [-1, 1], so scale up to compensate.
        let scaledSamples = samples.map { $0 * 32768.0 }

        decodeQueue.async { [weak self] in
            recognizer.acceptWaveform(samples: scaledSamples, sampleRate: 16000)

            while recognizer.isReady() {
                recognizer.decode()
            }

            let text = recognizer.getResult().text

            Task { @MainActor [weak self] in
                self?.latestText = text
            }
        }
    }

    func feedAudio(_ samples: [Float]) throws {
        guard recognizer != nil else { throw AppError.modelNotReady }
        enqueueAudio(samples)
    }

    func getStreamingResult() -> ASRResult? {
        let text = latestText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let duration = Float(audioSamples.count) / 16000.0
        let segment = ASRSegment(
            id: segmentIdCounter,
            text: " " + text,
            start: 0,
            end: duration
        )

        return ASRResult(text: text, segments: [segment], language: "en")
    }

    func isEndpointDetected() -> Bool {
        recognizer?.isEndpoint() ?? false
    }

    func resetStreamingState() {
        recognizer?.reset(hotwords: "")
        latestText = ""
        segmentIdCounter += 1
    }

    // MARK: - Private

    private nonisolated static func createRecognizer(
        config: SherpaModelConfig,
        modelDir: String
    ) throws -> SherpaOnnxRecognizer {
        let fm = FileManager.default
        let tokensPath = "\(modelDir)/\(config.tokens)"

        guard fm.fileExists(atPath: tokensPath) else {
            throw NSError(domain: "SherpaOnnxStreamingEngine", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "tokens.txt not found at \(tokensPath)"])
        }

        guard let encoder = config.encoder,
              let uncachedDecoder = config.uncachedDecoder,
              let joiner = config.joiner else {
            throw NSError(domain: "SherpaOnnxStreamingEngine", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Missing transducer model file names in config"])
        }

        let paths = [encoder, uncachedDecoder, joiner]
        for p in paths {
            let fullPath = "\(modelDir)/\(p)"
            guard fm.fileExists(atPath: fullPath) else {
                throw NSError(domain: "SherpaOnnxStreamingEngine", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "Model file not found: \(p)"])
            }
        }

        let transducerConfig = sherpaOnnxOnlineTransducerModelConfig(
            encoder: "\(modelDir)/\(encoder)",
            decoder: "\(modelDir)/\(uncachedDecoder)",
            joiner: "\(modelDir)/\(joiner)"
        )

        let modelConfig = sherpaOnnxOnlineModelConfig(
            tokens: tokensPath,
            transducer: transducerConfig,
            numThreads: 2,
            debug: 0
        )

        let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80)

        var recognizerConfig = sherpaOnnxOnlineRecognizerConfig(
            featConfig: featConfig,
            modelConfig: modelConfig,
            enableEndpoint: true,
            decodingMethod: "greedy_search"
        )

        guard let recognizer = SherpaOnnxRecognizer(config: &recognizerConfig) else {
            throw NSError(domain: "SherpaOnnxStreamingEngine", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create streaming recognizer — model files may be invalid"])
        }
        return recognizer
    }
}
