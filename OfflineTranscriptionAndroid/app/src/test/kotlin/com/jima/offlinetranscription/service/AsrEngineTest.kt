package com.voiceping.offlinetranscription.service

import com.voiceping.offlinetranscription.model.EngineType
import com.voiceping.offlinetranscription.model.ModelInfo
import com.voiceping.offlinetranscription.model.SherpaModelType
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Tests for the ASR engine abstraction layer: interface contract,
 * engine type mapping, and model→engine resolution.
 */
class AsrEngineTest {

    // -- Interface contract --

    @Test
    fun asrEngine_interfaceHasExpectedMethods() {
        // Compile-time verification that the interface exists with expected shape.
        // A no-op implementation proves the contract is well-defined.
        val engine = object : AsrEngine {
            override suspend fun loadModel(modelPath: String) = false
            override suspend fun transcribe(
                audioSamples: FloatArray, numThreads: Int, language: String
            ) = emptyList<TranscriptionSegment>()
            override val isLoaded: Boolean get() = false
            override fun release() {}
        }
        assertFalse(engine.isLoaded)
    }

    @Test
    fun noOpEngine_release_doesNotThrow() {
        val engine = object : AsrEngine {
            override suspend fun loadModel(modelPath: String) = false
            override suspend fun transcribe(
                audioSamples: FloatArray, numThreads: Int, language: String
            ) = emptyList<TranscriptionSegment>()
            override val isLoaded: Boolean get() = false
            override fun release() {}
        }
        engine.release() // Should not throw
    }

    // -- Engine type to model mapping --

    @Test
    fun allWhisperCppModels_haveNullSherpaModelType() {
        ModelInfo.availableModels
            .filter { it.engineType == EngineType.WHISPER_CPP }
            .forEach { model ->
                assertEquals(null, model.sherpaModelType, "whisper.cpp model ${model.id} should have null sherpaModelType")
            }
    }

    @Test
    fun allSherpaOnnxModels_haveNonNullSherpaModelType() {
        ModelInfo.availableModels
            .filter { it.engineType == EngineType.SHERPA_ONNX }
            .forEach { model ->
                assertNotNull(model.sherpaModelType, "sherpa-onnx model ${model.id} should have non-null sherpaModelType")
            }
    }

    @Test
    fun engineTypes_coverAllModels() {
        val validTypes = setOf(EngineType.WHISPER_CPP, EngineType.SHERPA_ONNX, EngineType.SHERPA_ONNX_STREAMING)
        ModelInfo.availableModels.forEach { model ->
            assertTrue(
                model.engineType in validTypes,
                "Model ${model.id} has unexpected engine type: ${model.engineType}"
            )
        }
    }

    // -- Streaming interface defaults --

    @Test
    fun asrEngine_isStreaming_defaultsFalse() {
        val engine = object : AsrEngine {
            override suspend fun loadModel(modelPath: String) = false
            override suspend fun transcribe(
                audioSamples: FloatArray, numThreads: Int, language: String
            ) = emptyList<TranscriptionSegment>()
            override val isLoaded: Boolean get() = false
            override fun release() {}
        }
        assertFalse(engine.isStreaming)
    }

    @Test
    fun asrEngine_streamingDefaults_doNotThrow() {
        val engine = object : AsrEngine {
            override suspend fun loadModel(modelPath: String) = false
            override suspend fun transcribe(
                audioSamples: FloatArray, numThreads: Int, language: String
            ) = emptyList<TranscriptionSegment>()
            override val isLoaded: Boolean get() = false
            override fun release() {}
        }
        // All streaming defaults should be safe no-ops
        engine.feedAudio(floatArrayOf(0.1f, 0.2f))
        assertEquals(null, engine.getStreamingResult())
        assertFalse(engine.isEndpointDetected())
        engine.resetStreamingState()
    }

    @Test
    fun sherpaOnnxStreamingModels_haveNonNullSherpaModelType() {
        ModelInfo.availableModels
            .filter { it.engineType == EngineType.SHERPA_ONNX_STREAMING }
            .forEach { model ->
                assertNotNull(model.sherpaModelType, "streaming model ${model.id} should have non-null sherpaModelType")
            }
    }

    @Test
    fun zipformerModels_haveRequiredOnnxFiles() {
        val zipformerModels = ModelInfo.availableModels.filter { it.sherpaModelType == SherpaModelType.ZIPFORMER_TRANSDUCER }
        assertTrue(zipformerModels.isNotEmpty())
        zipformerModels.forEach { model ->
            val names = model.files.map { it.localName }.toSet()
            assertTrue(names.any { it.contains("encoder") && it.endsWith(".onnx") }, "Zipformer ${model.id} needs encoder")
            assertTrue(names.any { it.contains("decoder") && it.endsWith(".onnx") }, "Zipformer ${model.id} needs decoder")
            assertTrue(names.any { it.contains("joiner") && it.endsWith(".onnx") }, "Zipformer ${model.id} needs joiner")
            assertTrue("tokens.txt" in names, "Zipformer ${model.id} needs tokens.txt")
        }
    }

    // -- Model-to-engine resolution --

    @Test
    fun whisperCppModels_shouldUseWhisperCppEngine() {
        val whisperModels = ModelInfo.availableModels.filter { it.engineType == EngineType.WHISPER_CPP }
        assertTrue(whisperModels.isNotEmpty(), "Should have at least one WHISPER_CPP model")
        whisperModels.forEach { model ->
            assertEquals(EngineType.WHISPER_CPP, model.engineType)
            // These models have single .bin files
            assertEquals(1, model.files.size, "${model.id} should have single file")
            assertTrue(model.files.first().localName.endsWith(".bin"))
        }
    }

    @Test
    fun sherpaOnnxModels_shouldUseSherpaOnnxEngine() {
        val sherpaModels = ModelInfo.availableModels.filter { it.engineType == EngineType.SHERPA_ONNX }
        assertTrue(sherpaModels.isNotEmpty(), "Should have at least one SHERPA_ONNX model")
        sherpaModels.forEach { model ->
            assertEquals(EngineType.SHERPA_ONNX, model.engineType)
            // All sherpa-onnx models need tokens.txt
            assertTrue(
                model.files.any { it.localName == "tokens.txt" },
                "${model.id} should include tokens.txt"
            )
        }
    }

    @Test
    fun moonshineModels_haveRequiredOnnxFiles() {
        val moonshineModels = ModelInfo.availableModels.filter { it.sherpaModelType == SherpaModelType.MOONSHINE }
        assertTrue(moonshineModels.isNotEmpty())
        moonshineModels.forEach { model ->
            val names = model.files.map { it.localName }.toSet()
            assertTrue("preprocess.onnx" in names, "Moonshine ${model.id} needs preprocess.onnx")
            assertTrue(names.any { it.contains("encode") && it.endsWith(".onnx") }, "Moonshine ${model.id} needs encoder")
            assertTrue(names.any { it.contains("uncached_decode") && it.endsWith(".onnx") }, "Moonshine ${model.id} needs uncached_decoder")
            assertTrue(names.any { it.contains("cached_decode") && it.endsWith(".onnx") }, "Moonshine ${model.id} needs cached_decoder")
        }
    }

    @Test
    fun sensevoiceModels_haveRequiredOnnxFiles() {
        val svModels = ModelInfo.availableModels.filter { it.sherpaModelType == SherpaModelType.SENSE_VOICE }
        assertTrue(svModels.isNotEmpty())
        svModels.forEach { model ->
            val names = model.files.map { it.localName }.toSet()
            assertTrue(names.any { it.contains("model") && it.endsWith(".onnx") }, "SenseVoice ${model.id} needs model.onnx")
            assertTrue("tokens.txt" in names, "SenseVoice ${model.id} needs tokens.txt")
        }
    }

    @Test
    fun omnilingualModels_haveRequiredOnnxFiles() {
        val omniModels = ModelInfo.availableModels.filter { it.sherpaModelType == SherpaModelType.OMNILINGUAL_CTC }
        assertTrue(omniModels.isNotEmpty())
        omniModels.forEach { model ->
            val names = model.files.map { it.localName }.toSet()
            assertTrue("model.int8.onnx" in names, "Omnilingual ${model.id} needs model.int8.onnx")
            assertTrue("tokens.txt" in names, "Omnilingual ${model.id} needs tokens.txt")
        }
    }
}
