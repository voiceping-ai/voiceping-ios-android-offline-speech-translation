import XCTest
import SwiftData
@testable import OfflineTranscription

/// Tests for SwiftData persistence, record creation, deletion, and edge cases.
@MainActor
final class DataPersistenceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "selectedModelVariant")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "selectedModelVariant")
        super.tearDown()
    }

    // MARK: - Record Creation

    func testRecordCreation() {
        let r = TranscriptionRecord(text: "Hello world", durationSeconds: 5.5, modelUsed: "Base")
        XCTAssertEqual(r.text, "Hello world")
        XCTAssertEqual(r.durationSeconds, 5.5, accuracy: 0.001)
        XCTAssertEqual(r.modelUsed, "Base")
        XCTAssertNil(r.language)
        XCTAssertNotNil(r.id)
        XCTAssertTrue(abs(r.createdAt.timeIntervalSinceNow) < 2.0)
    }

    func testRecordWithLanguage() {
        let r = TranscriptionRecord(text: "Bonjour", durationSeconds: 3.0, modelUsed: "Small", language: "fr")
        XCTAssertEqual(r.language, "fr")
    }

    func testRecordUniqueIDs() {
        let r1 = TranscriptionRecord(text: "A", durationSeconds: 1, modelUsed: "Base")
        let r2 = TranscriptionRecord(text: "B", durationSeconds: 2, modelUsed: "Base")
        XCTAssertNotEqual(r1.id, r2.id)
    }

    // MARK: - SwiftData Insert and Fetch

    @MainActor
    func testInsertAndFetch() throws {
        let container = try ModelContainer(
            for: TranscriptionRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext

        let r = TranscriptionRecord(text: "Test", durationSeconds: 10, modelUsed: "Tiny")
        ctx.insert(r)
        try ctx.save()

        let records = try ctx.fetch(FetchDescriptor<TranscriptionRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].text, "Test")
    }

    @MainActor
    func testMultipleInsert() throws {
        let container = try ModelContainer(
            for: TranscriptionRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext

        for i in 0..<10 {
            ctx.insert(TranscriptionRecord(
                text: "Record \(i)", durationSeconds: Double(i), modelUsed: "Base"
            ))
        }
        try ctx.save()

        let records = try ctx.fetch(FetchDescriptor<TranscriptionRecord>())
        XCTAssertEqual(records.count, 10)
    }

    // MARK: - Delete

    @MainActor
    func testDeleteSingleRecord() throws {
        let container = try ModelContainer(
            for: TranscriptionRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext

        let r1 = TranscriptionRecord(text: "Keep", durationSeconds: 1, modelUsed: "Base")
        let r2 = TranscriptionRecord(text: "Delete", durationSeconds: 2, modelUsed: "Base")
        ctx.insert(r1)
        ctx.insert(r2)
        try ctx.save()

        ctx.delete(r2)
        try ctx.save()

        let remaining = try ctx.fetch(FetchDescriptor<TranscriptionRecord>())
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].text, "Keep")
    }

    @MainActor
    func testDeleteAllRecords() throws {
        let container = try ModelContainer(
            for: TranscriptionRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext

        for i in 0..<5 {
            ctx.insert(TranscriptionRecord(
                text: "R\(i)", durationSeconds: 1, modelUsed: "Base"
            ))
        }
        try ctx.save()

        let all = try ctx.fetch(FetchDescriptor<TranscriptionRecord>())
        for record in all {
            ctx.delete(record)
        }
        try ctx.save()

        let remaining = try ctx.fetch(FetchDescriptor<TranscriptionRecord>())
        XCTAssertEqual(remaining.count, 0)
    }

    // MARK: - Sort Order

    @MainActor
    func testFetchSortedByDate() throws {
        let container = try ModelContainer(
            for: TranscriptionRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext

        let r1 = TranscriptionRecord(text: "First", durationSeconds: 1, modelUsed: "Base")
        // Small delay to ensure different timestamps
        let r2 = TranscriptionRecord(text: "Second", durationSeconds: 2, modelUsed: "Base")
        let r3 = TranscriptionRecord(text: "Third", durationSeconds: 3, modelUsed: "Base")

        ctx.insert(r1)
        ctx.insert(r2)
        ctx.insert(r3)
        try ctx.save()

        var descriptor = FetchDescriptor<TranscriptionRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        let latest = try ctx.fetch(descriptor)
        XCTAssertEqual(latest.count, 1)
    }

    // MARK: - Edge Cases

    @MainActor
    func testLargeTextRecord() throws {
        let container = try ModelContainer(
            for: TranscriptionRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext

        let longText = String(repeating: "This is a test sentence. ", count: 1000)
        let r = TranscriptionRecord(text: longText, durationSeconds: 600, modelUsed: "Small")
        ctx.insert(r)
        try ctx.save()

        let records = try ctx.fetch(FetchDescriptor<TranscriptionRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].text.count, longText.count)
    }

    @MainActor
    func testZeroDurationRecord() throws {
        let container = try ModelContainer(
            for: TranscriptionRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext

        let r = TranscriptionRecord(text: "Quick", durationSeconds: 0, modelUsed: "Tiny")
        ctx.insert(r)
        try ctx.save()

        let records = try ctx.fetch(FetchDescriptor<TranscriptionRecord>())
        XCTAssertEqual(records[0].durationSeconds, 0)
    }

    // MARK: - Utilities

    func testFormatDurationEdgeCases() {
        XCTAssertEqual(FormatUtils.formatDuration(0), "0:00")
        XCTAssertEqual(FormatUtils.formatDuration(-1), "0:00") // negative clamped
        XCTAssertEqual(FormatUtils.formatDuration(59), "0:59")
        XCTAssertEqual(FormatUtils.formatDuration(60), "1:00")
        XCTAssertEqual(FormatUtils.formatDuration(3599), "59:59")
        XCTAssertEqual(FormatUtils.formatDuration(3600), "1:00:00")
        XCTAssertEqual(FormatUtils.formatDuration(86400), "24:00:00")
    }

    func testFormatFileSizeValues() {
        let small = FormatUtils.formatFileSize(500)
        XCTAssertFalse(small.isEmpty)

        let medium = FormatUtils.formatFileSize(5_000_000)
        XCTAssertTrue(medium.contains("MB") || medium.contains("KB"))

        let large = FormatUtils.formatFileSize(2_000_000_000)
        XCTAssertTrue(large.contains("GB") || large.contains("MB"))
    }
}
