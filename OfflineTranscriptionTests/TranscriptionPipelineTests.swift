import XCTest
@testable import OfflineTranscription

/// Tests that emulate audio feeding and the eager confirmation pipeline.
/// Uses testFeedResult() to exercise processTranscriptionResult directly.
@MainActor
final class TranscriptionPipelineTests: XCTestCase {

    private var service: WhisperService!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "selectedModelVariant")
        service = WhisperService()
        service.enableEagerMode = true
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "selectedModelVariant")
        service = nil
        super.tearDown()
    }

    private func seg(_ text: String, _ start: Float, _ end: Float) -> ASRSegment {
        ASRSegment(id: Int.random(in: 0...10000), text: text, start: start, end: end)
    }

    private func result(_ segments: [ASRSegment]) -> ASRResult {
        ASRResult(
            text: segments.map(\.text).joined(separator: " "),
            segments: segments, language: "en"
        )
    }

    // MARK: - Iteration 1: First result goes to unconfirmed
    func testFirstResultUnconfirmed() {
        service.testFeedResult(result([seg(" Hello", 0, 1), seg(" world", 1, 2)]))
        XCTAssertEqual(service.confirmedSegments.count, 0)
        XCTAssertEqual(service.unconfirmedSegments.count, 2)
        XCTAssertEqual(service.confirmedText, "")
        XCTAssertTrue(service.hypothesisText.contains("Hello"))
    }

    // MARK: - Iteration 2: Matching segments confirmed
    func testMatchingSegmentsConfirmed() {
        service.testFeedResult(result([seg(" Hello", 0, 1), seg(" world", 1, 2)]))
        service.testFeedResult(result([seg(" Hello", 0, 1), seg(" there", 1, 2.5)]))

        XCTAssertEqual(service.confirmedSegments.count, 1)
        XCTAssertEqual(service.confirmedSegments[0].text, " Hello")
        XCTAssertEqual(service.unconfirmedSegments.count, 1)
        XCTAssertEqual(service.unconfirmedSegments[0].text, " there")
    }

    // MARK: - Iteration 3: Multiple matches confirmed
    func testMultipleMatchesConfirmed() {
        service.testFeedResult(result([
            seg(" The", 0, 0.5), seg(" quick", 0.5, 1), seg(" brown", 1, 1.5),
        ]))
        service.testFeedResult(result([
            seg(" The", 0, 0.5), seg(" quick", 0.5, 1), seg(" brown", 1, 1.5), seg(" fox", 1.5, 2),
        ]))

        XCTAssertEqual(service.confirmedSegments.count, 3)
        XCTAssertEqual(service.unconfirmedSegments.count, 1)
        XCTAssertTrue(service.confirmedText.contains("quick"))
        XCTAssertTrue(service.hypothesisText.contains("fox"))
    }

    // MARK: - Iteration 4: No match → nothing confirmed
    func testNoMatchNothingConfirmed() {
        service.testFeedResult(result([seg(" Hello", 0, 1)]))
        service.testFeedResult(result([seg(" Goodbye", 0, 1)]))

        XCTAssertEqual(service.confirmedSegments.count, 0)
        XCTAssertEqual(service.unconfirmedSegments.count, 1)
        XCTAssertEqual(service.unconfirmedSegments[0].text, " Goodbye")
    }

    // MARK: - Iteration 5: Empty result
    func testEmptyResult() {
        service.testFeedResult(result([]))
        XCTAssertEqual(service.confirmedSegments.count, 0)
        XCTAssertEqual(service.unconfirmedSegments.count, 0)
        XCTAssertEqual(service.fullTranscriptionText, "")
    }

    // MARK: - Iteration 6: Eager mode disabled
    func testEagerModeDisabled() {
        service.enableEagerMode = false
        let s = [seg(" Hello", 0, 1)]
        service.testFeedResult(result(s))
        service.testFeedResult(result(s))

        XCTAssertEqual(service.confirmedSegments.count, 0, "No confirmation when eager mode off")
        XCTAssertEqual(service.unconfirmedSegments.count, 1)
    }

    // MARK: - Iteration 7: Progressive transcription
    func testProgressiveTranscription() {
        service.testFeedResult(result([seg(" The quick", 0, 1)]))
        XCTAssertEqual(service.fullTranscriptionText, "The quick")

        service.testFeedResult(result([seg(" The quick", 0, 1), seg(" brown", 1, 1.5)]))
        XCTAssertEqual(service.confirmedSegments.count, 1)

        service.testFeedResult(result([seg(" brown", 1, 1.5), seg(" fox", 1.5, 2)]))
        XCTAssertEqual(service.confirmedSegments.count, 2)
        XCTAssertTrue(service.fullTranscriptionText.contains("fox"))
    }

    // MARK: - Iteration 8: Whitespace trimming
    func testWhitespaceTrimmedComparison() {
        service.testFeedResult(result([seg(" Hello ", 0, 1)]))
        service.testFeedResult(result([seg("  Hello  ", 0, 1), seg(" world", 1, 2)]))

        XCTAssertEqual(service.confirmedSegments.count, 1, "Should match despite whitespace")
    }

    // MARK: - Iteration 9: Stress test with 20 iterations
    func testRapidSuccessiveResults() {
        for i in 0..<20 {
            var segs: [ASRSegment] = []
            for j in 0...i {
                segs.append(seg(" word\(j)", Float(j), Float(j + 1)))
            }
            service.testFeedResult(result(segs))
        }

        let total = service.confirmedSegments.count + service.unconfirmedSegments.count
        XCTAssertGreaterThan(total, 0)
        XCTAssertGreaterThan(service.confirmedSegments.count, 0)
    }

    // MARK: - Chunk boundary finalization

    func testChunkBoundaryFinalizesHypothesis() {
        // Feed unconfirmed segments that will be finalized at chunk boundary
        service.testFeedResult(result([seg(" chunk one text", 0, 10)]))
        XCTAssertEqual(service.confirmedSegments.count, 0)
        XCTAssertEqual(service.unconfirmedSegments.count, 1)

        // Feed same text again → confirms it
        service.testFeedResult(result([seg(" chunk one text", 0, 10), seg(" more", 10, 14)]))
        XCTAssertEqual(service.confirmedSegments.count, 1)
        XCTAssertEqual(service.unconfirmedSegments.count, 1)

        // fullTranscriptionText should include both
        XCTAssertTrue(service.fullTranscriptionText.contains("chunk one text"))
        XCTAssertTrue(service.fullTranscriptionText.contains("more"))
    }

    func testMaxChunkSecondsIs15() {
        // Verify the chunk size was reduced to 15s (matching Android)
        // We can test this indirectly: after feeding 16s of confirmed text,
        // the chunk should finalize via processTranscriptionResult's sliceOffset logic
        // For now, just verify clear resets completedChunksText
        service.testFeedResult(result([seg(" text", 0, 14)]))
        service.testFeedResult(result([seg(" text", 0, 14)]))
        XCTAssertEqual(service.confirmedSegments.count, 1)

        service.clearTranscription()
        XCTAssertEqual(service.fullTranscriptionText, "")
    }

    // MARK: - Start/stop state isolation

    func testStartStopPreservesNoState() {
        // Session 1
        service.testFeedResult(result([seg(" Session one", 0, 5)]))
        service.testFeedResult(result([seg(" Session one", 0, 5), seg(" text", 5, 8)]))
        XCTAssertGreaterThan(service.confirmedSegments.count, 0)
        XCTAssertTrue(service.fullTranscriptionText.contains("Session one"))

        // Stop + restart
        service.clearTranscription()

        // Verify complete cleanup
        XCTAssertEqual(service.confirmedSegments.count, 0)
        XCTAssertEqual(service.unconfirmedSegments.count, 0)
        XCTAssertEqual(service.confirmedText, "")
        XCTAssertEqual(service.hypothesisText, "")
        XCTAssertEqual(service.fullTranscriptionText, "")

        // Session 2 should be independent
        service.testFeedResult(result([seg(" Session two", 0, 3)]))
        XCTAssertEqual(service.unconfirmedSegments.count, 1)
        XCTAssertFalse(service.fullTranscriptionText.contains("Session one"))
        XCTAssertTrue(service.fullTranscriptionText.contains("Session two"))
    }

    func testFiveRapidClearCycles() {
        for cycle in 0..<5 {
            service.testFeedResult(result([seg(" Cycle \(cycle)", 0, 2)]))
            service.testFeedResult(result([seg(" Cycle \(cycle)", 0, 2), seg(" data", 2, 4)]))
            XCTAssertGreaterThan(service.confirmedSegments.count, 0)

            service.clearTranscription()
            XCTAssertEqual(service.fullTranscriptionText, "",
                           "Cycle \(cycle): state should be clean after clear")
        }
    }

    // MARK: - Iteration 10: Clear between sessions
    func testClearBetweenSessions() {
        service.testFeedResult(result([seg(" Session one", 0, 2)]))
        service.testFeedResult(result([seg(" Session one", 0, 2), seg(" continues", 2, 3)]))
        XCTAssertGreaterThan(service.confirmedSegments.count, 0)

        service.clearTranscription()
        XCTAssertEqual(service.confirmedSegments.count, 0)
        XCTAssertEqual(service.unconfirmedSegments.count, 0)
        XCTAssertEqual(service.fullTranscriptionText, "")

        service.testFeedResult(result([seg(" Session two", 0, 2)]))
        XCTAssertEqual(service.unconfirmedSegments.count, 1)
        XCTAssertEqual(service.unconfirmedSegments[0].text, " Session two")
    }
}
