package com.voiceping.offlinetranscription.service

import android.util.Log
import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineMoonshineModelConfig
import com.k2fsa.sherpa.onnx.OfflineOmnilingualAsrCtcModelConfig
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
 * ASR engine backed by sherpa-onnx for Moonshine, SenseVoice, and Omnilingual models.
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
                try {
                    val config = buildConfig(modelPath)
                    recognizer = OfflineRecognizer(config = config)
                    true
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
                val stream = rec.createStream()
                try {
                    stream.acceptWaveform(audioSamples, sampleRate = 16000)
                    rec.decode(stream)
                    val result = rec.getResult(stream)

                    if (result.text.isBlank()) return@withContext emptyList()

                    val lang = result.lang.takeIf { it.isNotBlank() }
                    buildSegments(result.text, result.timestamps, lang)
                } catch (e: Throwable) {
                    Log.e(TAG, "Sherpa transcribe failed", e)
                    emptyList()
                } finally {
                    stream.release()
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

    private fun buildConfig(modelDir: String): OfflineRecognizerConfig {
        val tokensPath = File(modelDir, "tokens.txt").absolutePath
        val threads = Runtime.getRuntime().availableProcessors().coerceAtMost(4)

        val modelConfig = when (modelType) {
            SherpaModelType.MOONSHINE -> OfflineModelConfig(
                moonshine = OfflineMoonshineModelConfig(
                    preprocessor = File(modelDir, "preprocess.onnx").absolutePath,
                    encoder = findFile(modelDir, "encode"),
                    uncachedDecoder = findFile(modelDir, "uncached_decode"),
                    cachedDecoder = findFile(modelDir, "cached_decode"),
                ),
                tokens = tokensPath,
                numThreads = threads,
                debug = false,
                provider = "cpu",
            )
            SherpaModelType.ZIPFORMER_TRANSDUCER -> throw IllegalArgumentException(
                "ZIPFORMER_TRANSDUCER should use SherpaOnnxStreamingEngine, not SherpaOnnxEngine"
            )
            SherpaModelType.SENSE_VOICE -> OfflineModelConfig(
                senseVoice = OfflineSenseVoiceModelConfig(
                    model = findFile(modelDir, "model"),
                    language = "auto",
                    useInverseTextNormalization = true,
                ),
                tokens = tokensPath,
                numThreads = threads,
                debug = false,
                provider = "cpu",
            )
            SherpaModelType.OMNILINGUAL_CTC -> OfflineModelConfig(
                omnilingual = OfflineOmnilingualAsrCtcModelConfig(
                    model = findFile(modelDir, "model"),
                ),
                tokens = tokensPath,
                numThreads = threads,
                debug = false,
                provider = "cpu",
            )
        }

        return OfflineRecognizerConfig(
            featConfig = FeatureConfig(sampleRate = 16000, featureDim = 80),
            modelConfig = modelConfig,
            decodingMethod = "greedy_search",
        )
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
