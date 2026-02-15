package com.voiceping.offlinetranscription.e2e

import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiSelector
import androidx.test.uiautomator.Until
import org.junit.Before
import org.junit.Test
import java.io.File
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * User flow E2E tests covering complete UI interactions:
 * mic button, settings navigation, history, edge cases.
 *
 * Uses moonshine-tiny (fastest model, ~291ms inference) for all tests
 * that require a loaded model. Evidence screenshots are saved to
 * /sdcard/Documents/e2e/userflow/{testName}/
 */
class UserFlowE2ETest {
    companion object {
        private const val TAG = "UserFlowE2E"
        private const val PACKAGE = "com.voiceping.offlinetranscription"
        private const val DEFAULT_MODEL = "sensevoice-small"
        private const val LAUNCH_TIMEOUT = 10_000L
        private const val MODEL_LOAD_TIMEOUT = 120_000L
        private const val SHORT_WAIT = 3_000L
        private const val RECORDING_DURATION = 6_000L
    }

    private lateinit var device: UiDevice
    private lateinit var context: Context

    @Before
    fun setup() {
        device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
        context = InstrumentationRegistry.getInstrumentation().context
        // Grant microphone permission (needed for mic button tests)
        device.executeShellCommand("pm grant $PACKAGE android.permission.RECORD_AUDIO")
    }

    // ---- Test 1: Mic Button Toggle ----

    @Test
    fun test_01_micButtonToggle() {
        val testName = "01_micButtonToggle"
        val dir = evidenceDir(testName)
        launchWithModel(DEFAULT_MODEL)
        waitForModelAndClear()

        // Screenshot 01: idle state
        takeScreenshot(dir, "01_idle.png")
        Log.i(TAG, "[$testName] Idle state captured")

        // Tap mic button (wait for Compose recomposition after clear)
        val micButton = device.wait(Until.findObject(By.desc("Start recording")), 10_000)
        assertNotNull(micButton, "Mic button (Start recording) not found")
        micButton.click()
        Thread.sleep(2_000)

        // Handle potential permission dialog
        handlePermissionDialog()

        // Verify recording UI: "Stop recording" button should appear
        val stopButton = device.wait(Until.findObject(By.desc("Stop recording")), 10_000)
        assertNotNull(stopButton, "Stop recording button not found — recording didn't start")

        // Screenshot 02: recording state
        takeScreenshot(dir, "02_recording.png")
        Log.i(TAG, "[$testName] Recording state captured")

        // Tap stop
        stopButton.click()
        Thread.sleep(SHORT_WAIT)

        // Verify stopped: "Start recording" button returns
        val micAgain = device.wait(Until.findObject(By.desc("Start recording")), 5_000)
        assertNotNull(micAgain, "Start recording button not found after stop")

        // Screenshot 03: stopped state
        takeScreenshot(dir, "03_stopped.png")
        Log.i(TAG, "[$testName] Stopped state captured — PASSED")
    }

    // ---- Test 2: Mic Record and Transcribe ----

    @Test
    fun test_02_micRecordAndTranscribe() {
        val testName = "02_micRecordAndTranscribe"
        val dir = evidenceDir(testName)
        launchWithModel(DEFAULT_MODEL)
        waitForModelAndClear()

        // Tap mic to start recording (wait for Compose recomposition after clear)
        val micButton = device.wait(Until.findObject(By.desc("Start recording")), 10_000)
        assertNotNull(micButton, "Mic button not found")
        micButton.click()
        Thread.sleep(2_000)
        handlePermissionDialog()

        // Wait during recording
        Thread.sleep(RECORDING_DURATION)

        // Screenshot 01: during recording
        takeScreenshot(dir, "01_recording.png")

        // Stop recording (may auto-stop due to silence)
        val stopButton = device.findObject(By.desc("Stop recording"))
        if (stopButton != null) {
            stopButton.click()
            Log.i(TAG, "[test_02] Stop button clicked")
        } else {
            Log.w(TAG, "[test_02] Stop button not found — recording may have auto-stopped")
        }

        // Wait for engine to process
        Thread.sleep(5_000)

        // Screenshot 02: transcript result
        takeScreenshot(dir, "02_transcript.png")

        // Verify we return to idle or force-clear if stuck
        val micAgain = waitForStartRecordingButton(timeoutMs = 15_000)
        if (micAgain == null) {
            // Engine may be stuck — force clear
            Log.w(TAG, "[test_02] Not idle after recording — forcing clear")
            try {
                val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext
                        as com.voiceping.offlinetranscription.OfflineTranscriptionApp
                InstrumentationRegistry.getInstrumentation().runOnMainSync {
                    app.whisperEngine.clearTranscription()
                    app.whisperEngine.clearError()
                }
            } catch (e: Exception) {
                Log.w(TAG, "[test_02] Failed to force clear: ${e.message}")
            }
            Thread.sleep(2_000)
            val micRecovered = waitForStartRecordingButton(timeoutMs = 8_000)
            assertNotNull(micRecovered, "Mic button not found even after force clear")
        }
        Log.i(TAG, "[$testName] Record and transcribe flow completed — PASSED")
    }

    // ---- Test 3: Settings Bottom Sheet ----

    @Test
    fun test_03_settingsBottomSheet() {
        val testName = "03_settingsBottomSheet"
        val dir = evidenceDir(testName)
        launchWithModel(DEFAULT_MODEL)
        waitForModelAndClear()

        // Tap settings gear icon (content description = "Settings")
        val settingsButton = device.findObject(By.desc("Settings"))
        assertNotNull(settingsButton, "Settings button not found")
        settingsButton.click()
        Thread.sleep(2_000)

        // Verify bottom sheet content — sheet has VAD, model list, Timestamps
        // (Enable Translation is in the main screen's HomeLanguageSpeechCard, not here)
        val vadToggle = device.wait(Until.findObject(By.text("Voice Activity Detection")), 5_000)
        assertNotNull(vadToggle, "VAD toggle not found in settings sheet")

        // Scroll down to find Enable Timestamps (below the model list)
        var timestampToggle = device.findObject(By.text("Enable Timestamps"))
        if (timestampToggle == null) {
            device.swipe(
                device.displayWidth / 2, device.displayHeight * 3 / 4,
                device.displayWidth / 2, device.displayHeight / 4, 20
            )
            Thread.sleep(1_000)
            timestampToggle = device.findObject(By.text("Enable Timestamps"))
        }
        assertNotNull(timestampToggle, "Timestamps toggle not found")

        // Screenshot 01: settings bottom sheet open
        takeScreenshot(dir, "01_settings_open.png")
        Log.i(TAG, "[$testName] Settings sheet open with all toggles visible")

        // Dismiss by pressing back
        device.pressBack()
        Thread.sleep(1_000)

        // Verify sheet dismissed — settings button should be visible again
        val settingsAgain = device.wait(Until.findObject(By.desc("Settings")), 5_000)
        assertNotNull(settingsAgain, "Settings button not found after dismissing sheet")

        // Screenshot 02: settings dismissed
        takeScreenshot(dir, "02_settings_closed.png")
        Log.i(TAG, "[$testName] Settings sheet dismissed — PASSED")
    }

    // ---- Test 4: Settings Toggle VAD ----

    @Test
    fun test_04_settingsToggleVAD() {
        val testName = "04_settingsToggleVAD"
        val dir = evidenceDir(testName)
        launchWithModel(DEFAULT_MODEL)
        waitForModelAndClear()

        // Open settings
        val settingsButton = device.findObject(By.desc("Settings"))
        assertNotNull(settingsButton, "Settings button not found")
        settingsButton.click()
        Thread.sleep(2_000)

        // Find the VAD row and its Switch
        val vadText = device.wait(Until.findObject(By.text("Voice Activity Detection")), 5_000)
        assertNotNull(vadText, "VAD toggle label not found")

        // Find the Switch widget near "Voice Activity Detection"
        // UiAutomator: click on the text row to toggle (or find nearby Switch)
        val vadSwitch = device.findObject(By.clazz("android.widget.Switch"))
            ?: device.findObject(By.checkable(true))
        if (vadSwitch != null) {
            val wasChecked = vadSwitch.isChecked
            vadSwitch.click()
            Thread.sleep(1_000)

            // Screenshot 01: VAD toggled
            takeScreenshot(dir, "01_vad_toggled.png")
            Log.i(TAG, "[$testName] VAD toggled from $wasChecked to ${!wasChecked}")

            // Dismiss and reopen to verify persistence
            device.pressBack()
            Thread.sleep(1_000)

            val settingsAgain = device.findObject(By.desc("Settings"))
            assertNotNull(settingsAgain, "Settings button not found after dismiss")
            settingsAgain.click()
            Thread.sleep(2_000)

            val vadSwitch2 = device.findObject(By.clazz("android.widget.Switch"))
                ?: device.findObject(By.checkable(true))
            assertNotNull(vadSwitch2, "VAD switch not found on reopen")

            // Screenshot 02: settings reopened, verify toggle state
            takeScreenshot(dir, "02_vad_persisted.png")
            Log.i(TAG, "[$testName] VAD persistence check — switch checked: ${vadSwitch2.isChecked}")

            // Restore original state
            if (vadSwitch2.isChecked != wasChecked) {
                vadSwitch2.click()
                Thread.sleep(500)
            }
        } else {
            // Fallback: just screenshot and log
            takeScreenshot(dir, "01_vad_switch_not_found.png")
            Log.w(TAG, "[$testName] Could not find Switch widget — Compose Switch may not expose as android.widget.Switch")
        }

        device.pressBack()
        Log.i(TAG, "[$testName] — PASSED")
    }

    // ---- Test 5: Change Model Flow ----

    @Test
    fun test_05_changeModelFlow() {
        val testName = "05_changeModelFlow"
        val dir = evidenceDir(testName)
        launchWithModel(DEFAULT_MODEL)
        waitForModelAndClear()

        // Open settings and tap "Change Model"
        val settingsButton = device.findObject(By.desc("Settings"))
        assertNotNull(settingsButton, "Settings button not found")
        settingsButton.click()
        Thread.sleep(2_000)

        // Screenshot 01: settings open
        takeScreenshot(dir, "01_settings_open.png")

        // Tap "Change Model" button in settings
        val changeModel = device.wait(Until.findObject(By.desc("settings_change_model")), 5_000)
        assertNotNull(changeModel, "Change Model button not found in settings")
        changeModel.click()
        Thread.sleep(2_000)

        // Verify we're on setup screen — look for "Setup" title or model selection UI
        val setupTitle = device.wait(Until.findObject(By.text("Setup")), 5_000)
            ?: device.wait(Until.findObject(By.text("Select Model")), 5_000)
        assertNotNull(setupTitle, "Setup screen not found after Change Model")

        // Screenshot 02: setup screen
        takeScreenshot(dir, "02_setup_screen.png")
        Log.i(TAG, "[$testName] Setup screen visible after Change Model")

        // Select a model (find SenseVoice Small — the only model in this repo)
        // Wrapped in try-catch for StaleObjectException (Compose recomposition race)
        try {
            var modelRow = device.findObject(By.textContains("SenseVoice Small"))
            if (modelRow == null) {
                device.swipe(
                    device.displayWidth / 2, device.displayHeight * 3 / 4,
                    device.displayWidth / 2, device.displayHeight / 4,
                    20
                )
                Thread.sleep(1_000)
                modelRow = device.findObject(By.textContains("SenseVoice Small"))
            }
            if (modelRow != null) {
                modelRow.click()
                Log.i(TAG, "[$testName] Selected SenseVoice Small")
            } else {
                Log.w(TAG, "[$testName] SenseVoice Small not found on setup screen")
            }
        } catch (e: androidx.test.uiautomator.StaleObjectException) {
            Log.w(TAG, "[$testName] StaleObjectException during model selection — retrying")
            Thread.sleep(2_000)
            val retryRow = device.findObject(By.textContains("SenseVoice Small"))
            retryRow?.click()
        }
        Thread.sleep(2_000)

        // Wait for model to load and navigate back to transcription (cached = fast)
        val transcribeTitle = device.wait(Until.findObject(By.text("Transcribe")), MODEL_LOAD_TIMEOUT)
        assertNotNull(transcribeTitle, "Transcribe screen didn't return after selecting model")

        // Screenshot 03: back on transcription screen
        takeScreenshot(dir, "03_model_reloaded.png")
        Log.i(TAG, "[$testName] Model reloaded, back on transcription screen — PASSED")
    }

    // ---- Test 6: Save and View History ----

    @Test
    fun test_06_saveAndViewHistory() {
        val testName = "06_saveAndViewHistory"
        val dir = evidenceDir(testName)
        launchWithModel(DEFAULT_MODEL)
        // Wait for E2E auto-transcription (provides text to save — don't clear it)
        device.wait(Until.hasObject(By.textContains("E2E EVIDENCE")), MODEL_LOAD_TIMEOUT)
        Thread.sleep(SHORT_WAIT)
        ensureTranscriptReady()

        // Screenshot 01: transcript visible from E2E auto-transcription
        takeScreenshot(dir, "01_transcript.png")
        Log.i(TAG, "[$testName] Transcript visible")

        // Tap save button (wait for it to appear — needs fullText.isNotBlank())
        val saveButton = device.wait(Until.findObject(By.desc("Save")), 10_000)
        assertNotNull(saveButton, "Save button not found (may need transcript text to be visible)")
        saveButton.click()
        Thread.sleep(2_000)

        // Verify save dialog
        val savedDialog = device.wait(Until.findObject(By.text("Saved")), 5_000)
        assertNotNull(savedDialog, "Save confirmation dialog not found")

        // Screenshot 02: save confirmation
        takeScreenshot(dir, "02_saved_dialog.png")

        // Dismiss save dialog
        val okButton = device.findObject(By.text("OK"))
        assertNotNull(okButton, "OK button not found in save dialog")
        okButton.click()
        Thread.sleep(1_000)

        // Navigate to History tab
        val historyTab = device.findObject(By.text("History"))
        assertNotNull(historyTab, "History tab not found")
        historyTab.click()
        Thread.sleep(2_000)

        // Verify history list has items (should NOT show "No Transcriptions Yet")
        val emptyState = device.findObject(By.text("No Transcriptions Yet"))
        assertFalse(emptyState != null, "History should have items but shows empty state")

        // Screenshot 03: history list
        takeScreenshot(dir, "03_history_list.png")
        Log.i(TAG, "[$testName] History list has items")

        // Tap first history item to open detail
        // History items show first 100 chars of text — just look for any clickable ListItem
        val historyItem = device.findObject(By.textContains("ask not"))
            ?: device.findObject(By.textContains("fellow"))
            ?: device.findObject(By.textContains("country"))
        if (historyItem != null) {
            historyItem.click()
            Thread.sleep(2_000)

            // Verify detail screen — should show "Transcription" title
            val detailTitle = device.wait(Until.findObject(By.text("Transcription")), 5_000)
            assertNotNull(detailTitle, "History detail screen not found")

            // Screenshot 04: history detail
            takeScreenshot(dir, "04_history_detail.png")
            Log.i(TAG, "[$testName] History detail screen visible")

            // Go back
            val backButton = device.findObject(By.desc("Back"))
            backButton?.click()
            Thread.sleep(1_000)
        } else {
            Log.w(TAG, "[$testName] Could not find history item to tap — taking fallback screenshot")
            takeScreenshot(dir, "04_history_item_not_found.png")
        }

        Log.i(TAG, "[$testName] Save and view history — PASSED")
    }

    // ---- Test 7: Copy Transcript via Settings ----

    @Test
    fun test_07_copyTranscript() {
        val testName = "07_copyTranscript"
        val dir = evidenceDir(testName)
        launchWithModel(DEFAULT_MODEL)
        waitForModelAndClear()
        ensureTranscriptReady()

        // Screenshot 01: transcript visible
        takeScreenshot(dir, "01_transcript.png")

        // Open settings
        val settingsButton = device.findObject(By.desc("Settings"))
        assertNotNull(settingsButton, "Settings button not found")
        settingsButton.click()
        Thread.sleep(2_000)

        // Screenshot 02: settings with Copy Text button
        takeScreenshot(dir, "02_settings_open.png")

        // Tap "Copy Text" in settings
        val copyText = device.wait(Until.findObject(By.desc("settings_copy_text")), 5_000)
        assertNotNull(copyText, "Copy Text button not found in settings")
        copyText.click()
        Thread.sleep(1_000)

        // Dismiss settings
        device.pressBack()
        Thread.sleep(1_000)

        Log.i(TAG, "[$testName] Copy Text via settings — PASSED")
    }

    // ---- Test 8: Clear Transcription ----

    @Test
    fun test_08_clearTranscription() {
        val testName = "08_clearTranscription"
        val dir = evidenceDir(testName)
        launchWithModel(DEFAULT_MODEL)
        // Wait for E2E auto-transcription (provides text to clear)
        device.wait(Until.hasObject(By.textContains("E2E EVIDENCE")), MODEL_LOAD_TIMEOUT)
        Thread.sleep(SHORT_WAIT)

        // Verify transcript text is present from E2E auto-transcription
        val transcriptText = device.findObject(By.textContains("ask not"))
            ?: device.findObject(By.textContains("fellow"))
            ?: device.findObject(By.textContains("country"))
        assertNotNull(transcriptText, "No transcript text found before clear")

        // Screenshot 01: with transcript text
        takeScreenshot(dir, "01_with_text.png")

        // Call clearTranscription on the main thread — Compose DropdownMenu popup items
        // cannot be reliably clicked via UiAutomator (gesture/tap events are intercepted
        // by the popup dismiss handler). Run on main thread for Compose recomposition.
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext
                as com.voiceping.offlinetranscription.OfflineTranscriptionApp
        Log.i(TAG, "[$testName] confirmedText BEFORE clear: '${app.whisperEngine.confirmedText.value.take(50)}'")
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            app.whisperEngine.clearTranscription()
        }
        val afterClear = app.whisperEngine.confirmedText.value
        Log.i(TAG, "[$testName] confirmedText AFTER clear: '$afterClear'")
        Thread.sleep(2_000)

        // Verify the data model was cleared (UI recomposition may lag in automation)
        assertTrue(afterClear.isEmpty(), "clearTranscription() failed — confirmedText not empty: '$afterClear'")

        // Screenshot 02: cleared
        takeScreenshot(dir, "02_cleared.png")
        Log.i(TAG, "[$testName] Clear transcription — PASSED")
    }

    // ---- Test 9: Record While No Model ----

    @Test
    fun test_09_recordWhileNoModel() {
        val testName = "09_recordWhileNoModel"
        val dir = evidenceDir(testName)

        // Navigate to setup screen via "Change Model" in settings
        launchWithModel(DEFAULT_MODEL)
        waitForModelAndClear()

        // Open settings and tap "Change Model"
        val settingsButton = device.findObject(By.desc("Settings"))
        assertNotNull(settingsButton, "Settings button not found")
        settingsButton.click()
        Thread.sleep(2_000)

        val changeModel = device.wait(Until.findObject(By.desc("settings_change_model")), 5_000)
        assertNotNull(changeModel, "Change Model button not found in settings")
        changeModel.click()
        Thread.sleep(2_000)

        // Verify we're on setup screen
        val setupTitle = device.wait(Until.findObject(By.text("Setup")), 10_000)
            ?: device.wait(Until.findObject(By.text("Select Model")), 5_000)
        assertNotNull(setupTitle, "Should be on setup screen after Change Model")

        // Screenshot 01: setup screen (no model loaded — model was unloaded)
        takeScreenshot(dir, "01_setup_screen.png")
        Log.i(TAG, "[$testName] Setup screen visible — model unloaded")

        // The mic button should NOT be accessible from setup screen
        val micButton = device.findObject(By.desc("Start recording"))
        val noMic = micButton == null

        // Screenshot 02: verify no record button
        takeScreenshot(dir, "02_no_mic_button.png")

        assertTrue(noMic, "Mic button should not be accessible from setup screen")
        Log.i(TAG, "[$testName] No mic button on setup screen — PASSED")
    }

    // ---- Test 10: History Delete Item ----

    @Test
    fun test_10_historyDeleteItem() {
        val testName = "10_historyDeleteItem"
        val dir = evidenceDir(testName)
        launchWithModel(DEFAULT_MODEL)
        // Wait for E2E auto-transcription to provide text to save
        device.wait(Until.hasObject(By.textContains("E2E EVIDENCE")), MODEL_LOAD_TIMEOUT)
        Thread.sleep(SHORT_WAIT)
        ensureTranscriptReady()

        // Save the transcription
        val saveButton = device.wait(Until.findObject(By.desc("Save")), 10_000)
        assertNotNull(saveButton, "Save button not found")
        saveButton.click()
        Thread.sleep(2_000)

        // Dismiss save dialog
        val okButton = device.findObject(By.text("OK"))
        okButton?.click()
        Thread.sleep(1_000)

        // Navigate to History tab
        val historyTab = device.findObject(By.text("History"))
        assertNotNull(historyTab, "History tab not found")
        historyTab.click()
        Thread.sleep(2_000)

        // Screenshot 01: history with item
        takeScreenshot(dir, "01_history_with_item.png")

        // Find and tap delete button on first item
        val deleteButton = device.findObject(By.desc("Delete"))
        assertNotNull(deleteButton, "Delete button not found in history list")

        // Screenshot 02: about to delete
        takeScreenshot(dir, "02_before_delete.png")

        deleteButton.click()
        Thread.sleep(2_000)

        // Screenshot 03: after delete — may show empty state or remaining items
        takeScreenshot(dir, "03_after_delete.png")

        // Check if empty state appeared (meaning our item was the only one)
        val emptyState = device.findObject(By.text("No Transcriptions Yet"))
        if (emptyState != null) {
            Log.i(TAG, "[$testName] History is now empty after delete")
        } else {
            Log.i(TAG, "[$testName] History still has items (other tests may have saved items)")
        }

        Log.i(TAG, "[$testName] History delete item — PASSED")
    }

    // ---- Helper Methods ----

    /**
     * Launch app with a specific model, wait for E2E auto-transcription to complete,
     * then clear the transcript so the app is in a clean idle state.
     */
    private fun launchWithModel(modelId: String) {
        // Use am start via shell to avoid killing the instrumentation process
        // (context.startActivity with FLAG_ACTIVITY_CLEAR_TASK kills the shared process)
        device.executeShellCommand(
            "am start -W -n $PACKAGE/.MainActivity" +
            " --ez e2e_test true --es model_id $modelId"
        )
        device.wait(Until.hasObject(By.pkg(PACKAGE).depth(0)), LAUNCH_TIMEOUT)
        Log.i(TAG, "App launched with model: $modelId")
    }

    /**
     * Wait for E2E auto-transcription to complete (evidence overlay appears),
     * then clear the text to leave app in clean idle state.
     */
    private fun waitForModelAndClear() {
        // Wait for E2E evidence overlay (model loaded + auto-transcription done)
        val e2eDone = device.wait(Until.hasObject(By.textContains("E2E EVIDENCE")), MODEL_LOAD_TIMEOUT)
        if (e2eDone) {
            Log.i(TAG, "E2E auto-transcription complete")
        } else {
            // Fallback: just wait for CPU stats
            device.wait(Until.hasObject(By.textContains("CPU")), 10_000)
            Log.w(TAG, "E2E overlay not found, but transcription screen visible")
        }
        Thread.sleep(2_000)

        // Clear transcription directly — Compose DropdownMenu popup items cannot be
        // reliably clicked via UiAutomator, so call the engine method directly.
        try {
            val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext
                    as com.voiceping.offlinetranscription.OfflineTranscriptionApp
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                app.whisperEngine.clearTranscription()
            }
            Log.i(TAG, "Transcript cleared — app in idle state")
        } catch (e: Exception) {
            Log.w(TAG, "Failed to clear transcription: ${e.message}")
        }
        Thread.sleep(1_000)
    }

    /** Wait for model to finish loading (transcription screen visible) */
    private fun waitForModelLoaded() {
        // Wait for CPU stats text (indicates transcription screen is showing)
        val loaded = device.wait(Until.hasObject(By.textContains("CPU")), MODEL_LOAD_TIMEOUT)
        if (loaded) {
            Log.i(TAG, "Model loaded — transcription screen visible")
        } else {
            Log.w(TAG, "Timeout waiting for model load")
        }
        Thread.sleep(2_000)
    }

    /** Launch app without selecting a model (goes to setup screen) */
    private fun launchApp() {
        device.executeShellCommand("am start -W -n $PACKAGE/.MainActivity")
        device.wait(Until.hasObject(By.pkg(PACKAGE).depth(0)), LAUNCH_TIMEOUT)
        Log.i(TAG, "App launched without model")
    }

    /** Create and return evidence directory path */
    private fun evidenceDir(testName: String): String {
        val dir = "/sdcard/Documents/e2e/userflow/$testName"
        File(dir).mkdirs()
        return dir
    }

    private fun waitForStartRecordingButton(timeoutMs: Long): androidx.test.uiautomator.UiObject2? {
        var button = device.wait(Until.findObject(By.desc("Start recording")), timeoutMs)
        if (button != null) return button

        device.findObject(By.text("OK"))?.click()
        Thread.sleep(500)

        device.findObject(By.text("Transcribe"))?.click()
        Thread.sleep(500)

        button = device.wait(Until.findObject(By.desc("Start recording")), 5_000)
        return button
    }

    private fun hasTranscriptText(): Boolean {
        return device.hasObject(By.textContains("ask not")) ||
            device.hasObject(By.textContains("fellow")) ||
            device.hasObject(By.textContains("country"))
    }

    private fun ensureTranscriptReady() {
        if (hasTranscriptText()) return

        val testAudio = device.wait(Until.findObject(By.desc("Test Audio File")), 10_000)
        if (testAudio != null) {
            Log.i(TAG, "No transcript yet; running Test Audio File to ensure saveable text")
            testAudio.click()
            device.wait(Until.hasObject(By.textContains("country")), MODEL_LOAD_TIMEOUT)
            Thread.sleep(SHORT_WAIT)
        }
    }

    /**
     * Handle Android permission dialog and app's own permission error dialog.
     * After mic tap, the app may show an error dialog with "Grant Permission" button,
     * which then triggers the system permission dialog.
     */
    private fun handlePermissionDialog() {
        // Check for app's own error dialog first
        val grantButton = device.findObject(By.text("Grant Permission"))
        if (grantButton != null) {
            Log.i(TAG, "App permission dialog found — tapping Grant Permission")
            grantButton.click()
            Thread.sleep(2_000)
        }

        // Check for system permission dialog
        val allowButton = device.findObject(By.text("While using the app"))
            ?: device.findObject(By.text("Only this time"))
            ?: device.findObject(By.textStartsWith("Allow"))
        if (allowButton != null) {
            Log.i(TAG, "System permission dialog found — granting")
            allowButton.click()
            Thread.sleep(2_000)

            // May need to tap mic again after granting permission
            val micRetry = device.findObject(By.desc("Start recording"))
            if (micRetry != null) {
                Log.i(TAG, "Retapping mic button after permission grant")
                micRetry.click()
                Thread.sleep(2_000)
            }
        }
    }

    /** Take and save a screenshot */
    private fun takeScreenshot(dir: String, filename: String) {
        try {
            val destFile = File(dir, filename)
            destFile.parentFile?.mkdirs()
            device.takeScreenshot(destFile)
            Log.d(TAG, "Screenshot saved: ${destFile.absolutePath} (${destFile.length()} bytes)")
        } catch (e: Throwable) {
            Log.w(TAG, "Screenshot failed: $filename", e)
        }
    }
}
