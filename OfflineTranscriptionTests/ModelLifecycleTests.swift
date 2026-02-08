import XCTest
@testable import OfflineTranscription

/// Tests for model lifecycle: catalog, selection, state transitions, download status.
@MainActor
final class ModelLifecycleTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "selectedModelVariant")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "selectedModelVariant")
        super.tearDown()
    }

    // MARK: - Model Catalog

    func testModelCatalogCount() {
        XCTAssertEqual(ModelInfo.availableModels.count, 11)
    }

    func testModelCatalogOrder() {
        let models = ModelInfo.availableModels
        XCTAssertEqual(models[0].id, "whisper-tiny")
        XCTAssertEqual(models[1].id, "whisper-base")
        XCTAssertEqual(models[2].id, "whisper-small")
        XCTAssertEqual(models[3].id, "whisper-large-v3-turbo")
        XCTAssertEqual(models[4].id, "whisper-large-v3-turbo-compressed")
        XCTAssertEqual(models[5].id, "moonshine-tiny")
        XCTAssertEqual(models[6].id, "moonshine-base")
        XCTAssertEqual(models[7].id, "sensevoice-small")
        XCTAssertEqual(models[8].id, "zipformer-20m")
        XCTAssertEqual(models[9].id, "omnilingual-300m")
        XCTAssertEqual(models[10].id, "parakeet-tdt-v3")
    }

    func testWhisperModelsHaveVariants() {
        let whisperModels = ModelInfo.availableModels.filter { $0.family == .whisper }
        XCTAssertEqual(whisperModels.count, 5)
        for model in whisperModels {
            XCTAssertNotNil(model.variant, "\(model.id) should have a variant")
            XCTAssertTrue(model.variant!.hasPrefix("openai_whisper-"),
                          "Variant \(model.variant!) should start with openai_whisper-")
        }
    }

    func testSherpaModelsHaveNoVariant() {
        let sherpaModels = ModelInfo.availableModels.filter {
            $0.variant == nil && $0.sherpaModelConfig != nil
        }
        XCTAssertEqual(sherpaModels.count, 5)
        for model in sherpaModels {
            XCTAssertNotNil(model.sherpaModelConfig,
                            "\(model.id) should have a sherpaModelConfig")
        }
    }

    func testModelInfoIdentifiable() {
        let ids = ModelInfo.availableModels.map(\.id)
        XCTAssertEqual(Set(ids).count, 11, "All model IDs should be unique")
    }

    func testModelInfoHashable() {
        let set = Set(ModelInfo.availableModels)
        XCTAssertEqual(set.count, 11, "All models should be distinct in a Set")
    }

    func testDefaultModel() {
        XCTAssertEqual(ModelInfo.defaultModel.id, "whisper-base")
        XCTAssertEqual(ModelInfo.defaultModel.displayName, "Whisper Base")
    }

    func testModelDisplayNames() {
        let names = ModelInfo.availableModels.map(\.displayName)
        XCTAssertTrue(names.contains("Whisper Tiny"))
        XCTAssertTrue(names.contains("Whisper Base"))
        XCTAssertTrue(names.contains("Whisper Small"))
        XCTAssertTrue(names.contains("Whisper Large V3 Turbo"))
        XCTAssertTrue(names.contains("Whisper Large V3 Turbo (Compressed)"))
        XCTAssertTrue(names.contains("Moonshine Tiny"))
        XCTAssertTrue(names.contains("Moonshine Base"))
        XCTAssertTrue(names.contains("SenseVoice Small"))
        XCTAssertTrue(names.contains("Zipformer Streaming"))
        XCTAssertTrue(names.contains("Omnilingual 300M"))
        XCTAssertTrue(names.contains("Parakeet TDT 0.6B"))
    }

    func testModelParameterCounts() {
        let whisperParams = ModelInfo.availableModels.filter { $0.family == .whisper }.map(\.parameterCount)
        XCTAssertEqual(whisperParams, ["39M", "74M", "244M", "809M", "809M"])
    }

    func testModelSizeStrings() {
        for model in ModelInfo.availableModels {
            XCTAssertTrue(model.sizeOnDisk.contains("MB") || model.sizeOnDisk.contains("GB"),
                          "\(model.id) size should contain MB or GB")
        }
    }

    func testModelDescriptions() {
        for model in ModelInfo.availableModels {
            XCTAssertFalse(model.description.isEmpty,
                           "\(model.id) should have a description")
        }
    }

    func testModelFamilies() {
        let families = Set(ModelInfo.availableModels.map(\.family))
        XCTAssertEqual(families, [.whisper, .moonshine, .senseVoice, .zipformer, .omnilingual, .parakeet])
    }

    func testModelEngineTypes() {
        let whisperKitModels = ModelInfo.availableModels.filter { $0.engineType == .whisperKit }
        let offlineModels = ModelInfo.availableModels.filter { $0.engineType == .sherpaOnnxOffline }
        let streamingModels = ModelInfo.availableModels.filter { $0.engineType == .sherpaOnnxStreaming }
        let fluidAudioModels = ModelInfo.availableModels.filter { $0.engineType == .fluidAudio }
        XCTAssertEqual(whisperKitModels.count, 5)
        XCTAssertEqual(offlineModels.count, 4)
        XCTAssertEqual(streamingModels.count, 1)
        XCTAssertEqual(fluidAudioModels.count, 1)
    }

    func testModelsByFamily() {
        let grouped = ModelInfo.modelsByFamily
        XCTAssertEqual(grouped.count, 6)
        XCTAssertEqual(grouped[0].family, .whisper)
        XCTAssertEqual(grouped[0].models.count, 5)
        XCTAssertEqual(grouped[1].family, .moonshine)
        XCTAssertEqual(grouped[1].models.count, 2)
        XCTAssertEqual(grouped[2].family, .senseVoice)
        XCTAssertEqual(grouped[2].models.count, 1)
        XCTAssertEqual(grouped[3].family, .zipformer)
        XCTAssertEqual(grouped[3].models.count, 1)
        XCTAssertEqual(grouped[4].family, .omnilingual)
        XCTAssertEqual(grouped[4].models.count, 1)
        XCTAssertEqual(grouped[5].family, .parakeet)
        XCTAssertEqual(grouped[5].models.count, 1)
    }

    func testLegacyModelIdLookup() {
        XCTAssertEqual(ModelInfo.findByLegacyId("tiny")?.id, "whisper-tiny")
        XCTAssertEqual(ModelInfo.findByLegacyId("base")?.id, "whisper-base")
        XCTAssertEqual(ModelInfo.findByLegacyId("small")?.id, "whisper-small")
        XCTAssertEqual(ModelInfo.findByLegacyId("whisper-base")?.id, "whisper-base")
        XCTAssertNil(ModelInfo.findByLegacyId("nonexistent"))
    }

    // MARK: - Model State Transitions

    func testInitialModelState() {
        let s = WhisperService()
        XCTAssertEqual(s.modelState, .unloaded)
        XCTAssertNil(s.whisperKit)
        XCTAssertNil(s.currentModelVariant)
    }

    func testDefaultModelSelection() {
        let s = WhisperService()
        XCTAssertEqual(s.selectedModel.id, "whisper-base")
    }

    func testModelSelectionChange() {
        let s = WhisperService()
        let tiny = ModelInfo.availableModels.first { $0.id == "whisper-tiny" }!
        s.selectedModel = tiny
        XCTAssertEqual(s.selectedModel.id, "whisper-tiny")
    }

    func testIsModelDownloadedFalseForUnknownModelConfigs() {
        let s = WhisperService()

        let unknownWhisper = ModelInfo(
            id: "unit-whisper",
            displayName: "Unit Whisper",
            parameterCount: "1M",
            sizeOnDisk: "~1 MB",
            description: "Unit test model",
            family: .whisper,
            engineType: .whisperKit,
            languages: "en",
            variant: "unit_test_variant_\(UUID().uuidString)",
            sherpaModelConfig: nil
        )
        XCTAssertFalse(s.isModelDownloaded(unknownWhisper))

        let unknownSherpaOffline = ModelInfo(
            id: "unit-sherpa-offline",
            displayName: "Unit Sherpa Offline",
            parameterCount: "1M",
            sizeOnDisk: "~1 MB",
            description: "Unit test model",
            family: .moonshine,
            engineType: .sherpaOnnxOffline,
            languages: "en",
            variant: nil,
            sherpaModelConfig: SherpaModelConfig(
                repoName: "unit_test_repo_\(UUID().uuidString)",
                tokens: "tokens.txt",
                modelType: .senseVoice,
                senseVoiceModel: "model.int8.onnx"
            )
        )
        XCTAssertFalse(s.isModelDownloaded(unknownSherpaOffline))

        let unknownSherpaStreaming = ModelInfo(
            id: "unit-sherpa-streaming",
            displayName: "Unit Sherpa Streaming",
            parameterCount: "1M",
            sizeOnDisk: "~1 MB",
            description: "Unit test model",
            family: .zipformer,
            engineType: .sherpaOnnxStreaming,
            languages: "en",
            variant: nil,
            sherpaModelConfig: SherpaModelConfig(
                repoName: "unit_test_repo_stream_\(UUID().uuidString)",
                tokens: "tokens.txt",
                modelType: .zipformerTransducer,
                encoder: "encoder.int8.onnx",
                uncachedDecoder: "decoder.onnx",
                joiner: "joiner.int8.onnx"
            )
        )
        XCTAssertFalse(s.isModelDownloaded(unknownSherpaStreaming))

        let unknownFluid = ModelInfo(
            id: "unit-fluid",
            displayName: "Unit Fluid",
            parameterCount: "1M",
            sizeOnDisk: "~1 MB",
            description: "Unit test model",
            family: .parakeet,
            engineType: .fluidAudio,
            languages: "en",
            variant: nil,
            sherpaModelConfig: nil
        )
        XCTAssertFalse(s.isModelDownloaded(unknownFluid))
    }

    func testDownloadProgressInitiallyZero() {
        let s = WhisperService()
        XCTAssertEqual(s.downloadProgress, 0.0)
    }

    // MARK: - Model Management ViewModel

    func testModelManagementVMInitialState() {
        let vm = ModelManagementViewModel(whisperService: WhisperService())
        XCTAssertFalse(vm.isDownloading)
        XCTAssertFalse(vm.isLoading)
        XCTAssertFalse(vm.isReady)
        XCTAssertEqual(vm.downloadProgress, 0.0)
        XCTAssertNil(vm.errorMessage)
    }

    func testModelManagementVMModelSelection() {
        let s = WhisperService()
        let vm = ModelManagementViewModel(whisperService: s)
        let small = ModelInfo.availableModels.first { $0.id == "whisper-small" }!
        vm.selectedModel = small
        XCTAssertEqual(vm.selectedModel.id, "whisper-small")
        XCTAssertEqual(s.selectedModel.id, "whisper-small")
    }

    func testModelManagementVMIsDownloadedDelegates() {
        let service = WhisperService()
        let vm = ModelManagementViewModel(whisperService: service)
        for model in ModelInfo.availableModels {
            XCTAssertEqual(vm.isModelDownloaded(model), service.isModelDownloaded(model))
        }
    }

    // MARK: - Configuration Persistence

    func testConfigurationDefaultValues() {
        let s = WhisperService()
        XCTAssertTrue(s.useVAD)
        XCTAssertEqual(s.silenceThreshold, 0.3, accuracy: 0.01)
        XCTAssertEqual(s.realtimeDelayInterval, 1.0, accuracy: 0.01)
        XCTAssertTrue(s.enableTimestamps)
        XCTAssertTrue(s.enableEagerMode)
    }

    func testConfigurationChanges() {
        let s = WhisperService()
        s.useVAD = false
        s.silenceThreshold = 0.5
        s.realtimeDelayInterval = 2.0
        s.enableTimestamps = false
        s.enableEagerMode = false

        XCTAssertFalse(s.useVAD)
        XCTAssertEqual(s.silenceThreshold, 0.5, accuracy: 0.01)
        XCTAssertEqual(s.realtimeDelayInterval, 2.0, accuracy: 0.01)
        XCTAssertFalse(s.enableTimestamps)
        XCTAssertFalse(s.enableEagerMode)
    }
}
