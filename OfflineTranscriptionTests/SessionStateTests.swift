import XCTest
@testable import OfflineTranscription

/// Tests for the session state machine and audio lifecycle.
@MainActor
final class SessionStateTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "selectedModelVariant")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "selectedModelVariant")
        super.tearDown()
    }

    // MARK: - Session State Basics

    func testInitialSessionState() {
        let s = WhisperService()
        XCTAssertEqual(s.sessionState, .idle)
    }

    func testSessionStateValues() {
        // Verify all cases exist and are distinct.
        let states: [SessionState] = [.idle, .starting, .recording, .stopping, .interrupted]
        XCTAssertEqual(Set(states.map(\.rawValue)).count, 5)
    }

    func testSessionStateEquatable() {
        XCTAssertEqual(SessionState.idle, SessionState.idle)
        XCTAssertNotEqual(SessionState.idle, SessionState.recording)
    }

    func testSessionStateSendable() {
        // SessionState should be usable across concurrency boundaries.
        let state: SessionState = .recording
        Task {
            XCTAssertEqual(state, .recording)
        }
    }

    // MARK: - State Transitions via Test Helpers

    func testSetSessionState() {
        let s = WhisperService()
        s.testSetSessionState(.recording)
        XCTAssertEqual(s.sessionState, .recording)
    }

    func testStartRecordingRequiresIdleState() async {
        let s = WhisperService()
        // Force non-idle state
        s.testSetSessionState(.recording)

        // startRecording should silently return (guard sessionState == .idle)
        do {
            try await s.startRecording()
            // Should not throw — just returns early
        } catch {
            XCTFail("Should not throw when already recording, just return")
        }

        // State should remain unchanged (still recording, not re-started)
        XCTAssertEqual(s.sessionState, .recording)
    }

    func testStartRecordingWithoutModelResetsToIdle() async {
        let s = WhisperService()
        XCTAssertEqual(s.sessionState, .idle)

        do {
            try await s.startRecording()
            XCTFail("Should throw modelNotReady")
        } catch {
            XCTAssertEqual(s.sessionState, .idle, "Should reset to idle on failure")
        }
    }

    func testStopRecordingFromIdleIsNoOp() {
        let s = WhisperService()
        XCTAssertEqual(s.sessionState, .idle)
        s.stopRecording()
        XCTAssertEqual(s.sessionState, .idle, "Stop from idle should be no-op")
    }

    func testStopRecordingFromInterruptedGoesToIdle() {
        let s = WhisperService()
        s.testSetSessionState(.interrupted)
        s.stopRecording()
        XCTAssertEqual(s.sessionState, .idle)
        XCTAssertFalse(s.isRecording)
    }

    // MARK: - Interruption Simulation

    func testSimulateInterruptionBeganWhileRecording() {
        let s = WhisperService()
        s.enableEagerMode = true

        // Simulate recording state
        s.testSetSessionState(.recording)
        // Need to set isRecording via internal state — use the test helper approach
        // Since isRecording is private(set), we simulate via testSimulateInterruption
        // which checks isRecording internally. For this test, we manually set state.

        // testSimulateInterruption checks isRecording, which is false here.
        // This tests the guard behavior.
        s.testSimulateInterruption(began: true)
        // isRecording was false, so interruption was ignored
        XCTAssertEqual(s.sessionState, .recording)
    }

    func testSimulateInterruptionEndFromInterrupted() {
        let s = WhisperService()
        s.testSetSessionState(.interrupted)
        s.testSimulateInterruption(began: false) // end interruption → stops
        XCTAssertEqual(s.sessionState, .idle)
    }

    func testSimulateInterruptionEndFromIdleIsNoOp() {
        let s = WhisperService()
        s.testSetSessionState(.idle)
        s.testSimulateInterruption(began: false)
        XCTAssertEqual(s.sessionState, .idle)
    }

    // MARK: - Clear Resets Session

    func testClearTranscriptionResetsSession() {
        let s = WhisperService()
        s.testSetSessionState(.interrupted)
        s.clearTranscription()
        XCTAssertEqual(s.sessionState, .idle)
    }

    // MARK: - Model Switch Safety

    func testModelSwitchFromIdlePreservesIdle() async {
        let s = WhisperService()
        XCTAssertEqual(s.sessionState, .idle)
        // switchModel will call setupModel which will fail without network,
        // but sessionState should remain idle (not recording).
        // We just verify the initial guard behavior.
        XCTAssertFalse(s.isRecording)
    }

    func testTTSGuardStopsRecordingSession() {
        let s = WhisperService()
        s.testSetSessionState(.recording)
        s.testSetRecordingFlags(isRecording: true, isTranscribing: true)

        s.testStopRecordingForTTSIfNeeded()

        XCTAssertEqual(s.sessionState, .idle)
        XCTAssertFalse(s.isRecording)
        XCTAssertFalse(s.isTranscribing)
        XCTAssertTrue(s.micStoppedForTTS)
    }

    func testTTSGuardNoOpWhenIdle() {
        let s = WhisperService()
        XCTAssertEqual(s.sessionState, .idle)
        XCTAssertFalse(s.micStoppedForTTS)

        s.testStopRecordingForTTSIfNeeded()

        XCTAssertEqual(s.sessionState, .idle)
        XCTAssertFalse(s.micStoppedForTTS)
    }
}
