import XCTest
import SwiftData
@testable import OfflineTranscription

/// Tests for ViewModels and SwiftData persistence.
@MainActor
final class ViewModelTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "selectedModelVariant")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "selectedModelVariant")
        super.tearDown()
    }

    // MARK: - Iteration 1
    func testTranscriptionViewModelInitialState() {
        let vm = TranscriptionViewModel(whisperService: WhisperService())
        XCTAssertFalse(vm.isRecording)
        XCTAssertEqual(vm.confirmedText, "")
        XCTAssertEqual(vm.hypothesisText, "")
        XCTAssertEqual(vm.fullText, "")
        XCTAssertFalse(vm.showError)
        XCTAssertEqual(vm.errorMessage, "")
        XCTAssertFalse(vm.hasEngineError)
    }

    // MARK: - Iteration 2
    func testTranscriptionViewModelErrorOnStart() async {
        let vm = TranscriptionViewModel(whisperService: WhisperService())
        await vm.startRecording()
        XCTAssertTrue(vm.showError)
        XCTAssertFalse(vm.errorMessage.isEmpty)
    }

    // MARK: - Iteration 3
    func testModelManagementViewModelState() {
        let vm = ModelManagementViewModel(whisperService: WhisperService())
        XCTAssertFalse(vm.isDownloading)
        XCTAssertFalse(vm.isLoading)
        XCTAssertFalse(vm.isReady)
        XCTAssertEqual(vm.downloadProgress, 0.0)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.selectedModel.id, "whisper-base")
    }

    // MARK: - Iteration 4
    func testModelSelectionChange() {
        let service = WhisperService()
        let vm = ModelManagementViewModel(whisperService: service)
        let whisperTiny = ModelInfo.availableModels.first { $0.id == "whisper-tiny" }!
        vm.selectedModel = whisperTiny
        XCTAssertEqual(vm.selectedModel.id, "whisper-tiny")
        XCTAssertEqual(service.selectedModel.id, "whisper-tiny")
    }

    // MARK: - Iteration 5: Save empty transcription is no-op
    @MainActor
    func testSaveEmptyTranscription() throws {
        let container = try ModelContainer(
            for: TranscriptionRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext
        let vm = TranscriptionViewModel(whisperService: WhisperService())
        vm.saveTranscription(using: ctx)

        let records = try ctx.fetch(FetchDescriptor<TranscriptionRecord>())
        XCTAssertEqual(records.count, 0, "Should not save empty transcription")
    }

    // MARK: - Iteration 6: ViewModel delegates to service
    func testViewModelDelegatesToService() {
        let service = WhisperService()
        let vm = TranscriptionViewModel(whisperService: service)
        service.testSetState(confirmedText: "test confirmed", hypothesisText: "test hypothesis")
        XCTAssertEqual(vm.confirmedText, "test confirmed")
        XCTAssertEqual(vm.hypothesisText, "test hypothesis")
    }

    // MARK: - Iteration 7: Toggle recording without model errors
    func testToggleRecordingErrors() async {
        let vm = TranscriptionViewModel(whisperService: WhisperService())
        await vm.toggleRecording()
        XCTAssertTrue(vm.showError)
    }

    // MARK: - Iteration 8: isModelDownloaded delegates to service
    func testIsModelDownloaded() {
        let service = WhisperService()
        let vm = ModelManagementViewModel(whisperService: service)
        for model in ModelInfo.availableModels {
            XCTAssertEqual(vm.isModelDownloaded(model), service.isModelDownloaded(model))
        }
    }

    // MARK: - Iteration 9: Multiple SwiftData records
    @MainActor
    func testMultipleRecords() throws {
        let container = try ModelContainer(
            for: TranscriptionRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext

        let r1 = TranscriptionRecord(text: "First", durationSeconds: 5, modelUsed: "Base")
        let r2 = TranscriptionRecord(text: "Second", durationSeconds: 10, modelUsed: "Tiny")
        let r3 = TranscriptionRecord(text: "Third", durationSeconds: 15, modelUsed: "Small")

        ctx.insert(r1)
        ctx.insert(r2)
        ctx.insert(r3)
        try ctx.save()

        let records = try ctx.fetch(FetchDescriptor<TranscriptionRecord>())
        XCTAssertEqual(records.count, 3)
    }

    // MARK: - Iteration 10: Delete record
    @MainActor
    func testDeleteRecord() throws {
        let container = try ModelContainer(
            for: TranscriptionRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext

        let r1 = TranscriptionRecord(text: "To delete", durationSeconds: 5, modelUsed: "Base")
        let r2 = TranscriptionRecord(text: "To keep", durationSeconds: 10, modelUsed: "Base")
        ctx.insert(r1)
        ctx.insert(r2)
        try ctx.save()

        ctx.delete(r1)
        try ctx.save()

        let remaining = try ctx.fetch(FetchDescriptor<TranscriptionRecord>())
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].text, "To keep")
    }
}
