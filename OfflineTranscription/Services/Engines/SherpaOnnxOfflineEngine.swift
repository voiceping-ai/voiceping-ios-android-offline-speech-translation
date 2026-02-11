import Foundation
import SherpaOnnxKit

/// ASREngine implementation for sherpa-onnx offline SenseVoice model.
@MainActor
final class SherpaOnnxOfflineEngine: ASREngine {
    var isStreaming: Bool { false }
    private(set) var modelState: ASRModelState = .unloaded
    private(set) var downloadProgress: Double = 0.0
    private(set) var loadingStatusMessage: String = ""
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
        loadingStatusMessage = "Loading model..."

        do {
            let recognizer = try await Task.detached {
                return try Self.createRecognizer(config: config, modelDir: dirPath)
            }.value

            NSLog("[SherpaOnnxOfflineEngine] Created recognizer for model=%@", config.modelType.rawValue)
            self.recognizer = recognizer
            self.currentModel = model
            self.modelState = .loaded
            self.loadingStatusMessage = ""
        } catch {
            modelState = .error
            loadingStatusMessage = ""
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

        let modelName = currentModel?.id ?? "unknown"
        let audioDuration = Float(audioArray.count) / 16000.0

        // Log audio stats
        let rms = sqrt(audioArray.reduce(0.0) { $0 + $1 * $1 } / max(Float(audioArray.count), 1))
        NSLog("[SherpaOnnxOfflineEngine] TRANSCRIBE model=%@ samples=%d duration=%.2fs rms=%.6f",
              modelName, audioArray.count, audioDuration, rms)

        // All sherpa-onnx models consume raw [-1, 1] float waveforms directly.
        // No int16 scaling — matches Android behavior where SenseVoice works
        // with raw floats and has better accuracy.
        let samples = audioArray

        let decodeStart = CFAbsoluteTimeGetCurrent()
        let result = await Task.detached {
            recognizer.decode(samples: samples, sampleRate: 16000)
        }.value
        let decodeEnd = CFAbsoluteTimeGetCurrent()

        var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("[SherpaOnnxOfflineEngine] Decode took %.3fs result_len=%d lang=\"%@\" text=\"%@\"",
              decodeEnd - decodeStart, text.count, result.lang, String(text.prefix(200)))

        // SenseVoice provides language detection.
        // Normalize: strip angle-bracket tokens (e.g. "<|en|>" → "en") so the
        // language code is clean for translation and locale matching.
        let detectedLang: String? = {
            let raw = result.lang.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            return raw.replacingOccurrences(of: "<|", with: "")
                .replacingOccurrences(of: "|>", with: "")
        }()

        // Strip spurious spaces from CJK output. SenseVoice's BPE decoder
        // sometimes inserts word-boundary spaces that are wrong for ja/zh/ko.
        if let langCode = detectedLang {
            if ["ja", "zh", "ko", "yue"].contains(langCode) {
                let before = text
                text = Self.stripCJKSpaces(text)
                if before != text {
                    NSLog("[SherpaOnnxOfflineEngine] CJK space strip (%@): \"%@\" → \"%@\"",
                          langCode, before, text)
                }
            }
        }

        guard !text.isEmpty else {
            return ASRResult(text: "", segments: [], language: options.language)
        }

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

    /// Create a recognizer using CPU provider only (CoreML silently fails on some devices).
    private nonisolated static func createRecognizer(
        config: SherpaModelConfig,
        modelDir: String
    ) throws -> SherpaOnnxOfflineRecognizer {
        let provider = "cpu"
        let fm = FileManager.default
        let tokensPath = "\(modelDir)/\(config.tokens)"

        guard fm.fileExists(atPath: tokensPath) else {
            throw NSError(domain: "SherpaOnnxOfflineEngine", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "tokens.txt not found at \(tokensPath)"])
        }

        let numThreads = recommendedOfflineThreads()

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
            language: "auto",
            useInverseTextNormalization: true
        )
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: tokensPath,
            numThreads: numThreads,
            provider: provider,
            debug: 0,
            senseVoice: senseVoiceConfig
        )

        let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80)
        var recognizerConfig = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featConfig,
            modelConfig: modelConfig,
            decodingMethod: "greedy_search"
        )

        guard let recognizer = SherpaOnnxOfflineRecognizer(config: &recognizerConfig) else {
            throw NSError(domain: "SherpaOnnxOfflineEngine", code: -6,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create offline recognizer for provider \(provider)"])
        }

        return recognizer
    }

    /// Remove spaces between CJK characters. Keeps spaces around Latin/number runs.
    private nonisolated static func stripCJKSpaces(_ text: String) -> String {
        var result = ""
        let chars = Array(text)
        for (i, char) in chars.enumerated() {
            if char == " " {
                let prev = i > 0 ? chars[i - 1] : nil
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                // Keep space only if both neighbors are non-CJK (Latin, digits, etc.)
                let prevIsCJK = prev.map { Self.isCJK($0) } ?? true
                let nextIsCJK = next.map { Self.isCJK($0) } ?? true
                if !prevIsCJK && !nextIsCJK {
                    result.append(char)
                }
                // Otherwise drop the space
            } else {
                result.append(char)
            }
        }
        return result
    }

    private nonisolated static func isCJK(_ char: Character) -> Bool {
        guard let scalar = char.unicodeScalars.first else { return false }
        let v = scalar.value
        // CJK Unified Ideographs, Hiragana, Katakana, Hangul, CJK punctuation
        return (v >= 0x3000 && v <= 0x9FFF)
            || (v >= 0xAC00 && v <= 0xD7AF)  // Hangul Syllables
            || (v >= 0xF900 && v <= 0xFAFF)   // CJK Compat Ideographs
            || (v >= 0xFF00 && v <= 0xFFEF)   // Fullwidth Forms
            || (v >= 0x20000 && v <= 0x2FA1F)  // CJK Extension B+
    }

    private nonisolated static func recommendedOfflineThreads() -> Int {
        let cores = max(ProcessInfo.processInfo.activeProcessorCount, 1)
        switch cores {
        case 0...2: return 1
        case 3...4: return 2
        case 5...8: return 4
        default:    return 6
        }
    }
}
