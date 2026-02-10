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
 * Tests for the ASR engine abstraction and model-to-engine mapping.
 */
class AsrEngineTest {

    @Test
    fun asrEngine_interfaceContract_isValid() {
        val engine = object : AsrEngine {
            override suspend fun loadModel(modelPath: String) = false
            override suspend fun transcribe(
                audioSamples: FloatArray,
                numThreads: Int,
                language: String
            ) = emptyList<TranscriptionSegment>()
            override val isLoaded: Boolean get() = false
            override fun release() {}
        }

        assertFalse(engine.isLoaded)
        engine.release()
    }

    @Test
    fun allCurrentModels_areSherpaOfflineAndTyped() {
        val models = ModelInfo.availableModels
        assertTrue(models.isNotEmpty())
        models.forEach { model ->
            assertEquals(EngineType.SHERPA_ONNX, model.engineType, "Unexpected engine for ${model.id}")
            assertNotNull(model.sherpaModelType, "sherpaModelType must be set for ${model.id}")
            assertTrue(
                model.files.any { it.localName == "tokens.txt" },
                "tokens.txt is required for ${model.id}"
            )
        }
    }

    @Test
    fun sensevoiceModel_mapsToSenseVoiceType() {
        val model = ModelInfo.availableModels.first { it.id == "sensevoice-small" }
        assertEquals(SherpaModelType.SENSE_VOICE, model.sherpaModelType)
        val names = model.files.map { it.localName }.toSet()
        assertTrue("model.int8.onnx" in names)
        assertTrue("tokens.txt" in names)
    }
}
