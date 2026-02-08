package com.voiceping.offlinetranscription.service

import android.util.Log
import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.OnlineModelConfig
import com.k2fsa.sherpa.onnx.OnlineRecognizer
import com.k2fsa.sherpa.onnx.OnlineRecognizerConfig
import com.k2fsa.sherpa.onnx.OnlineStream
import com.k2fsa.sherpa.onnx.OnlineTransducerModelConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * ASR engine backed by sherpa-onnx OnlineRecognizer for real-time streaming
 * transcription (Zipformer transducer).
 *
 * Audio is fed incrementally via [feedAudio]. A single-thread executor
 * serialises decode work so that the recognizer is never accessed concurrently.
 */
class SherpaOnnxStreamingEngine : AsrEngine {
    companion object {
        private const val TAG = "SherpaOnnxStreaming"
    }

    private var recognizer: OnlineRecognizer? = null
    private var stream: OnlineStream? = null
    private val lock = ReentrantLock()
    private var decodeExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    @Volatile
    private var latestText: String = ""

    override val isLoaded: Boolean get() = lock.withLock { recognizer != null }
    override val isStreaming: Boolean get() = true

    override suspend fun loadModel(modelPath: String): Boolean {
        release()
        return withContext(Dispatchers.IO) {
            lock.withLock {
                decodeExecutor = Executors.newSingleThreadExecutor()
                try {
                    val tokensPath = File(modelPath, "tokens.txt").absolutePath
                    val encoderPath = findFile(modelPath, "encoder")
                    val decoderPath = findFile(modelPath, "decoder")
                    val joinerPath = findFile(modelPath, "joiner")

                    val transducerConfig = OnlineTransducerModelConfig(
                        encoder = encoderPath,
                        decoder = decoderPath,
                        joiner = joinerPath,
                    )

                    val modelConfig = OnlineModelConfig(
                        transducer = transducerConfig,
                        tokens = tokensPath,
                        numThreads = 2,
                        debug = false,
                        provider = "cpu",
                    )

                    val config = OnlineRecognizerConfig(
                        featConfig = FeatureConfig(sampleRate = 16000, featureDim = 80),
                        modelConfig = modelConfig,
                        enableEndpoint = true,
                        decodingMethod = "greedy_search",
                    )

                    val rec = OnlineRecognizer(config = config)
                    recognizer = rec
                    stream = rec.createStream()
                    true
                } catch (e: Throwable) {
                    Log.e(TAG, "Failed to load streaming model from $modelPath", e)
                    recognizer = null
                    stream = null
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
        // Batch fallback: feed all audio, signal finished, decode, return result.
        return withContext(Dispatchers.IO) {
            lock.withLock {
                val rec = recognizer ?: return@withContext emptyList()
                val s = rec.createStream()
                try {
                    // sherpa-onnx Kotlin API expects float samples in [-1, 1] range
                    s.acceptWaveform(audioSamples, sampleRate = 16000)
                    s.inputFinished()
                    while (rec.isReady(s)) {
                        rec.decode(s)
                    }
                    val result = rec.getResult(s)
                    Log.d(TAG, "Batch result text='${result.text}', tokens=${result.tokens?.size ?: 0}")
                    if (result.text.isBlank()) emptyList()
                    else listOf(TranscriptionSegment(text = result.text.trim(), startMs = 0, endMs = 0))
                } catch (e: Throwable) {
                    Log.e(TAG, "Batch transcribe failed", e)
                    emptyList()
                } finally {
                    s.release()
                }
            }
        }
    }

    // -- Streaming methods --

    override fun feedAudio(samples: FloatArray) {
        decodeExecutor.execute {
            lock.withLock {
                val rec = recognizer ?: return@execute
                val s = stream ?: return@execute
                try {
                    // sherpa-onnx Kotlin API expects float samples in [-1, 1] range
                    s.acceptWaveform(samples, sampleRate = 16000)
                    while (rec.isReady(s)) {
                        rec.decode(s)
                    }
                    latestText = rec.getResult(s).text
                } catch (e: Throwable) {
                    Log.e(TAG, "Streaming decode error", e)
                }
            }
        }
    }

    override fun getStreamingResult(): TranscriptionSegment? {
        val text = latestText.trim()
        if (text.isEmpty()) return null
        return TranscriptionSegment(text = text, startMs = 0, endMs = 0)
    }

    override fun isEndpointDetected(): Boolean {
        return lock.withLock {
            val rec = recognizer ?: return false
            val s = stream ?: return false
            try {
                rec.isEndpoint(s)
            } catch (e: Throwable) {
                false
            }
        }
    }

    override fun resetStreamingState() {
        lock.withLock {
            val rec = recognizer ?: return
            val s = stream ?: return
            try {
                rec.reset(s)
            } catch (e: Throwable) {
                Log.e(TAG, "Reset streaming state failed", e)
            }
            latestText = ""
        }
    }

    override fun release() {
        decodeExecutor.shutdown()
        try {
            if (!decodeExecutor.awaitTermination(2, TimeUnit.SECONDS)) {
                decodeExecutor.shutdownNow()
            }
        } catch (_: InterruptedException) {
            decodeExecutor.shutdownNow()
        }
        lock.withLock {
            stream?.release()
            stream = null
            recognizer?.release()
            recognizer = null
            latestText = ""
        }
    }

    /** Find the int8 version of a model file, falling back to the non-quantized version. */
    private fun findFile(dir: String, baseName: String): String {
        // Try exact match with int8 suffix first
        val int8 = File(dir).listFiles()?.firstOrNull {
            it.name.contains(baseName) && it.name.contains("int8") && it.name.endsWith(".onnx")
        }
        if (int8 != null) return int8.absolutePath

        // Fall back to any file containing the base name
        val fallback = File(dir).listFiles()?.firstOrNull {
            it.name.contains(baseName) && it.name.endsWith(".onnx")
        }
        if (fallback != null) return fallback.absolutePath

        // Last resort: construct expected path
        return File(dir, "$baseName.onnx").absolutePath
    }
}
