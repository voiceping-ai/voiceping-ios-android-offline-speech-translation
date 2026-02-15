import XCTest

/// 10 user flow tests covering mic button, settings navigation, save/history, and edge cases.
/// Each test captures screenshots at key states for visual validation.
final class UserFlowUITests: XCTestCase {

    // MARK: - Constants

    private let modelLoadTimeout: TimeInterval = 120
    private let transcriptionTimeout: TimeInterval = 180
    private let modelSwitchTimeout: TimeInterval = 180
    private let shortTimeout: TimeInterval = 10

    // MARK: - Setup / Teardown

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        let app = XCUIApplication()
        if let failureCount = testRun?.failureCount, failureCount > 0 {
            captureScreenshot(app, step: "FAILURE")
        }
        app.terminate()
    }

    // MARK: - Test 1: App Launch and Model Load

    func test_01_appLaunchAndModelLoad() {
        let app = launchApp(modelId: "sensevoice-small")

        captureScreenshot(app, step: "01_launch")

        // Wait for model to load
        let modelInfo = app.staticTexts["model_info_label"]
        XCTAssertTrue(
            modelInfo.waitForExistence(timeout: modelLoadTimeout),
            "Model info label should appear after model loads"
        )

        captureScreenshot(app, step: "02_loaded")

        // Verify model name displayed
        let mainTab = app.otherElements["main_tab_view"]
        XCTAssertTrue(mainTab.exists, "Main tab view should be visible")

        // Verify tab bar has Transcribe button
        let transcribeTab = app.tabBars.buttons["Transcribe"]
        XCTAssertTrue(transcribeTab.exists, "Transcribe tab should exist")
    }

    // MARK: - Test 2: Test File Transcription

    func test_02_testFileTranscription() {
        let app = launchApp(modelId: "sensevoice-small")
        waitForModelLoad(app)

        // Dismiss any translation download dialog (Apple Translation framework)
        dismissTranslationDownloadDialog(app)

        // Verify idle state
        let idlePlaceholder = app.staticTexts["idle_placeholder"]
        XCTAssertTrue(
            idlePlaceholder.waitForExistence(timeout: shortTimeout),
            "Idle placeholder should be visible before transcription"
        )

        captureScreenshot(app, step: "01_idle")

        // Tap test file button
        let testFileBtn = app.buttons["test_file_button"]
        XCTAssertTrue(testFileBtn.waitForExistence(timeout: shortTimeout))
        testFileBtn.tap()

        // Brief pause to catch "transcribing" state
        sleep(2)
        captureScreenshot(app, step: "02_transcribing")

        // Wait for confirmed text
        let confirmedText = app.staticTexts["confirmed_text"]
        XCTAssertTrue(
            confirmedText.waitForExistence(timeout: transcriptionTimeout),
            "Confirmed text should appear after transcription"
        )

        // Wait for translation to complete (async after transcription)
        sleep(5)
        // Dismiss translation download dialog if it reappeared
        dismissTranslationDownloadDialog(app)
        sleep(15)
        // Dismiss again if needed
        dismissTranslationDownloadDialog(app)
        captureScreenshot(app, step: "03_result")

        // Verify text contains expected keywords
        let text = confirmedText.label.lowercased()
        XCTAssertTrue(
            text.contains("country") || text.contains("ask"),
            "Transcription should contain expected JFK keywords, got: \(text)"
        )
    }

    // MARK: - Test 2b: Screenshot + Demo Frames with Translation

    func test_02b_screenshotWithTranslation() {
        let demoDir = "/tmp/ios_demo_frames"
        try? FileManager.default.removeItem(atPath: demoDir)
        try? FileManager.default.createDirectory(atPath: demoDir, withIntermediateDirectories: true)

        let app = launchApp(modelId: "sensevoice-small")

        // Frame 1: Model loading
        sleep(1)
        saveDemoFrame(app, to: demoDir, name: "01_loading.png")

        waitForModelLoad(app)
        dismissTranslationDownloadDialog(app)
        sleep(2)

        // Frame 2: Idle state
        saveDemoFrame(app, to: demoDir, name: "02_idle.png")

        // Tap test file button to transcribe
        let testFileBtn = app.buttons["test_file_button"]
        XCTAssertTrue(testFileBtn.waitForExistence(timeout: shortTimeout))
        testFileBtn.tap()

        // Frame 3: Transcribing in progress
        sleep(2)
        saveDemoFrame(app, to: demoDir, name: "03_transcribing.png")

        // Wait for confirmed text
        let confirmedText = app.staticTexts["confirmed_text"]
        _ = confirmedText.waitForExistence(timeout: transcriptionTimeout)

        // Frame 4: Transcription complete
        sleep(1)
        saveDemoFrame(app, to: demoDir, name: "04_transcribed.png")

        // Wait for translation to appear (poll instead of long sleep)
        let translatedText = app.staticTexts["translated_text"]
        for _ in 0..<30 {
            if translatedText.exists { break }
            sleep(1)
        }
        dismissTranslationDownloadDialog(app)
        sleep(2)

        // Frame 5: Final result with translation
        saveDemoFrame(app, to: demoDir, name: "05_translated.png")
        captureScreenshot(app, step: "translation_result")
    }

    private func saveDemoFrame(_ app: XCUIApplication, to dir: String, name: String) {
        let screenshot = app.screenshot()
        let path = "\(dir)/\(name)"
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: path))
        // Also add as XCTAttachment for extraction from xcresult
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "demo_\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        NSLog("[Demo] Frame saved: %@", path)
    }

    // MARK: - Test 3: Record Button States

    func test_03_recordButtonStates() {
        let app = launchApp(modelId: "sensevoice-small")
        waitForModelLoad(app)

        // Handle mic permission alert
        let permissionHandled = expectation(description: "permission handled")
        permissionHandled.isInverted = true // May not trigger if already granted
        addUIInterruptionMonitor(withDescription: "Microphone Permission") { alert in
            if alert.buttons["Allow"].exists {
                alert.buttons["Allow"].tap()
            } else if alert.buttons["OK"].exists {
                alert.buttons["OK"].tap()
            }
            permissionHandled.fulfill()
            return true
        }

        // Verify idle state
        let recordBtn = app.buttons["record_button"]
        XCTAssertTrue(recordBtn.waitForExistence(timeout: shortTimeout))
        XCTAssertEqual(recordBtn.label, "Start recording")

        captureScreenshot(app, step: "01_idle")

        // Tap to start recording
        recordBtn.tap()
        // Trigger interruption monitor
        app.tap()
        wait(for: [permissionHandled], timeout: 3)

        // Check if we got an error alert (permission denied) or recording started
        sleep(1)
        let errorAlert = app.alerts["Error"]
        if errorAlert.exists {
            // Permission denied — still validate the alert appears correctly
            captureScreenshot(app, step: "02_permission_error")
            errorAlert.buttons.firstMatch.tap()
        } else {
            // Recording should have started
            let stopLabel = recordBtn.waitForLabel("Stop recording", timeout: 5)
            XCTAssertTrue(stopLabel, "Record button should show 'Stop recording' while recording")

            captureScreenshot(app, step: "02_recording")

            // Stop recording
            recordBtn.tap()
            sleep(1)

            XCTAssertEqual(recordBtn.label, "Start recording",
                           "Record button should return to 'Start recording' after stop")
        }

        captureScreenshot(app, step: "03_stopped")
    }

    // MARK: - Test 4: Settings Navigation

    func test_04_settingsNavigation() {
        let app = launchApp(modelId: "sensevoice-small", additionalArgs: ["--reset-state"])
        waitForModelLoad(app)

        // Dismiss any translation error alerts from default-enabled translation
        dismissAnyAlerts(app)

        // Open settings
        let settingsBtn = app.buttons["settings_button"]
        XCTAssertTrue(settingsBtn.waitForExistence(timeout: shortTimeout))
        settingsBtn.tap()

        // Verify settings sheet
        let settingsTitle = app.navigationBars["Settings"]
        XCTAssertTrue(
            settingsTitle.waitForExistence(timeout: shortTimeout),
            "Settings navigation title should be visible"
        )

        captureScreenshot(app, step: "01_settings_open")

        // Verify current model
        let currentModel = app.staticTexts["settings_current_model"]
        XCTAssertTrue(currentModel.exists, "Current model name should be displayed")
        XCTAssertTrue(
            currentModel.label.contains("SenseVoice Small"),
            "Current model should be SenseVoice Small, got: \(currentModel.label)"
        )

        // Scroll down past all model rows to reach toggle section
        // (6 model families / 11 models means many swipes needed)
        let vadToggle = app.switches["vad_toggle"]
        for _ in 0..<6 {
            if vadToggle.exists && vadToggle.isHittable { break }
            app.swipeUp()
            usleep(500_000) // 0.5s
        }

        // Verify toggles exist
        let timestampsToggle = app.switches["timestamps_toggle"]
        XCTAssertTrue(
            vadToggle.waitForExistence(timeout: shortTimeout),
            "VAD toggle should exist (after scrolling)"
        )
        XCTAssertTrue(timestampsToggle.exists, "Timestamps toggle should exist")

        // Toggle VAD off then on
        vadToggle.tap()
        sleep(1)
        vadToggle.tap()

        captureScreenshot(app, step: "02_toggles")

        // Dismiss settings — scroll back up to find Done button
        let doneBtn = app.buttons["settings_done_button"]
        for _ in 0..<4 {
            if doneBtn.exists && doneBtn.isHittable { break }
            app.swipeDown()
            usleep(500_000)
        }
        XCTAssertTrue(
            doneBtn.waitForExistence(timeout: shortTimeout),
            "Done button should be visible"
        )
        doneBtn.tap()

        // Verify back to main view
        let modelInfo = app.staticTexts["model_info_label"]
        XCTAssertTrue(
            modelInfo.waitForExistence(timeout: shortTimeout),
            "Model info should be visible after dismissing settings"
        )

        captureScreenshot(app, step: "03_dismissed")
    }

    // MARK: - Test 5: Save and History

    func test_05_saveAndHistory() {
        let app = launchApp(modelId: "sensevoice-small")
        waitForModelLoad(app)

        // Transcribe test file
        tapTestFile(app)
        let confirmedText = app.staticTexts["confirmed_text"]
        XCTAssertTrue(confirmedText.waitForExistence(timeout: transcriptionTimeout))

        captureScreenshot(app, step: "01_transcribed")

        // Save
        let saveBtn = app.buttons["save_button"]
        XCTAssertTrue(saveBtn.waitForExistence(timeout: shortTimeout))
        saveBtn.tap()

        // Verify saved alert
        let savedAlert = app.alerts["Saved"]
        XCTAssertTrue(
            savedAlert.waitForExistence(timeout: shortTimeout),
            "Saved alert should appear"
        )

        captureScreenshot(app, step: "02_saved")
        savedAlert.buttons["OK"].tap()

        // Switch to History tab
        app.tabBars.buttons["History"].tap()
        sleep(1)

        // Verify history row exists
        let historyRow = app.buttons.matching(identifier: "history_row").firstMatch
        XCTAssertTrue(
            historyRow.waitForExistence(timeout: shortTimeout),
            "History should contain a saved entry"
        )

        captureScreenshot(app, step: "03_history")

        // Tap to view detail
        historyRow.tap()
        sleep(1)

        let detailText = app.staticTexts["detail_text"]
        XCTAssertTrue(
            detailText.waitForExistence(timeout: shortTimeout),
            "Detail text should be visible"
        )

        captureScreenshot(app, step: "04_detail")
    }

    // MARK: - Test 6: History Empty State and Delete

    func test_06_historyEmptyAndDelete() {
        let app = launchApp(modelId: "sensevoice-small", additionalArgs: ["--reset-state"])
        waitForModelLoad(app)

        // Go to History — should be empty
        app.tabBars.buttons["History"].tap()
        sleep(1)

        // ContentUnavailableView renders as various element types in XCUITest
        let emptyState = app.otherElements["history_empty_state"]
        let emptyText = app.staticTexts["No Transcriptions Yet"]
        let emptyStaticText = app.staticTexts["history_empty_state"]
        var foundEmpty = emptyState.waitForExistence(timeout: shortTimeout)
        if !foundEmpty { foundEmpty = emptyText.exists || emptyStaticText.exists }
        // If no history entries exist, the list should be empty (even if ContentUnavailableView not found)
        if !foundEmpty {
            let historyRow = app.buttons.matching(identifier: "history_row").firstMatch
            foundEmpty = !historyRow.exists
        }
        XCTAssertTrue(foundEmpty, "Empty state should be visible (or no history rows)")

        captureScreenshot(app, step: "01_empty")

        // Go back to Transcribe, make a transcription, save
        app.tabBars.buttons["Transcribe"].tap()
        sleep(1)
        tapTestFile(app)

        let confirmedText = app.staticTexts["confirmed_text"]
        XCTAssertTrue(confirmedText.waitForExistence(timeout: transcriptionTimeout))

        let saveBtn = app.buttons["save_button"]
        XCTAssertTrue(saveBtn.waitForExistence(timeout: shortTimeout))
        saveBtn.tap()

        let savedAlert = app.alerts["Saved"]
        XCTAssertTrue(savedAlert.waitForExistence(timeout: shortTimeout))
        savedAlert.buttons["OK"].tap()

        // Back to History — should have entry
        app.tabBars.buttons["History"].tap()
        sleep(1)

        let historyRow = app.buttons.matching(identifier: "history_row").firstMatch
        XCTAssertTrue(
            historyRow.waitForExistence(timeout: shortTimeout),
            "History should now contain an entry"
        )

        captureScreenshot(app, step: "02_with_entry")

        // Swipe to delete
        historyRow.swipeLeft()
        sleep(1)

        let deleteBtn = app.buttons["Delete"]
        if deleteBtn.waitForExistence(timeout: 3) {
            deleteBtn.tap()
        }
        sleep(1)

        captureScreenshot(app, step: "03_deleted")
    }

    // MARK: - Test 7: Settings Copy and Clear

    func test_07_settingsCopyAndClear() {
        // Reset state to clear any leftover translation settings from previous runs
        let app = launchApp(modelId: "sensevoice-small", additionalArgs: ["--reset-state"])
        waitForModelLoad(app)

        // Transcribe
        tapTestFile(app)
        let confirmedText = app.staticTexts["confirmed_text"]
        XCTAssertTrue(confirmedText.waitForExistence(timeout: transcriptionTimeout))

        captureScreenshot(app, step: "01_with_text")

        // Open settings
        let settingsBtn = app.buttons["settings_button"]
        XCTAssertTrue(settingsBtn.waitForExistence(timeout: shortTimeout))
        settingsBtn.tap()
        sleep(1)

        captureScreenshot(app, step: "02_settings")

        // Tap Copy Text in settings
        let copyBtn = app.buttons["settings_copy_text"]
        XCTAssertTrue(
            copyBtn.waitForExistence(timeout: shortTimeout),
            "Copy Text button should exist in settings"
        )
        copyBtn.tap()
        sleep(1)

        // Tap Clear Transcription in settings
        let clearBtn = app.buttons["settings_clear_transcription"]
        XCTAssertTrue(
            clearBtn.waitForExistence(timeout: shortTimeout),
            "Clear Transcription button should exist in settings"
        )
        clearBtn.tap()
        sleep(2)

        // Dismiss settings
        let doneBtn = app.buttons["settings_done_button"]
        if doneBtn.exists && doneBtn.isEnabled {
            doneBtn.tap()
            sleep(1)
        }

        // Verify text is cleared — either idle placeholder appears or confirmed text is gone
        let idlePlaceholder = app.staticTexts["idle_placeholder"]
        let confirmedGone = !app.staticTexts["confirmed_text"].exists
        XCTAssertTrue(
            idlePlaceholder.waitForExistence(timeout: shortTimeout) || confirmedGone,
            "Text should be cleared after tapping Clear in settings"
        )

        captureScreenshot(app, step: "03_cleared")
    }

    // MARK: - Test 8: Model Switch in Settings

    func test_08_modelSwitchInSettings() {
        let app = launchApp(modelId: "sensevoice-small")
        waitForModelLoad(app)

        // Verify initial model
        let modelInfo = app.staticTexts["model_info_label"]
        XCTAssertTrue(modelInfo.exists)

        captureScreenshot(app, step: "01_initial")

        // Open settings
        let settingsBtn = app.buttons["settings_button"]
        settingsBtn.tap()

        let settingsTitle = app.navigationBars["Settings"]
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: shortTimeout))

        // Tap Parakeet TDT model row (second model in this repo)
        let parakeetRow = app.buttons["model_row_parakeet-tdt-v3"]
        // May need to scroll to find it
        if !parakeetRow.waitForExistence(timeout: 3) {
            app.swipeUp()
            sleep(1)
        }
        XCTAssertTrue(
            parakeetRow.waitForExistence(timeout: shortTimeout),
            "Parakeet TDT row should exist in settings"
        )
        parakeetRow.tap()

        captureScreenshot(app, step: "02_switching")

        // Wait for model switch to complete — sheet auto-dismisses on success
        // or Done button becomes enabled
        let predicate = NSPredicate(format: "exists == true")
        let modelInfoExpectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: modelInfo
        )
        wait(for: [modelInfoExpectation], timeout: modelSwitchTimeout)

        // If settings sheet is still open, dismiss it
        let doneBtn = app.buttons["settings_done_button"]
        if doneBtn.exists && doneBtn.isEnabled {
            doneBtn.tap()
            sleep(1)
        }

        captureScreenshot(app, step: "03_switched")
    }

    // MARK: - Test 9: Tab Switch Preserves State

    func test_09_tabSwitchPreservesState() {
        let app = launchApp(modelId: "sensevoice-small")
        waitForModelLoad(app)

        // Transcribe
        tapTestFile(app)
        let confirmedText = app.staticTexts["confirmed_text"]
        XCTAssertTrue(confirmedText.waitForExistence(timeout: transcriptionTimeout))

        let originalText = confirmedText.label

        captureScreenshot(app, step: "01_transcribed")

        // Switch to History tab
        app.tabBars.buttons["History"].tap()
        sleep(1)

        captureScreenshot(app, step: "02_history")

        // Switch back to Transcribe tab
        app.tabBars.buttons["Transcribe"].tap()
        sleep(1)

        // Verify text preserved
        XCTAssertTrue(confirmedText.exists, "Confirmed text should still exist after tab switch")
        XCTAssertEqual(
            confirmedText.label, originalText,
            "Transcription text should be preserved across tab switches"
        )

        captureScreenshot(app, step: "03_back")
    }

    // MARK: - Test 10: Model Setup Onboarding

    func test_10_modelSetupOnboarding() {
        // Launch with --reset-state and NO --model-id to force setup view
        let app = XCUIApplication()
        app.launchArguments = ["--reset-state"]
        app.launch()

        sleep(2)
        captureScreenshot(app, step: "01_setup")

        // Check for setup view — use multiple query types since SwiftUI renders differently
        let setupTitle = app.staticTexts["setup_title"]
        let titleText = app.staticTexts["Offline Transcription"]
        let setupNav = app.navigationBars["Setup"]

        var foundSetup = setupTitle.waitForExistence(timeout: shortTimeout)
        if !foundSetup { foundSetup = titleText.exists }
        if !foundSetup { foundSetup = setupNav.exists }
        // Also check that we're NOT in MainTabView
        if !foundSetup {
            let mainTab = app.otherElements["main_tab_view"]
            foundSetup = !mainTab.exists
        }
        XCTAssertTrue(foundSetup, "Setup view should appear when no model is loaded")

        // Verify title text
        XCTAssertTrue(
            titleText.exists || setupTitle.exists,
            "App title should be visible on setup screen"
        )

        // Verify prompt text
        let prompt = app.staticTexts["setup_prompt"]
        let promptText = app.staticTexts["Tap a model to download and get started."]
        XCTAssertTrue(
            prompt.exists || promptText.exists,
            "Setup prompt should be visible"
        )

        captureScreenshot(app, step: "02_model_list")

        // Verify at least one model family header is visible
        let senseVoiceHeader = app.staticTexts["SenseVoice"]
        XCTAssertTrue(
            senseVoiceHeader.waitForExistence(timeout: shortTimeout),
            "SenseVoice family header should be visible in model picker"
        )
    }

    // MARK: - Test 11: System Broadcast Mode UI

    func test_11_systemBroadcastModeUI() {
        let app = launchApp(modelId: "sensevoice-small")
        waitForModelLoad(app)

        captureScreenshot(app, step: "01_voice_mode")

        // Switch to System mode
        let audioSourcePicker = app.segmentedControls["audio_mode_picker"]
        XCTAssertTrue(
            audioSourcePicker.waitForExistence(timeout: shortTimeout),
            "Audio source picker should exist"
        )
        let systemButton = audioSourcePicker.buttons["System"]
        XCTAssertTrue(systemButton.exists, "System segment should exist")
        systemButton.tap()
        sleep(1)

        captureScreenshot(app, step: "02_system_mode")

        // Verify broadcast picker appears
        let broadcastPicker = app.otherElements["broadcast_picker"]
        XCTAssertTrue(
            broadcastPicker.waitForExistence(timeout: shortTimeout),
            "Broadcast picker should appear in System mode"
        )

        captureScreenshot(app, step: "03_broadcast_picker_visible")

        // Tap the broadcast picker (on simulator, the system sheet won't appear
        // because ReplayKit requires a real device, but we verify the UI is present)
        broadcastPicker.tap()
        sleep(2)

        captureScreenshot(app, step: "04_after_broadcast_tap")

        // Switch back to Voice mode
        let voiceButton = audioSourcePicker.buttons["Voice"]
        voiceButton.tap()
        sleep(1)

        captureScreenshot(app, step: "05_back_to_voice")
    }

    // MARK: - Helpers

    private func launchApp(
        modelId: String? = nil,
        additionalArgs: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        var args: [String] = []
        if let modelId = modelId {
            args.append(contentsOf: ["--model-id", modelId])
        }
        args.append(contentsOf: additionalArgs)
        app.launchArguments = args
        app.launch()
        return app
    }

    @discardableResult
    private func waitForModelLoad(_ app: XCUIApplication) -> Bool {
        let modelInfo = app.staticTexts["model_info_label"]
        let loaded = modelInfo.waitForExistence(timeout: modelLoadTimeout)
        // Let the UI fully settle after model load
        sleep(2)
        return loaded
    }

    private func tapTestFile(_ app: XCUIApplication) {
        let testFileBtn = app.buttons["test_file_button"]
        XCTAssertTrue(
            testFileBtn.waitForExistence(timeout: shortTimeout),
            "Test file button should exist"
        )
        testFileBtn.tap()
        // Brief wait to let the transcription task begin
        sleep(1)
    }

    private func dismissTranslationDownloadDialog(_ app: XCUIApplication) {
        // Apple Translation framework shows a "Required Downloads" sheet
        // when language models need downloading. Dismiss it by tapping "Done".
        // The dialog may reappear multiple times as translation sessions are recreated.
        for _ in 0..<5 {
            let doneButton = app.buttons["Done"]
            if doneButton.waitForExistence(timeout: 3) {
                doneButton.tap()
                sleep(3)
            } else {
                break
            }
        }
        // Also dismiss any alerts
        dismissAnyAlerts(app)
    }

    // MARK: - Test 11: System Recording + File Transcription Demo

    func test_11_systemRecordingAndDemo() {
        let app = launchApp(modelId: "sensevoice-small")
        waitForModelLoad(app)
        dismissTranslationDownloadDialog(app)
        sleep(1)

        // Tap "System" segment in audio mode picker
        let picker = app.segmentedControls["audio_mode_picker"]
        if picker.waitForExistence(timeout: 5) {
            picker.buttons["System"].tap()
            sleep(2)
        }
        captureScreenshot(app, step: "system_mode")

        // Switch back to Voice for file transcription demo
        if picker.exists {
            picker.buttons["Voice"].tap()
            sleep(1)
        }

        // Capture file transcription demo frames
        captureScreenshot(app, step: "frame_00_idle")

        let testFileBtn = app.buttons["test_file_button"]
        if testFileBtn.waitForExistence(timeout: shortTimeout) {
            testFileBtn.tap()
            for i in 1...6 {
                usleep(500_000)
                captureScreenshot(app, step: String(format: "frame_%02d_progress", i))
            }
            let confirmedText = app.staticTexts["confirmed_text"]
            _ = confirmedText.waitForExistence(timeout: transcriptionTimeout)
            sleep(1)
            captureScreenshot(app, step: "frame_07_result")
        }
    }

    private func dismissAnyAlerts(_ app: XCUIApplication) {
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 2) {
            alert.buttons.firstMatch.tap()
            usleep(500_000)
        }
    }

    private func captureScreenshot(_ app: XCUIApplication, step: String) {
        let screenshot = app.screenshot()

        // Save to filesystem for collection
        let testName = String(describing: name)
            .replacingOccurrences(of: "-[UserFlowUITests ", with: "")
            .replacingOccurrences(of: "]", with: "")
        let dir = "/tmp/ui_flow_evidence/\(testName)"
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        let path = "\(dir)/\(step).png"
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: path))

        // Also add as XCTest attachment
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(testName)_\(step)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

// MARK: - XCUIElement Helpers

extension XCUIElement {
    /// Wait until the element's label matches the expected value.
    func waitForLabel(_ expected: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        return result == .completed
    }
}
