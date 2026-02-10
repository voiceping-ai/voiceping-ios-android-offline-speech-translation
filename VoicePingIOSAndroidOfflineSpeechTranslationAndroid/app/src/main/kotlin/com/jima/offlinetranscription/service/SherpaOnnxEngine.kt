package com.voiceping.offlinetranscription.service

import android.util.Log
import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineSenseVoiceModelConfig
import com.voiceping.offlinetranscription.model.SherpaModelType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * ASR engine backed by sherpa-onnx for SenseVoice offline recognition.
 * Expects a model directory containing the required ONNX files + tokens.txt.
 *
 * All access to [recognizer] is guarded by [lock] so that release()
 * cannot free the recognizer while transcribe() is in-flight.
 */
class SherpaOnnxEngine(
    private val modelType: SherpaModelType
) : AsrEngine {
    companion object {
        private const val TAG = "SherpaOnnxEngine"
    }

    private var recognizer: OfflineRecognizer? = null
    private val lock = ReentrantLock()

    override val isLoaded: Boolean get() = lock.withLock { recognizer != null }

    override suspend fun loadModel(modelPath: String): Boolean {
        release()
        return withContext(Dispatchers.IO) {
            lock.withLock {
                val threads = computeOfflineThreads()
                try {
                    val config = buildConfig(
                        modelDir = modelPath,
                        threads = threads,
                        provider = "cpu"
                    )
                    recognizer = OfflineRecognizer(config = config)
                    Log.i(TAG, "Loaded sherpa model with provider=cpu threads=$threads")
                    return@withContext true
                } catch (e: Throwable) {
                    Log.e(TAG, "Failed to load sherpa model from $modelPath", e)
                    recognizer = null
                    false
                }
            }
        }
    }

    override suspend fun transcribe(
        audioSamples: FloatArray,
        numThreads: Int,
        language: String
    ): List<TranscriptionSegment> {
        return withContext(Dispatchers.IO) {
            lock.withLock {
                val rec = recognizer ?: return@withContext emptyList()
                try {
                    val audioDurationSec = audioSamples.size / 16000f
                    val decodeStartNs = System.nanoTime()

                    val stream = rec.createStream()
                    val result = try {
                        stream.acceptWaveform(audioSamples, sampleRate = 16000)
                        rec.decode(stream)
                        rec.getResult(stream)
                    } finally {
                        stream.release()
                    }

                    val text = result.text.trim()
                    val timestamps = result.timestamps
                    val lang = result.lang.takeIf { it.isNotBlank() }

                    val decodeElapsedSec = (System.nanoTime() - decodeStartNs) / 1_000_000_000.0
                    Log.i(
                        TAG,
                        "Decode done dur=${String.format("%.1f", audioDurationSec)}s elapsed=${String.format("%.2f", decodeElapsedSec)}s textLen=${text.length}"
                    )
                    if (text.isBlank()) return@withContext emptyList()
                    buildSegments(text, timestamps, lang)
                } catch (e: Throwable) {
                    Log.e(TAG, "Sherpa transcribe failed", e)
                    emptyList()
                }
            }
        }
    }

    override fun release() {
        lock.withLock {
            recognizer?.release()
            recognizer = null
        }
    }

    private fun buildConfig(modelDir: String, threads: Int, provider: String): OfflineRecognizerConfig {
        val tokensPath = File(modelDir, "tokens.txt").absolutePath

        val modelConfig = OfflineModelConfig(
            senseVoice = OfflineSenseVoiceModelConfig(
                model = findFile(modelDir, "model"),
                language = "auto",
                useInverseTextNormalization = true,
            ),
            tokens = tokensPath,
            numThreads = threads,
            debug = false,
            provider = provider,
        )

        return OfflineRecognizerConfig(
            featConfig = FeatureConfig(sampleRate = 16000, featureDim = 80),
            modelConfig = modelConfig,
            decodingMethod = "greedy_search",
        )
    }

    private fun computeOfflineThreads(): Int {
        val cores = Runtime.getRuntime().availableProcessors().coerceAtLeast(1)
        return when {
            cores <= 2 -> 1
            cores <= 4 -> 2
            else -> 4
        }
    }

    /** Find the int8 version of a model file, falling back to the non-quantized version. */
    private fun findFile(dir: String, baseName: String): String {
        val int8 = File(dir, "$baseName.int8.onnx")
        if (int8.exists()) return int8.absolutePath
        return File(dir, "$baseName.onnx").absolutePath
    }

    private fun buildSegments(
        text: String,
        timestamps: FloatArray?,
        detectedLanguage: String? = null
    ): List<TranscriptionSegment> {
        if (timestamps != null && timestamps.size >= 2) {
            val startMs = (timestamps.first() * 1000).toLong()
            val endMs = (timestamps.last() * 1000).toLong()
            return listOf(TranscriptionSegment(
                text = text.trim(), startMs = startMs, endMs = endMs,
                detectedLanguage = detectedLanguage
            ))
        }
        return listOf(TranscriptionSegment(
            text = text.trim(), startMs = 0, endMs = 0,
            detectedLanguage = detectedLanguage
        ))
    }
}
