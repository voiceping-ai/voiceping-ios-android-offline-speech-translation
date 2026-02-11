package com.voiceping.offlinetranscription.service

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import com.voiceping.offlinetranscription.model.AndroidSpeechMode
import java.util.Locale

/**
 * ASR engine backed by Android's built-in [SpeechRecognizer].
 *
 * Key differences from other engines:
 * - [isSelfRecording] = true: the SpeechRecognizer captures audio from the mic itself.
 * - [transcribe] is not supported (returns empty) — this engine only works in live recording mode.
 * - [mode] controls whether to use on-device or standard (potentially cloud-backed) recognition:
 *   - [AndroidSpeechMode.OFFLINE]: Uses [SpeechRecognizer.createOnDeviceSpeechRecognizer] (API 31+).
 *   - [AndroidSpeechMode.ONLINE]: Uses [SpeechRecognizer.createSpeechRecognizer] without offline hint.
 * - SpeechRecognizer must be created/operated on the main thread, so [startListening]/[stopListening]
 *   must be called from the main thread (WhisperEngine handles this).
 */
class AndroidSpeechEngine(
    private val context: Context,
    private val mode: AndroidSpeechMode = AndroidSpeechMode.OFFLINE
) : AsrEngine {

    companion object {
        private const val TAG = "AndroidSpeechEngine"
    }

    private var recognizer: SpeechRecognizer? = null
    @Volatile private var loaded = false
    @Volatile private var listening = false

    // Accumulated transcription results
    @Volatile private var confirmedText: String = ""
    @Volatile private var hypothesisText: String = ""
    @Volatile private var detectedLanguage: String? = null

    override val isSelfRecording: Boolean get() = true
    override val isLoaded: Boolean get() = loaded

    override suspend fun loadModel(modelPath: String): Boolean {
        val available = when (mode) {
            AndroidSpeechMode.OFFLINE -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
                } else {
                    Log.w(TAG, "On-device recognizer requires API 31+, current is ${Build.VERSION.SDK_INT}")
                    false
                }
            }
            AndroidSpeechMode.ONLINE -> {
                SpeechRecognizer.isRecognitionAvailable(context)
            }
        }

        if (!available) {
            Log.w(TAG, "SpeechRecognizer (mode=$mode) not available on this device")
            return false
        }

        loaded = true
        Log.i(TAG, "Android SpeechRecognizer available (mode=$mode, API ${Build.VERSION.SDK_INT})")
        return true
    }

    override suspend fun transcribe(
        audioSamples: FloatArray,
        numThreads: Int,
        language: String
    ): List<TranscriptionSegment> {
        // Not supported — SpeechRecognizer doesn't accept raw audio buffers.
        // File-based transcription is not available for this engine.
        Log.w(TAG, "transcribe() not supported for AndroidSpeechEngine (self-recording only)")
        return emptyList()
    }

    /**
     * Start live speech recognition. Must be called on the main thread.
     * Creates the SpeechRecognizer and begins listening.
     */
    override fun startListening() {
        if (listening) {
            Log.w(TAG, "Already listening, ignoring startListening()")
            return
        }

        confirmedText = ""
        hypothesisText = ""
        detectedLanguage = null

        val sr = when (mode) {
            AndroidSpeechMode.OFFLINE -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                    SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
                ) {
                    Log.i(TAG, "Creating on-device SpeechRecognizer (OFFLINE mode, API 31+)")
                    SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
                } else {
                    Log.w(TAG, "On-device recognizer unavailable, falling back to standard with EXTRA_PREFER_OFFLINE")
                    SpeechRecognizer.createSpeechRecognizer(context)
                }
            }
            AndroidSpeechMode.ONLINE -> {
                Log.i(TAG, "Creating standard SpeechRecognizer (ONLINE mode — may use cloud)")
                SpeechRecognizer.createSpeechRecognizer(context)
            }
        }

        sr.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {
                Log.i(TAG, "Ready for speech")
            }

            override fun onBeginningOfSpeech() {
                Log.i(TAG, "Speech started")
            }

            override fun onRmsChanged(rmsdB: Float) {
                // Could be used for energy visualization in the future
            }

            override fun onBufferReceived(buffer: ByteArray?) {}

            override fun onEndOfSpeech() {
                Log.i(TAG, "Speech ended")
            }

            override fun onError(error: Int) {
                val errorMsg = errorCodeToString(error)
                Log.w(TAG, "Recognition error: $errorMsg ($error)")

                // On transient errors (e.g. NO_MATCH, SPEECH_TIMEOUT), restart if still listening.
                // SpeechRecognizer auto-stops after each utterance, so we restart to keep
                // continuous recognition going.
                if (listening && isRestartableError(error)) {
                    Log.i(TAG, "Restarting recognition after transient error")
                    restartRecognition(sr)
                }
            }

            override fun onResults(results: Bundle?) {
                val matches = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                val bestResult = matches?.firstOrNull()?.trim() ?: ""
                if (bestResult.isNotEmpty()) {
                    val separator = if (confirmedText.isNotEmpty()) " " else ""
                    confirmedText = confirmedText + separator + bestResult
                    Log.i(TAG, "Final result: '$bestResult' | total='${confirmedText.take(80)}'")
                }
                hypothesisText = ""

                // SpeechRecognizer stops after each utterance — restart for continuous recognition
                if (listening) {
                    restartRecognition(sr)
                }
            }

            override fun onPartialResults(partialResults: Bundle?) {
                val matches = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                val partial = matches?.firstOrNull()?.trim() ?: ""
                if (partial.isNotEmpty()) {
                    hypothesisText = partial
                }
            }

            override fun onEvent(eventType: Int, params: Bundle?) {}
        })

        recognizer = sr
        listening = true
        beginRecognition(sr)
    }

    /** Stop listening and release the recognizer. Must be called on the main thread. */
    override fun stopListening() {
        listening = false
        try {
            recognizer?.stopListening()
        } catch (e: Throwable) {
            Log.w(TAG, "stopListening failed", e)
        }
        destroyRecognizer()
        // Promote any remaining hypothesis to confirmed
        if (hypothesisText.isNotEmpty()) {
            val separator = if (confirmedText.isNotEmpty()) " " else ""
            confirmedText = confirmedText + separator + hypothesisText
            hypothesisText = ""
        }
    }

    override fun getConfirmedText(): String = confirmedText
    override fun getHypothesisText(): String = hypothesisText
    override fun getDetectedLanguage(): String? = detectedLanguage

    override fun release() {
        listening = false
        destroyRecognizer()
        loaded = false
        confirmedText = ""
        hypothesisText = ""
    }

    private fun beginRecognition(sr: SpeechRecognizer) {
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            // Only request offline preference for OFFLINE mode
            if (mode == AndroidSpeechMode.OFFLINE && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            }
            // Use device default language
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault().toLanguageTag())
        }

        try {
            sr.startListening(intent)
            Log.i(TAG, "Recognition started (mode=$mode, language=${Locale.getDefault().toLanguageTag()})")
        } catch (e: Throwable) {
            Log.e(TAG, "Failed to start listening", e)
        }
    }

    private fun restartRecognition(sr: SpeechRecognizer) {
        try {
            sr.cancel()
            beginRecognition(sr)
        } catch (e: Throwable) {
            Log.w(TAG, "restartRecognition failed", e)
        }
    }

    private fun destroyRecognizer() {
        try {
            recognizer?.destroy()
        } catch (e: Throwable) {
            Log.w(TAG, "destroy recognizer failed", e)
        }
        recognizer = null
    }

    private fun isRestartableError(error: Int): Boolean {
        return error == SpeechRecognizer.ERROR_NO_MATCH ||
            error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT ||
            error == SpeechRecognizer.ERROR_CLIENT
    }

    private fun errorCodeToString(error: Int): String = when (error) {
        SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "NETWORK_TIMEOUT"
        SpeechRecognizer.ERROR_NETWORK -> "NETWORK"
        SpeechRecognizer.ERROR_AUDIO -> "AUDIO"
        SpeechRecognizer.ERROR_SERVER -> "SERVER"
        SpeechRecognizer.ERROR_CLIENT -> "CLIENT"
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "SPEECH_TIMEOUT"
        SpeechRecognizer.ERROR_NO_MATCH -> "NO_MATCH"
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "RECOGNIZER_BUSY"
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "INSUFFICIENT_PERMISSIONS"
        else -> "UNKNOWN($error)"
    }
}
