package com.voiceping.offlinetranscription.ui.transcription

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.voiceping.offlinetranscription.data.AppDatabase
import com.voiceping.offlinetranscription.data.TranscriptionEntity
import com.voiceping.offlinetranscription.model.ModelInfo
import com.voiceping.offlinetranscription.service.WhisperEngine
import com.voiceping.offlinetranscription.util.WavWriter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

class TranscriptionViewModel(
    val engine: WhisperEngine,
    private val database: AppDatabase,
    private val filesDir: File
) : ViewModel() {

    val isRecording = engine.isRecording
    val confirmedText = engine.confirmedText
    val hypothesisText = engine.hypothesisText
    val bufferEnergy = engine.bufferEnergy
    val bufferSeconds = engine.bufferSeconds
    val tokensPerSecond = engine.tokensPerSecond
    val lastError = engine.lastError
    val selectedModel = engine.selectedModel
    val modelState = engine.modelState
    val useVAD = engine.useVAD
    val enableTimestamps = engine.enableTimestamps
    val translationEnabled = engine.translationEnabled
    val speakTranslatedAudio = engine.speakTranslatedAudio
    val translationSourceLanguageCode = engine.translationSourceLanguageCode
    val translationTargetLanguageCode = engine.translationTargetLanguageCode
    val ttsRate = engine.ttsRate
    val translatedConfirmedText = engine.translatedConfirmedText
    val translatedHypothesisText = engine.translatedHypothesisText
    val translationWarning = engine.translationWarning
    val cpuPercent = engine.cpuPercent
    val memoryMB = engine.memoryMB
    val e2eResult = engine.e2eResult

    private val _showSaveConfirmation = MutableStateFlow(false)
    val showSaveConfirmation: StateFlow<Boolean> = _showSaveConfirmation.asStateFlow()

    val fullText: String
        get() = engine.fullTranscriptionText

    fun toggleRecording() {
        if (engine.isRecording.value) {
            engine.stopRecording()
        } else {
            engine.startRecording()
        }
    }

    fun clearTranscription() {
        engine.clearTranscription()
    }

    /** Dismiss error without clearing transcription text. */
    fun dismissError() {
        engine.clearError()
    }

    fun saveTranscription() {
        val text = fullText
        if (text.isBlank()) return

        // Use actual audio buffer duration, not wall clock
        val duration = engine.recordingDurationSeconds
        viewModelScope.launch {
            val entity = TranscriptionEntity(
                text = text,
                durationSeconds = duration,
                modelUsed = engine.selectedModel.value.displayName
            )

            // Write audio WAV if samples are available
            val samples = engine.audioRecorder.samples
            var audioRelPath: String? = null
            if (samples.isNotEmpty()) {
                try {
                    val sessionDir = File(filesDir, "sessions/${entity.id}")
                    val wavFile = File(sessionDir, "audio.wav")
                    withContext(Dispatchers.IO) {
                        WavWriter.write(samples, outputFile = wavFile)
                    }
                    audioRelPath = "sessions/${entity.id}/audio.wav"
                    Log.i("TranscriptionVM", "Saved audio WAV: ${wavFile.length()} bytes")
                } catch (e: Exception) {
                    Log.w("TranscriptionVM", "Failed to write audio WAV", e)
                }
            }

            try {
                database.transcriptionDao().insert(
                    entity.copy(audioFileName = audioRelPath)
                )
                _showSaveConfirmation.value = true
            } catch (e: Exception) {
                // Clean up audio file on DB failure
                if (audioRelPath != null) {
                    File(filesDir, "sessions/${entity.id}").deleteRecursively()
                }
                engine.setLastError(
                    com.voiceping.offlinetranscription.model.AppError.TranscriptionFailed(e)
                )
            }
        }
    }

    fun dismissSaveConfirmation() {
        _showSaveConfirmation.value = false
    }

    fun transcribeTestFile(filePath: String) {
        engine.transcribeFile(filePath)
    }

    fun stopIfRecording() {
        if (engine.isRecording.value) {
            engine.stopRecording()
        }
    }

    fun switchModel(model: ModelInfo) {
        viewModelScope.launch {
            engine.switchModel(model)
        }
    }

    fun setUseVAD(enabled: Boolean) {
        viewModelScope.launch {
            engine.setUseVAD(enabled)
        }
    }

    fun setEnableTimestamps(enabled: Boolean) {
        viewModelScope.launch {
            engine.setEnableTimestamps(enabled)
        }
    }

    fun setTranslationEnabled(enabled: Boolean) {
        viewModelScope.launch {
            engine.setTranslationEnabled(enabled)
        }
    }

    fun setSpeakTranslatedAudio(enabled: Boolean) {
        viewModelScope.launch {
            engine.setSpeakTranslatedAudio(enabled)
        }
    }

    fun setTranslationSourceLanguageCode(languageCode: String) {
        viewModelScope.launch {
            engine.setTranslationSourceLanguageCode(languageCode)
        }
    }

    fun setTranslationTargetLanguageCode(languageCode: String) {
        viewModelScope.launch {
            engine.setTranslationTargetLanguageCode(languageCode)
        }
    }

    fun setTtsRate(rate: Float) {
        viewModelScope.launch {
            engine.setTtsRate(rate)
        }
    }
}
