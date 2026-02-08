import Foundation

struct ModelInfo: Identifiable, Hashable {
    let id: String
    let displayName: String
    let parameterCount: String
    let sizeOnDisk: String
    let description: String
    let family: ModelFamily
    let engineType: ASREngineType
    let languages: String

    /// WhisperKit variant name (e.g. "openai_whisper-tiny"). Only for WhisperKit models.
    let variant: String?

    /// sherpa-onnx model config. Only for sherpa-onnx models.
    let sherpaModelConfig: SherpaModelConfig?

    static let availableModels: [ModelInfo] = [
        // MARK: - SenseVoice (sherpa-onnx offline)
        ModelInfo(
            id: "sensevoice-small",
            displayName: "SenseVoice Small",
            parameterCount: "234M",
            sizeOnDisk: "~240 MB",
            description: "Multilingual (zh/en/ja/ko/yue). Fast on-device offline ASR.",
            family: .senseVoice,
            engineType: .sherpaOnnxOffline,
            languages: "zh/en/ja/ko/yue",
            variant: nil,
            sherpaModelConfig: SherpaModelConfig(
                repoName: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17",
                tokens: "tokens.txt",
                modelType: .senseVoice,
                senseVoiceModel: "model.int8.onnx"
            )
        ),
        // MARK: - Parakeet (FluidAudio, CoreML)
        ModelInfo(
            id: "parakeet-tdt-v3",
            displayName: "Parakeet TDT 0.6B",
            parameterCount: "600M",
            sizeOnDisk: "~600 MB",
            description: "High-accuracy multilingual model via FluidAudio CoreML runtime.",
            family: .parakeet,
            engineType: .fluidAudio,
            languages: "25 European languages",
            variant: nil,
            sherpaModelConfig: nil
        ),
    ]

    static let defaultModel = availableModels.first { $0.id == "sensevoice-small" }!

    var inferenceMethodLabel: String {
        switch engineType {
        case .whisperKit:
            return "CoreML (WhisperKit)"
        case .sherpaOnnxOffline:
            return "sherpa-onnx offline (ONNX Runtime)"
        case .sherpaOnnxStreaming:
            return "sherpa-onnx streaming (ONNX Runtime)"
        case .fluidAudio:
            return "CoreML (FluidAudio)"
        }
    }

    /// Backward-compat: find a model by old-style ID ("tiny" → "whisper-tiny").
    static func findByLegacyId(_ legacyId: String) -> ModelInfo? {
        if let model = availableModels.first(where: { $0.id == legacyId }) {
            return model
        }
        return availableModels.first(where: { $0.id == "whisper-\(legacyId)" })
    }

    /// Models grouped by family for UI display.
    static var modelsByFamily: [(family: ModelFamily, models: [ModelInfo])] {
        let grouped = Dictionary(grouping: availableModels, by: \.family)
        let order: [ModelFamily] = [.whisper, .moonshine, .senseVoice, .zipformer, .omnilingual, .parakeet]
        return order.compactMap { family in
            guard let models = grouped[family], !models.isEmpty else { return nil }
            return (family: family, models: models)
        }
    }
}

// MARK: - sherpa-onnx Model Config

enum SherpaModelType: String, Codable, Sendable {
    case moonshine
    case senseVoice
    case zipformerTransducer
    case omnilingualCtc
}

struct SherpaModelConfig: Hashable, Sendable {
    let repoName: String
    let tokens: String
    let modelType: SherpaModelType

    // Moonshine offline
    var preprocessor: String?
    var encoder: String?
    var uncachedDecoder: String?
    var cachedDecoder: String?

    // SenseVoice
    var senseVoiceModel: String?

    // Zipformer streaming transducer
    var joiner: String?

    // Omnilingual CTC
    var omnilingualModel: String?

    /// All files needed for this model (used for individual file downloads).
    var allFiles: [String] {
        var files = [tokens]
        switch modelType {
        case .moonshine:
            if let p = preprocessor { files.append(p) }
            if let e = encoder { files.append(e) }
            if let u = uncachedDecoder { files.append(u) }
            if let c = cachedDecoder { files.append(c) }
        case .senseVoice:
            if let m = senseVoiceModel { files.append(m) }
        case .zipformerTransducer:
            if let e = encoder { files.append(e) }
            if let d = uncachedDecoder { files.append(d) }
            if let j = joiner { files.append(j) }
        case .omnilingualCtc:
            if let m = omnilingualModel { files.append(m) }
        }
        return files
    }
}
