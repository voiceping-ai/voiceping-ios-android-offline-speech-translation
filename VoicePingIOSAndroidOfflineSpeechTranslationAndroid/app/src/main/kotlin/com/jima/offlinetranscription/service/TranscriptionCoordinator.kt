package com.voiceping.offlinetranscription.service

import android.os.SystemClock
import android.util.Log
import com.voiceping.offlinetranscription.model.AppError
import com.voiceping.offlinetranscription.model.AudioInputMode
import com.voiceping.offlinetranscription.util.TextNormalizationUtils
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlin.math.sqrt

/**
 * Coordinates real-time transcription: inference loop, VAD, chunking, and text assembly.
 *
 * Extracted from WhisperEngine to isolate inference loop state and logic.
 * Owns buffer tracking, silence detection, and chunk management internally.
 * Delegates observable state updates back to WhisperEngine via callback methods.
 */
class TranscriptionCoordinator(
    private val engine: WhisperEngine
) {
    // MARK: - Internal State

    var transcriptionJob: Job? = null
        private set
    private var lastBufferSize: Int = 0
    private val inferenceMutex = Mutex()
    private var recordingStartElapsedMs: Long = 0L
    private var hasCompletedFirstInference: Boolean = false
    private var realtimeInferenceCount: Long = 0
    private var movingAverageInferenceSeconds: Double = 0.0

    // MARK: - Constants

    companion object {
        private const val MAX_BUFFER_SAMPLES = AudioConstants.SAMPLE_RATE * 300 // 5 minutes
        private const val OFFLINE_REALTIME_CHUNK_SECONDS = 5.0f
        private const val INITIAL_MIN_NEW_AUDIO_SECONDS = 0.35f
        private const val MIN_NEW_AUDIO_SECONDS = 0.7f
        private const val MIN_INFERENCE_RMS = 0.012f
        private const val INITIAL_VAD_BYPASS_SECONDS = 1.0f
        private const val TARGET_INFERENCE_DUTY_CYCLE = 0.24f
        private const val MAX_CPU_PROTECT_DELAY_SECONDS = 1.6f
        private const val INFERENCE_EMA_ALPHA = 0.20
        private const val DIAGNOSTIC_LOG_INTERVAL = 5L
        private const val SILENCE_THRESHOLD = 0.0015f
        private const val VAD_PREROLL_SECONDS = 0.6f
        private const val NO_SIGNAL_TIMEOUT_SECONDS = 8.0
        private const val SIGNAL_ENERGY_THRESHOLD = 0.005f
    }

    // MARK: - Chunk Manager

    fun createChunkManagerForModel(): StreamingChunkManager {
        return StreamingChunkManager(
            chunkSeconds = OFFLINE_REALTIME_CHUNK_SECONDS,
            sampleRate = AudioRecorder.SAMPLE_RATE,
            minNewAudioSeconds = MIN_NEW_AUDIO_SECONDS
        )
    }

    // MARK: - Loop Lifecycle

    fun startLoop(scope: CoroutineScope, sessionToken: Long, asrEngine: AsrEngine) {
        cancelTranscriptionJob()
        recordingStartElapsedMs = SystemClock.elapsedRealtime()
        if (asrEngine.isSelfRecording) {
            transcriptionJob = scope.launch {
                selfRecordingPollLoop(asrEngine, sessionToken)
            }
        } else {
            transcriptionJob = scope.launch {
                realtimeLoop(asrEngine, sessionToken)
            }
        }
    }

    fun cancelTranscriptionJob() {
        transcriptionJob?.cancel()
        transcriptionJob = null
    }

    suspend fun cancelTranscriptionJobAndWait() {
        transcriptionJob?.cancelAndJoin()
        transcriptionJob = null
    }

    // MARK: - Realtime Inference Loop

    private suspend fun realtimeLoop(asrEngine: AsrEngine, sessionToken: Long) {
        try {
            while (engine.isSessionActive(sessionToken)) {
                try {
                    transcribeCurrentBuffer(asrEngine, sessionToken)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Throwable) {
                    if (!engine.isSessionActive(sessionToken)) return
                    engine.onTranscriptionError(AppError.TranscriptionFailed(e))
                    return
                }
            }
        } finally {
            // Final transcription pass for any remaining buffered audio.
            if (asrEngine.isLoaded) {
                val currentCount = engine.audioRecorder.sampleCount
                if (currentCount > lastBufferSize) {
                    try {
                        withContext(NonCancellable) {
                            val slice = engine.chunkManager.computeSlice(currentCount)
                            if (slice != null) {
                                val audioSamples = engine.audioRecorder.samplesRange(slice.startSample, slice.endSample)
                                if (audioSamples.isNotEmpty()) {
                                    val segments = asrEngine.transcribe(audioSamples, computeInferenceThreads(), "auto")
                                    if (segments.isNotEmpty()) {
                                        engine.chunkManager.finalizeTrailing(segments, slice.sliceOffsetMs)
                                        engine.updateConfirmedText(engine.chunkManager.confirmedText)
                                        engine.updateHypothesisText("")
                                        val lang = WhisperEngine.normalizeLanguageCode(segments.firstOrNull()?.detectedLanguage)
                                        if (lang != null) engine.updateDetectedLanguage(lang)
                                        Log.i("TranscriptionCoordinator", "realtimeLoop final pass: ${segments.size} segments, text='${engine.chunkManager.confirmedText.takeLast(60)}'")
                                    }
                                }
                            }
                        }
                    } catch (e: Throwable) {
                        Log.w("TranscriptionCoordinator", "realtimeLoop final pass failed", e)
                    }
                }
            }
            transcriptionJob = null
            if (engine.isSessionActive(sessionToken)) {
                engine.audioRecorder.stopRecording()
                engine.transitionTo(SessionState.Idle)
            }
        }
    }

    /**
     * Polling loop for self-recording engines (e.g. Android SpeechRecognizer).
     * The engine manages its own mic and provides results via [AsrEngine.getConfirmedText]
     * and [AsrEngine.getHypothesisText]. We poll every 200ms to update the UI.
     */
    private suspend fun selfRecordingPollLoop(asrEngine: AsrEngine, sessionToken: Long) {
        var lastConfirmed = ""
        var lastHypothesis = ""
        try {
            while (engine.isSessionActive(sessionToken)) {
                val confirmed = asrEngine.getConfirmedText()
                val hypothesis = asrEngine.getHypothesisText()

                if (confirmed != lastConfirmed || hypothesis != lastHypothesis) {
                    engine.updateConfirmedText(confirmed)
                    engine.updateHypothesisText(hypothesis)
                    engine.chunkManager.confirmedText = confirmed
                    lastConfirmed = confirmed
                    lastHypothesis = hypothesis

                    val lang = WhisperEngine.normalizeLanguageCode(asrEngine.getDetectedLanguage())
                    if (lang != null && lang != engine.detectedLanguage.value) {
                        engine.updateDetectedLanguage(lang)
                        engine.applyDetectedLanguageToTranslation(lang)
                    }

                    if (confirmed.isNotBlank()) {
                        engine.scheduleTranslationUpdate()
                    }
                }

                delay(200)
            }
        } catch (e: CancellationException) {
            // Normal cancellation on stop
        } catch (e: Throwable) {
            Log.e("TranscriptionCoordinator", "selfRecordingPollLoop error", e)
            if (engine.isSessionActive(sessionToken)) {
                engine.onTranscriptionError(AppError.TranscriptionFailed(e))
            }
        }
    }

    // MARK: - Per-Frame Transcription

    private suspend fun transcribeCurrentBuffer(asrEngine: AsrEngine, sessionToken: Long) {
        if (!engine.isSessionActive(sessionToken)) return

        // No-signal detection
        if (engine.audioRecorder.bufferSeconds >= NO_SIGNAL_TIMEOUT_SECONDS &&
            engine.audioRecorder.maxRecentEnergy < SIGNAL_ENERGY_THRESHOLD &&
            engine.confirmedText.value.isBlank() &&
            engine.hypothesisText.value.isBlank()
        ) {
            engine.onNoSignalDetected()
            return
        }

        val currentBufferSize = engine.audioRecorder.sampleCount
        val nextBufferSize = currentBufferSize - lastBufferSize
        val nextBufferSeconds = nextBufferSize.toFloat() / AudioRecorder.SAMPLE_RATE
        val bufferSeconds = currentBufferSize.toFloat() / AudioRecorder.SAMPLE_RATE

        val initialPhase = !hasCompletedFirstInference
        val baseDelay = if (initialPhase) {
            INITIAL_MIN_NEW_AUDIO_SECONDS
        } else {
            MIN_NEW_AUDIO_SECONDS
        }
        val effectiveDelay = if (initialPhase) {
            baseDelay
        } else {
            computeCpuAwareDelay(baseDelay)
        }
        if (nextBufferSeconds < effectiveDelay) {
            delay(100)
            return
        }

        // VAD check — bypass for system playback (continuous audio, not voice-triggered)
        if (engine.useVAD.value && engine.audioInputMode.value != AudioInputMode.SYSTEM_PLAYBACK) {
            val vadBypassSamples = (AudioRecorder.SAMPLE_RATE * INITIAL_VAD_BYPASS_SECONDS).toInt()
            val bypassVadDuringStartup = initialPhase && currentBufferSize <= vadBypassSamples
            if (!bypassVadDuringStartup) {
                val energy = engine.audioRecorder.relativeEnergy
                if (energy.isNotEmpty()) {
                    val recentEnergy = energy.takeLast(10)
                    val avgEnergy = recentEnergy.sum() / recentEnergy.size
                    val peakEnergy = recentEnergy.maxOrNull() ?: 0f
                    val hasVoice = peakEnergy >= SILENCE_THRESHOLD ||
                        avgEnergy >= SILENCE_THRESHOLD * 0.5f

                    if (!hasVoice) {
                        engine.chunkManager.consecutiveSilentWindows += 1
                        if (engine.chunkManager.consecutiveSilentWindows <= 2 ||
                            engine.chunkManager.consecutiveSilentWindows % DIAGNOSTIC_LOG_INTERVAL.toInt() == 0
                        ) {
                            Log.i(
                                "TranscriptionCoordinator",
                                "rt VAD skip: silentWindows=${engine.chunkManager.consecutiveSilentWindows} buffer=${"%.2f".format(bufferSeconds)}s"
                            )
                        }
                        keepVadPreroll(currentBufferSize)
                        return
                    } else {
                        engine.chunkManager.consecutiveSilentWindows = 0
                    }
                } else {
                    engine.chunkManager.consecutiveSilentWindows += 1
                    if (engine.chunkManager.consecutiveSilentWindows <= 2 ||
                        engine.chunkManager.consecutiveSilentWindows % DIAGNOSTIC_LOG_INTERVAL.toInt() == 0
                    ) {
                        Log.i(
                            "TranscriptionCoordinator",
                            "rt VAD skip(no-energy): silentWindows=${engine.chunkManager.consecutiveSilentWindows} buffer=${"%.2f".format(bufferSeconds)}s"
                        )
                    }
                    keepVadPreroll(currentBufferSize)
                    return
                }
            }
        }

        // Update energy visualization
        engine.updateBufferEnergy(engine.audioRecorder.relativeEnergy)
        engine.updateBufferSeconds(engine.audioRecorder.bufferSeconds)

        // Chunk-based windowing via StreamingChunkManager
        val slice = engine.chunkManager.computeSlice(currentBufferSize) ?: return

        val audioSamples = engine.audioRecorder.samplesRange(slice.startSample, slice.endSample)
        if (audioSamples.isEmpty()) return
        val sliceStartSec = slice.startSample.toFloat() / AudioRecorder.SAMPLE_RATE
        val sliceEndSec = slice.endSample.toFloat() / AudioRecorder.SAMPLE_RATE

        // RMS gate: skip inference on near-silence to prevent SenseVoice hallucinations
        val sliceRms = computeRms(audioSamples)
        if (sliceRms < MIN_INFERENCE_RMS) {
            if (engine.chunkManager.consecutiveSilentWindows <= 2 ||
                engine.chunkManager.consecutiveSilentWindows % DIAGNOSTIC_LOG_INTERVAL.toInt() == 0
            ) {
                Log.i(
                    "TranscriptionCoordinator",
                    "rt RMS skip: rms=${"%.4f".format(sliceRms)} < ${"%.4f".format(MIN_INFERENCE_RMS)} slice=[${"%.2f".format(sliceStartSec)},${"%.2f".format(sliceEndSec)}]"
                )
            }
            delay(500)
            return
        }
        lastBufferSize = currentBufferSize

        val startTime = System.nanoTime()
        val numThreads = computeInferenceThreads()
        if (!inferenceMutex.tryLock()) {
            return
        }
        val newSegments = try {
            asrEngine.transcribe(audioSamples, numThreads, "auto")
        } finally {
            inferenceMutex.unlock()
        }
        realtimeInferenceCount += 1
        val inferenceIndex = realtimeInferenceCount
        if (!hasCompletedFirstInference) {
            val firstInferenceMs = SystemClock.elapsedRealtime() - recordingStartElapsedMs
            Log.i(
                "TranscriptionCoordinator",
                "First inference completed in ${firstInferenceMs}ms (buffer=${"%.2f".format(bufferSeconds)}s, slice=${"%.2f".format(sliceEndSec - sliceStartSec)}s)"
            )
        }
        hasCompletedFirstInference = true
        if (!engine.isSessionActive(sessionToken)) return

        val elapsed = (System.nanoTime() - startTime) / 1_000_000_000.0
        if (elapsed > 0.0) {
            movingAverageInferenceSeconds = if (movingAverageInferenceSeconds <= 0.0) {
                elapsed
            } else {
                movingAverageInferenceSeconds + INFERENCE_EMA_ALPHA * (elapsed - movingAverageInferenceSeconds)
            }
        }
        val sliceDurationSec = audioSamples.size.toFloat() / AudioRecorder.SAMPLE_RATE
        val totalWords = newSegments.sumOf { it.text.split(" ").size }
        if (elapsed > 0 && totalWords > 0) {
            engine.updateTokensPerSecond(totalWords / elapsed)
        }
        val confirmedBeforeSec = engine.chunkManager.lastConfirmedSegmentEndMs / 1000f

        if (newSegments.isNotEmpty()) {
            engine.chunkManager.consecutiveSilentWindows = 0
            val lang = WhisperEngine.normalizeLanguageCode(newSegments.firstOrNull()?.detectedLanguage)
            if (lang != null && lang != engine.detectedLanguage.value) {
                engine.updateDetectedLanguage(lang)
                engine.applyDetectedLanguageToTranslation(lang)
            }
        }
        engine.chunkManager.processTranscriptionResult(newSegments, slice.sliceOffsetMs)
        engine.updateConfirmedText(engine.chunkManager.confirmedText)
        engine.updateHypothesisText(engine.chunkManager.hypothesisText)
        engine.scheduleTranslationUpdate()
        val confirmedAfterSec = engine.chunkManager.lastConfirmedSegmentEndMs / 1000f
        val lagAfterSec = (bufferSeconds - confirmedAfterSec).coerceAtLeast(0f)
        val previewText = newSegments.firstOrNull()
            ?.text
            ?.let { normalizeDisplayText(it) }
            ?.take(64)
            .orEmpty()
        val ratio = if (elapsed > 0.0) sliceDurationSec / elapsed else 0.0f
        val shouldLogDetailed =
            inferenceIndex <= 4L ||
                inferenceIndex % DIAGNOSTIC_LOG_INTERVAL == 0L ||
                elapsed >= 0.35 ||
                sliceDurationSec >= 4.0f ||
                lagAfterSec >= 2.0f
        if (shouldLogDetailed) {
            Log.i(
                "TranscriptionCoordinator",
                "rt chunk #$inferenceIndex buf=${"%.2f".format(bufferSeconds)}s new=${"%.2f".format(nextBufferSeconds)}s gate=${"%.2f".format(effectiveDelay)}s base=${"%.2f".format(baseDelay)}s avgInfer=${"%.3f".format(movingAverageInferenceSeconds)}s cpu=${"%.0f".format(engine.cpuPercent.value)}% slice=[${"%.2f".format(sliceStartSec)},${"%.2f".format(sliceEndSec)}] dur=${"%.2f".format(sliceDurationSec)}s infer=${"%.3f".format(elapsed)}s ratio=${"%.1f".format(ratio)}x seg=${newSegments.size} words=$totalWords conf=${"%.2f".format(confirmedBeforeSec)}s->${"%.2f".format(confirmedAfterSec)}s lag=${"%.2f".format(lagAfterSec)}s preview='${previewText}'"
            )
        }

        val safeTrimSample = ((engine.chunkManager.lastConfirmedSegmentEndMs * AudioRecorder.SAMPLE_RATE) / 1000)
            .toInt()
        trimRecorderBufferIfNeeded(safeTrimSample)
    }

    // MARK: - VAD & Delay

    private fun keepVadPreroll(currentBufferSize: Int) {
        val preRollSamples = (AudioRecorder.SAMPLE_RATE * VAD_PREROLL_SECONDS).toInt()
        lastBufferSize = (currentBufferSize - preRollSamples).coerceAtLeast(0)
    }

    private fun computeCpuAwareDelay(baseDelay: Float): Float {
        val avg = movingAverageInferenceSeconds
        if (avg <= 0.0) return baseDelay
        val budgetDelay = (avg / TARGET_INFERENCE_DUTY_CYCLE).toFloat()
        return maxOf(baseDelay, budgetDelay.coerceAtMost(MAX_CPU_PROTECT_DELAY_SECONDS))
    }

    // MARK: - Audio Analysis

    private fun computeRms(samples: FloatArray): Float {
        if (samples.isEmpty()) return 0f
        var sumSquares = 0.0
        for (sample in samples) {
            sumSquares += sample * sample
        }
        return sqrt(sumSquares / samples.size).toFloat()
    }

    // MARK: - Buffer Management

    private fun trimRecorderBufferIfNeeded(safeTrimBeforeAbsoluteSample: Int) {
        val currentAbsoluteSamples = engine.audioRecorder.sampleCount
        if (currentAbsoluteSamples <= MAX_BUFFER_SAMPLES) return

        val targetKeepSamples = MAX_BUFFER_SAMPLES / 2
        val desiredDropBefore = currentAbsoluteSamples - targetKeepSamples
        val dropBefore = minOf(
            desiredDropBefore,
            safeTrimBeforeAbsoluteSample.coerceAtLeast(0)
        )
        if (dropBefore <= 0) return

        val dropped = engine.audioRecorder.discardSamples(beforeAbsoluteIndex = dropBefore)
        if (dropped > 0) {
            Log.i(
                "TranscriptionCoordinator",
                "Trimmed $dropped old mic samples (safeBefore=$safeTrimBeforeAbsoluteSample, current=$currentAbsoluteSamples)"
            )
        }
    }

    // MARK: - Finalization

    fun finalizeSelfRecordingStop(asrEngine: AsrEngine) {
        asrEngine.stopListening()
        engine.updateConfirmedText(asrEngine.getConfirmedText())
        engine.updateHypothesisText("")
        engine.chunkManager.confirmedText = engine.confirmedText.value
        Log.i("TranscriptionCoordinator", "stopRecording (self-recording): text='${engine.confirmedText.value.take(80)}'")
    }

    fun finalizeBufferedRecordingStop() {
        engine.audioRecorder.stopRecording()
        engine.chunkManager.finalizeCurrentChunk()
        engine.updateConfirmedText(engine.chunkManager.confirmedText)
        engine.updateHypothesisText("")
        Log.i("TranscriptionCoordinator", "stopRecording: finalized text='${engine.confirmedText.value.take(80)}' audio=${engine.audioRecorder.bufferSeconds}s")
    }

    // MARK: - Text Normalization

    fun normalizeDisplayText(text: String): String = TextNormalizationUtils.normalizeText(text)

    // MARK: - Utilities

    private fun computeInferenceThreads(): Int {
        return Runtime.getRuntime().availableProcessors().coerceAtMost(4).coerceAtLeast(1)
    }

    // MARK: - State Reset

    fun reset() {
        cancelTranscriptionJob()
        lastBufferSize = 0
        recordingStartElapsedMs = 0L
        hasCompletedFirstInference = false
        realtimeInferenceCount = 0
        movingAverageInferenceSeconds = 0.0
    }
}
