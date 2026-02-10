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

    init(
        id: String,
        displayName: String,
        parameterCount: String,
        sizeOnDisk: String,
        description: String,
        family: ModelFamily,
        engineType: ASREngineType,
        languages: String,
        variant: String? = nil,
        sherpaModelConfig: SherpaModelConfig? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.parameterCount = parameterCount
        self.sizeOnDisk = sizeOnDisk
        self.description = description
        self.family = family
        self.engineType = engineType
        self.languages = languages
        self.variant = variant
        self.sherpaModelConfig = sherpaModelConfig
    }

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
    ]

    static let defaultModel = availableModels.first { $0.id == "sensevoice-small" }!

    var inferenceMethodLabel: String {
        return "sherpa-onnx offline (ONNX Runtime)"
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
        let order: [ModelFamily] = [.senseVoice]
        return order.compactMap { family in
            guard let models = grouped[family], !models.isEmpty else { return nil }
            return (family: family, models: models)
        }
    }
}

// MARK: - sherpa-onnx Model Config

enum SherpaModelType: String, Codable, Sendable {
    case senseVoice
}

struct SherpaModelConfig: Hashable, Sendable {
    let repoName: String
    let tokens: String
    let modelType: SherpaModelType

    // SenseVoice
    var senseVoiceModel: String?

    /// All files needed for this model (used for individual file downloads).
    var allFiles: [String] {
        var files = [tokens]
        if let m = senseVoiceModel { files.append(m) }
        return files
    }
}
