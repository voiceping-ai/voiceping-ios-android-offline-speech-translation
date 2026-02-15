package com.voiceping.offlinetranscription.service

import android.content.Context
import android.util.Log
import com.voiceping.offlinetranscription.model.ModelInfo
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject
import java.io.File

/** E2E test result for evidence collection. */
data class E2ETestResult(
    val modelId: String,
    val engine: String,
    val transcript: String,
    val translatedText: String,
    val ttsAudioPath: String?,
    val ttsStartCount: Int,
    val ttsMicGuardViolations: Int,
    val micStoppedForTts: Boolean,
    val pass: Boolean,
    val durationMs: Double,
    val timestamp: String,
    val error: String? = null
)

/**
 * Handles E2E test evidence collection and result serialization.
 *
 * Extracted from WhisperEngine to isolate test infrastructure from production logic.
 * Reads transcription/translation state from the engine to build evidence payloads.
 */
class E2ETestOrchestrator(
    private val context: Context,
    private val engine: WhisperEngine
) {
    private val _e2eResult = MutableStateFlow<E2ETestResult?>(null)
    val e2eResult: StateFlow<E2ETestResult?> = _e2eResult.asStateFlow()

    fun reset() {
        _e2eResult.value = null
    }

    fun writeResult(transcript: String, durationMs: Double, error: String?) {
        val model = engine.selectedModel.value
        val keywords = listOf("country", "ask", "do for", "fellow", "americans")
        val lowerTranscript = transcript.lowercase()
        val translatedText = engine.translatedConfirmedText.value
        val ttsAudioPath = engine.ttsEvidenceFilePath()
        val sourceCode = engine.translationSourceLanguageCode.value.trim().lowercase()
        val targetCode = engine.translationTargetLanguageCode.value.trim().lowercase()
        val expectsTranslation = engine.translationEnabled.value &&
            transcript.isNotBlank() &&
            sourceCode.isNotBlank() &&
            targetCode.isNotBlank() &&
            sourceCode != targetCode
        val translationReady = !expectsTranslation || translatedText.isNotBlank()
        val expectsTtsEvidence = engine.speakTranslatedAudio.value && expectsTranslation
        val ttsReady = !expectsTtsEvidence || !ttsAudioPath.isNullOrBlank()

        val pass = error == null &&
            transcript.isNotEmpty() &&
            keywords.any { lowerTranscript.contains(it) } &&
            engine.ttsMicGuardViolationCount == 0

        val result = E2ETestResult(
            modelId = model.id,
            engine = model.inferenceMethod,
            transcript = transcript,
            translatedText = translatedText,
            ttsAudioPath = ttsAudioPath,
            ttsStartCount = engine.ttsStartCountValue,
            ttsMicGuardViolations = engine.ttsMicGuardViolationCount,
            micStoppedForTts = engine.isMicStoppedForTts,
            pass = pass,
            durationMs = durationMs,
            timestamp = java.time.Instant.now().toString(),
            error = error
        )
        _e2eResult.value = result

        val json = JSONObject().apply {
            put("model_id", result.modelId)
            put("engine", result.engine)
            put("transcript", result.transcript)
            put("translated_text", result.translatedText)
            put("translation_warning", engine.translationWarning.value ?: JSONObject.NULL)
            put("expects_translation", expectsTranslation)
            put("translation_ready", translationReady)
            put("tts_audio_path", result.ttsAudioPath ?: JSONObject.NULL)
            put("expects_tts_evidence", expectsTtsEvidence)
            put("tts_ready", ttsReady)
            put("tts_start_count", result.ttsStartCount)
            put("tts_mic_guard_violations", result.ttsMicGuardViolations)
            put("mic_stopped_for_tts", result.micStoppedForTts)
            put("pass", result.pass)
            put("duration_ms", result.durationMs)
            put("timestamp", result.timestamp)
            put("error", result.error ?: JSONObject.NULL)
        }.toString(2)
        writeJson(modelId = model.id, json = json)
    }

    fun writeFailure(modelId: String = engine.selectedModel.value.id, error: String) {
        val model = ModelInfo.availableModels.find { it.id == modelId } ?: engine.selectedModel.value
        val json = JSONObject().apply {
            put("model_id", modelId)
            put("engine", model.inferenceMethod)
            put("transcript", "")
            put("translated_text", "")
            put("translation_warning", JSONObject.NULL)
            put("expects_translation", false)
            put("translation_ready", true)
            put("tts_audio_path", JSONObject.NULL)
            put("expects_tts_evidence", false)
            put("tts_ready", true)
            put("tts_start_count", 0)
            put("tts_mic_guard_violations", 0)
            put("mic_stopped_for_tts", false)
            put("pass", false)
            put("duration_ms", 0.0)
            put("timestamp", java.time.Instant.now().toString())
            put("error", error)
        }.toString(2)
        writeJson(modelId = modelId, json = json)
    }

    private fun writeJson(modelId: String, json: String) {
        try {
            val extDir = context.getExternalFilesDir(null)
            val file = File(extDir, "e2e_result_${modelId}.json")
            file.writeText(json)
            Log.i("E2E", "Result written to ${file.absolutePath}")
        } catch (e: Throwable) {
            Log.w("E2E", "Could not write result JSON (expected in non-test environments)", e)
        }
    }
}
