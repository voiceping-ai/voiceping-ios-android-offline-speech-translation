package com.voiceping.offlinetranscription.service

import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import com.voiceping.offlinetranscription.model.ModelInfo
import kotlinx.coroutines.flow.last
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Before
import org.junit.Test
import java.io.File
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Instrumented test that downloads, loads, and transcribes a test WAV file
 * with every available model. Runs on a connected device.
 *
 * Expected transcript (JFK): "ask not what your country can do for you
 * ask what you can do for your country"
 */
class AllModelsTranscribeTest {
    companion object {
        private const val TAG = "AllModelsTest"
        private const val WAV_PATH = "/data/local/tmp/test_speech.wav"
    }

    private lateinit var modelsDir: File
    private lateinit var downloader: ModelDownloader
    private var currentEngine: AsrEngine? = null

    @Before
    fun setUp() {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        modelsDir = File(ctx.filesDir, "models")
        downloader = ModelDownloader(modelsDir)
    }

    @After
    fun tearDown() {
        currentEngine?.release()
        currentEngine = null
    }

    // ---- Individual model tests ----

    @Test
    fun test_sensevoiceSmall() = testModel("sensevoice-small")

    // ---- Core test logic ----

    private fun testModel(modelId: String): Unit = runBlocking {
        val model = ModelInfo.availableModels.find { it.id == modelId }
            ?: fail("Model $modelId not found in availableModels")

        Log.i(TAG, "=== Testing $modelId ===")

        // 1. Download model if needed
        if (!downloader.isModelDownloaded(model)) {
            Log.i(TAG, "[$modelId] Downloading...")
            downloader.download(model).last()
            Log.i(TAG, "[$modelId] Download complete")
        }
        assertTrue(downloader.isModelDownloaded(model), "[$modelId] Model should be downloaded")

        // 2. Create engine
        val engine = SherpaOnnxEngine(modelType = model.sherpaModelType!!)
        currentEngine = engine

        // 3. Load model
        val modelPath = downloader.modelDir(model).absolutePath
        Log.i(TAG, "[$modelId] Loading from $modelPath")
        val loaded = engine.loadModel(modelPath)
        assertTrue(loaded, "[$modelId] Model failed to load")
        assertTrue(engine.isLoaded, "[$modelId] Engine should report isLoaded=true")

        // 4. Read WAV file
        val wavFile = File(WAV_PATH)
        assertTrue(wavFile.exists(), "Test WAV file not found at $WAV_PATH")
        val audioSamples = readWav16kMono(wavFile)
        assertTrue(audioSamples.isNotEmpty(), "[$modelId] WAV file should produce audio samples")
        val durationSec = audioSamples.size / 16000.0
        Log.i(TAG, "[$modelId] Audio: ${audioSamples.size} samples (${String.format("%.1f", durationSec)}s)")

        // 5. Transcribe
        val startMs = System.currentTimeMillis()
        val segments = engine.transcribe(audioSamples, numThreads = 4, language = "en")
        val elapsedMs = System.currentTimeMillis() - startMs
        val text = segments.joinToString(" ") { it.text }.trim().lowercase()

        Log.i(TAG, "[$modelId] Result (${elapsedMs}ms): \"$text\"")
        Log.i(TAG, "[$modelId] Segments: ${segments.size}, RTF: ${String.format("%.3f", elapsedMs / 1000.0 / durationSec)}")

        // 6. Verify transcription contains expected words
        assertTrue(text.isNotEmpty(), "[$modelId] Transcription should not be empty")
        assertTrue(
            text.contains("country") || text.contains("ask") || text.contains("do for"),
            "[$modelId] Expected JFK speech content, got: \"$text\""
        )

        // 7. Release
        engine.release()
        currentEngine = null
        Log.i(TAG, "[$modelId] PASSED")
    }

    /** Read a 16kHz mono PCM16 WAV file into a float array [-1, 1]. */
    private fun readWav16kMono(file: File): FloatArray {
        val bytes = file.readBytes()
        // Find "data" chunk
        var pos = 12
        while (pos + 8 <= bytes.size) {
            val chunkId = String(bytes, pos, 4, Charsets.US_ASCII)
            val chunkSize = java.nio.ByteBuffer.wrap(bytes, pos + 4, 4)
                .order(java.nio.ByteOrder.LITTLE_ENDIAN).int
            if (chunkId == "data") {
                val dataOffset = pos + 8
                val dataSize = chunkSize.coerceAtMost(bytes.size - dataOffset)
                val sampleCount = dataSize / 2
                return FloatArray(sampleCount) { i ->
                    val off = dataOffset + i * 2
                    val low = bytes[off].toInt() and 0xFF
                    val high = bytes[off + 1].toInt()
                    (high shl 8 or low).toFloat() / 32768f
                }
            }
            pos += 8 + chunkSize
            if (chunkSize % 2 != 0) pos++
        }
        return floatArrayOf()
    }
}
