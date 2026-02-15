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
        XCTAssertEqual(ModelInfo.availableModels.count, 2)
    }

    func testModelCatalogOrder() {
        let models = ModelInfo.availableModels
        XCTAssertEqual(models[0].id, "sensevoice-small")
        XCTAssertEqual(models[1].id, "apple-speech")
    }

    func testSherpaModelsHaveConfig() {
        let sherpaModels = ModelInfo.availableModels.filter { $0.sherpaModelConfig != nil }
        XCTAssertEqual(sherpaModels.count, 1)
        XCTAssertEqual(sherpaModels[0].id, "sensevoice-small")
    }

    func testModelInfoIdentifiable() {
        let ids = ModelInfo.availableModels.map(\.id)
        XCTAssertEqual(Set(ids).count, 2, "All model IDs should be unique")
    }

    func testModelInfoHashable() {
        let set = Set(ModelInfo.availableModels)
        XCTAssertEqual(set.count, 2, "All models should be distinct in a Set")
    }

    func testDefaultModelIsSensevoice() {
        XCTAssertEqual(ModelInfo.defaultModel.id, "sensevoice-small")
        XCTAssertEqual(ModelInfo.defaultModel.displayName, "SenseVoice Small")
    }

    func testDefaultModelExistsInCatalog() {
        XCTAssertTrue(
            ModelInfo.availableModels.contains(where: { $0.id == "sensevoice-small" }),
            "sensevoice-small must exist in catalog for defaultModel to resolve correctly"
        )
    }

    func testModelDisplayNames() {
        let names = ModelInfo.availableModels.map(\.displayName)
        XCTAssertTrue(names.contains("SenseVoice Small"))
        XCTAssertTrue(names.contains("Apple Speech"))
    }

    func testModelDescriptions() {
        for model in ModelInfo.availableModels {
            XCTAssertFalse(model.description.isEmpty,
                           "\(model.id) should have a description")
        }
    }

    func testModelFamilies() {
        let families = Set(ModelInfo.availableModels.map(\.family))
        XCTAssertEqual(families, [.senseVoice, .appleSpeech])
    }

    func testModelEngineTypes() {
        let offlineModels = ModelInfo.availableModels.filter { $0.engineType == .sherpaOnnxOffline }
        let appleSpeechModels = ModelInfo.availableModels.filter { $0.engineType == .appleSpeech }
        XCTAssertEqual(offlineModels.count, 1)
        XCTAssertEqual(appleSpeechModels.count, 1)
    }

    func testModelsByFamily() {
        let grouped = ModelInfo.modelsByFamily
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(grouped[0].family, .senseVoice)
        XCTAssertEqual(grouped[0].models.count, 1)
        XCTAssertEqual(grouped[1].family, .appleSpeech)
        XCTAssertEqual(grouped[1].models.count, 1)
    }

    func testLegacyModelIdLookup() {
        XCTAssertEqual(ModelInfo.findByLegacyId("sensevoice-small")?.id, "sensevoice-small")
        XCTAssertNil(ModelInfo.findByLegacyId("nonexistent"))
    }

    // MARK: - Model State Transitions

    func testInitialModelState() {
        let s = WhisperService()
        XCTAssertEqual(s.modelState, .unloaded)
        XCTAssertNil(s.currentModelVariant)
    }

    func testDefaultModelSelection() {
        let s = WhisperService()
        XCTAssertEqual(s.selectedModel.id, "sensevoice-small")
    }

    func testModelSelectionChange() {
        let s = WhisperService()
        let appleSpeech = ModelInfo.availableModels.first { $0.id == "apple-speech" }!
        s.selectedModel = appleSpeech
        XCTAssertEqual(s.selectedModel.id, "apple-speech")
    }

    func testIsModelDownloadedFalseForUnknownModelConfigs() {
        let s = WhisperService()

        let unknownSherpaOffline = ModelInfo(
            id: "unit-sherpa-offline",
            displayName: "Unit Sherpa Offline",
            parameterCount: "1M",
            sizeOnDisk: "~1 MB",
            description: "Unit test model",
            family: .senseVoice,
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
    }

    func testDownloadProgressInitiallyZero() {
        let s = WhisperService()
        XCTAssertEqual(s.downloadProgress, 0.0)
    }

    // MARK: - Configuration Persistence

    func testConfigurationDefaultValues() {
        let s = WhisperService()
        XCTAssertTrue(s.useVAD)
        XCTAssertEqual(s.silenceThreshold, 0.0015, accuracy: 0.0001)
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
