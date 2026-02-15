import XCTest
@testable import OfflineTranscription

/// Tests for WhisperService state, models, utilities, and error handling.
@MainActor
final class WhisperServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "selectedModelVariant")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "selectedModelVariant")
        super.tearDown()
    }

    private func makeSegment(text: String, start: Float, end: Float) -> ASRSegment {
        ASRSegment(id: Int.random(in: 0...10000), text: text, start: start, end: end)
    }

    // MARK: - Iteration 1
    func testInitialState() {
        let s = WhisperService()
        XCTAssertEqual(s.modelState, .unloaded)
        XCTAssertFalse(s.isRecording)
        XCTAssertFalse(s.isTranscribing)
        XCTAssertEqual(s.confirmedText, "")
        XCTAssertEqual(s.hypothesisText, "")
        XCTAssertEqual(s.confirmedSegments.count, 0)
        XCTAssertEqual(s.unconfirmedSegments.count, 0)
        XCTAssertEqual(s.bufferEnergy.count, 0)
        XCTAssertEqual(s.bufferSeconds, 0.0)
        XCTAssertEqual(s.tokensPerSecond, 0.0)
        XCTAssertEqual(s.downloadProgress, 0.0)
        XCTAssertNil(s.lastError)
    }

    // MARK: - Iteration 2
    func testDefaultModelSelection() {
        let s = WhisperService()
        XCTAssertEqual(s.selectedModel.id, "sensevoice-small")
        XCTAssertEqual(s.selectedModel.displayName, "SenseVoice Small")
        XCTAssertEqual(s.selectedModel.variant, nil)
    }

    // MARK: - Iteration 3
    func testModelInfoCatalog() {
        let models = ModelInfo.availableModels
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0].id, "sensevoice-small")
        XCTAssertEqual(models[0].family, .senseVoice)
        XCTAssertEqual(models[0].engineType, .sherpaOnnxOffline)
        XCTAssertEqual(models[1].id, "apple-speech")
        XCTAssertEqual(models[1].family, .appleSpeech)
        XCTAssertEqual(models[1].engineType, .appleSpeech)
        XCTAssertEqual(ModelInfo.defaultModel.id, "sensevoice-small")
    }

    // MARK: - Iteration 4
    func testStartRecordingWithoutModelThrows() async {
        let s = WhisperService()
        do {
            try await s.startRecording()
            XCTFail("Expected modelNotReady error")
        } catch let error as AppError {
            XCTAssertEqual(error.localizedDescription, AppError.modelNotReady.localizedDescription)
        } catch {
            XCTFail("Expected AppError, got \(error)")
        }
    }

    // MARK: - Iteration 5
    func testClearTranscriptionResetsState() {
        let s = WhisperService()
        s.testSetState(
            confirmedText: "Hello",
            hypothesisText: "world",
            confirmedSegments: [makeSegment(text: "Hello", start: 0, end: 1)],
            unconfirmedSegments: [makeSegment(text: "world", start: 1, end: 2)]
        )
        s.clearTranscription()
        XCTAssertEqual(s.confirmedText, "")
        XCTAssertEqual(s.hypothesisText, "")
        XCTAssertEqual(s.confirmedSegments.count, 0)
        XCTAssertEqual(s.unconfirmedSegments.count, 0)
        XCTAssertFalse(s.isRecording)
        XCTAssertEqual(s.bufferSeconds, 0.0)
        XCTAssertEqual(s.tokensPerSecond, 0.0)
    }

    // MARK: - Iteration 6
    func testFullTranscriptionText() {
        let s = WhisperService()
        XCTAssertEqual(s.fullTranscriptionText, "")

        s.testSetState(confirmedSegments: [makeSegment(text: "Hello", start: 0, end: 1)])
        XCTAssertEqual(s.fullTranscriptionText, "Hello")

        s.testSetState(
            confirmedSegments: [makeSegment(text: "Hello", start: 0, end: 1)],
            unconfirmedSegments: [makeSegment(text: " world", start: 1, end: 2)]
        )
        XCTAssertEqual(s.fullTranscriptionText, "Hello world")
    }

    // MARK: - Iteration 7
    func testFormatDuration() {
        XCTAssertEqual(FormatUtils.formatDuration(0), "0:00")
        XCTAssertEqual(FormatUtils.formatDuration(5), "0:05")
        XCTAssertEqual(FormatUtils.formatDuration(60), "1:00")
        XCTAssertEqual(FormatUtils.formatDuration(65), "1:05")
        XCTAssertEqual(FormatUtils.formatDuration(3600), "1:00:00")
        XCTAssertEqual(FormatUtils.formatDuration(3661), "1:01:01")
        XCTAssertEqual(FormatUtils.formatDuration(0.5), "0:00")
    }

    // MARK: - Iteration 8
    func testFormatFileSize() {
        let mb = FormatUtils.formatFileSize(80_000_000)
        XCTAssertTrue(mb.contains("MB"), "Got: \(mb)")
        let gb = FormatUtils.formatFileSize(1_000_000_000)
        XCTAssertTrue(gb.contains("GB") || gb.contains("MB"), "Got: \(gb)")
    }

    // MARK: - Iteration 9
    func testAppErrorDescriptions() {
        XCTAssertTrue(AppError.microphonePermissionDenied.localizedDescription.contains("denied"))
        XCTAssertTrue(AppError.microphonePermissionRestricted.localizedDescription.contains("restricted"))
        XCTAssertTrue(AppError.modelNotReady.localizedDescription.contains("not ready"))
        XCTAssertTrue(AppError.noModelSelected.localizedDescription.contains("No transcription"))

        let err = NSError(domain: "t", code: 1)
        XCTAssertTrue(AppError.modelDownloadFailed(underlying: err).localizedDescription.contains("download"))
        XCTAssertTrue(AppError.modelLoadFailed(underlying: err).localizedDescription.contains("load"))
        XCTAssertTrue(AppError.transcriptionFailed(underlying: err).localizedDescription.contains("Transcription"))
    }

    // MARK: - Iteration 10
    func testTranscriptionRecordCreation() {
        let r = TranscriptionRecord(text: "Hello world", durationSeconds: 5.5, modelUsed: "Base")
        XCTAssertEqual(r.text, "Hello world")
        XCTAssertEqual(r.durationSeconds, 5.5, accuracy: 0.001)
        XCTAssertEqual(r.modelUsed, "Base")
        XCTAssertNil(r.language)
        XCTAssertNotNil(r.id)
        XCTAssertTrue(abs(r.createdAt.timeIntervalSinceNow) < 2.0)

        let r2 = TranscriptionRecord(text: "Bonjour", durationSeconds: 3.0, modelUsed: "Small", language: "fr")
        XCTAssertEqual(r2.language, "fr")
    }

    // MARK: - New: Model families & engine types
    func testModelFamilies() {
        let senseVoiceModels = ModelInfo.availableModels.filter { $0.family == .senseVoice }
        XCTAssertEqual(senseVoiceModels.count, 1)
        XCTAssertTrue(senseVoiceModels.allSatisfy { $0.engineType == .sherpaOnnxOffline })
    }

    func testLegacyModelIdLookup() {
        XCTAssertEqual(ModelInfo.findByLegacyId("sensevoice-small")?.id, "sensevoice-small")
        XCTAssertNil(ModelInfo.findByLegacyId("nonexistent"))
    }

    func testModelsByFamily() {
        let groups = ModelInfo.modelsByFamily
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].family, .senseVoice)
        XCTAssertEqual(groups[1].family, .appleSpeech)
    }
}
