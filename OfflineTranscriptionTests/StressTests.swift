import XCTest
@testable import OfflineTranscription

/// Stress tests: rapid start/stop, many iterations, large segment counts, memory pressure.
@MainActor
final class StressTests: XCTestCase {

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
        ASRSegment(id: Int.random(in: 0...100000), text: text, start: start, end: end)
    }

    private func result(_ segments: [ASRSegment]) -> ASRResult {
        ASRResult(
            text: segments.map(\.text).joined(separator: " "),
            segments: segments, language: "en"
        )
    }

    // MARK: - Rapid Start/Stop

    func testRapidStopFromIdleNoOp() {
        // Rapidly calling stop when idle should be safe.
        for _ in 0..<100 {
            service.stopRecording()
        }
        XCTAssertEqual(service.sessionState, .idle)
        XCTAssertFalse(service.isRecording)
    }

    func testRapidClearTranscription() {
        // Rapidly clearing should be safe.
        for i in 0..<50 {
            service.testFeedResult(result([seg(" word\(i)", Float(i), Float(i + 1))]))
            service.clearTranscription()
        }
        XCTAssertEqual(service.confirmedSegments.count, 0)
        XCTAssertEqual(service.unconfirmedSegments.count, 0)
        XCTAssertEqual(service.fullTranscriptionText, "")
    }

    // MARK: - Many Iterations

    func testFiftyIterationsProgressive() {
        for i in 0..<50 {
            var segs: [ASRSegment] = []
            for j in 0...i {
                segs.append(seg(" w\(j)", Float(j), Float(j + 1)))
            }
            service.testFeedResult(result(segs))
        }

        let total = service.confirmedSegments.count + service.unconfirmedSegments.count
        XCTAssertGreaterThan(total, 0)
        XCTAssertGreaterThan(service.confirmedSegments.count, 0)
        XCTAssertFalse(service.fullTranscriptionText.isEmpty)
    }

    func testHundredIdenticalResults() {
        let segs = [seg(" Hello", 0, 1), seg(" world", 1, 2)]

        for _ in 0..<100 {
            service.testFeedResult(result(segs))
        }

        // Every 2 iterations confirms 2 segments (confirm → flush → refill cycle).
        // 100 iterations = 50 confirm cycles × 2 segments = 100 confirmed.
        XCTAssertEqual(service.confirmedSegments.count, 100)
        XCTAssertEqual(service.unconfirmedSegments.count, 0)
    }

    // MARK: - Large Segment Counts

    func testLargeSegmentCount() {
        var segs1: [ASRSegment] = []
        for i in 0..<200 {
            segs1.append(seg(" word\(i)", Float(i), Float(i) + 0.5))
        }
        service.testFeedResult(result(segs1))
        XCTAssertEqual(service.unconfirmedSegments.count, 200)

        // Second pass with same + one more
        var segs2 = segs1
        segs2.append(seg(" extra", 200, 200.5))
        service.testFeedResult(result(segs2))

        XCTAssertEqual(service.confirmedSegments.count, 200)
        XCTAssertEqual(service.unconfirmedSegments.count, 1)
    }

    // MARK: - Alternating Content

    func testAlternatingContent() {
        let a = [seg(" Alpha", 0, 1)]
        let b = [seg(" Beta", 0, 1)]

        for i in 0..<20 {
            service.testFeedResult(result(i % 2 == 0 ? a : b))
        }

        // Alternating never matches previous, so nothing should be confirmed.
        XCTAssertEqual(service.confirmedSegments.count, 0)
        XCTAssertEqual(service.unconfirmedSegments.count, 1)
    }

    // MARK: - Empty Results Interspersed

    func testEmptyResultsInterspersed() {
        let segs = [seg(" Hello", 0, 1)]

        service.testFeedResult(result(segs))
        service.testFeedResult(result([]))
        service.testFeedResult(result(segs))
        service.testFeedResult(result(segs))

        // After empty result, prevUnconfirmed is empty, so next result
        // goes to unconfirmed. Then matching on the 4th iteration confirms.
        XCTAssertEqual(service.confirmedSegments.count, 1)
    }

    // MARK: - Session Clear Mid-Stream

    func testClearMidStreamAndRestart() {
        // Build up some state
        let s1 = [seg(" First", 0, 1)]
        let s2 = [seg(" First", 0, 1), seg(" session", 1, 2)]
        service.testFeedResult(result(s1))
        service.testFeedResult(result(s2))
        XCTAssertGreaterThan(service.confirmedSegments.count, 0)

        // Clear
        service.clearTranscription()
        XCTAssertEqual(service.confirmedSegments.count, 0)
        XCTAssertEqual(service.unconfirmedSegments.count, 0)
        XCTAssertEqual(service.fullTranscriptionText, "")

        // Restart
        let s3 = [seg(" New", 0, 1)]
        service.testFeedResult(result(s3))
        XCTAssertEqual(service.unconfirmedSegments.count, 1)
        XCTAssertTrue(service.fullTranscriptionText.contains("New"))
    }

    // MARK: - Confirmed Text Accumulation

    func testConfirmedTextAccumulatesCorrectly() {
        service.testFeedResult(result([seg(" A", 0, 1)]))
        service.testFeedResult(result([seg(" A", 0, 1), seg(" B", 1, 2)]))
        // "A" confirmed
        XCTAssertTrue(service.confirmedText.contains("A"))

        service.testFeedResult(result([seg(" B", 1, 2), seg(" C", 2, 3)]))
        // "B" confirmed
        XCTAssertTrue(service.confirmedText.contains("B"))

        service.testFeedResult(result([seg(" C", 2, 3), seg(" D", 3, 4)]))
        // "C" confirmed
        XCTAssertTrue(service.confirmedText.contains("C"))

        XCTAssertEqual(service.confirmedSegments.count, 3)
    }
}
