package com.voiceping.offlinetranscription.model

import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ModelInfoTest {

    @Test
    fun availableModels_hasExpectedEntries() {
        val ids = ModelInfo.availableModels.map { it.id }
        assertEquals(3, ids.size)
        assertTrue("sensevoice-small" in ids)
        assertTrue("parakeet-tdt-0.6b-v2-int8" in ids)
        assertTrue("tinyllama-1.1b-ik-llama-cpp" in ids)
    }

    @Test
    fun defaultModel_isSenseVoiceSmall() {
        assertEquals("sensevoice-small", ModelInfo.defaultModel.id)
        assertEquals(EngineType.SHERPA_ONNX, ModelInfo.defaultModel.engineType)
        assertEquals(SherpaModelType.SENSE_VOICE, ModelInfo.defaultModel.sherpaModelType)
    }

    @Test
    fun modelIds_areUnique() {
        val ids = ModelInfo.availableModels.map { it.id }
        assertEquals(ids.size, ids.toSet().size, "Model IDs must be unique")
    }

    @Test
    fun sensevoiceModel_hasExpectedFilesAndMetadata() {
        val model = ModelInfo.availableModels.first { it.id == "sensevoice-small" }
        assertEquals("SenseVoice Small", model.displayName)
        assertEquals(EngineType.SHERPA_ONNX, model.engineType)
        assertEquals(SherpaModelType.SENSE_VOICE, model.sherpaModelType)
        assertEquals("zh/en/ja/ko/yue", model.languages)
        assertEquals(2, model.files.size)

        val names = model.files.map { it.localName }.toSet()
        assertTrue("model.int8.onnx" in names)
        assertTrue("tokens.txt" in names)
    }

    @Test
    fun parakeetModel_hasExpectedFilesAndMetadata() {
        val model = ModelInfo.availableModels.first { it.id == "parakeet-tdt-0.6b-v2-int8" }
        assertEquals("Parakeet TDT 0.6B", model.displayName)
        assertEquals(EngineType.SHERPA_ONNX, model.engineType)
        assertEquals(SherpaModelType.PARAKEET_NEMO_TRANSDUCER, model.sherpaModelType)
        assertEquals("English", model.languages)
        assertEquals(4, model.files.size)

        val names = model.files.map { it.localName }.toSet()
        assertTrue("encoder.int8.onnx" in names)
        assertTrue("decoder.int8.onnx" in names)
        assertTrue("joiner.int8.onnx" in names)
        assertTrue("tokens.txt" in names)
    }

    @Test
    fun allFiles_haveHttpsHuggingFaceUrls() {
        ModelInfo.availableModels.forEach { model ->
            model.files.forEach { file ->
                assertTrue(file.url.startsWith("https://"), "URL should be HTTPS for ${model.id}:${file.localName}")
                assertTrue(file.url.contains("huggingface.co"), "URL should be HuggingFace for ${model.id}:${file.localName}")
            }
        }
    }

    @Test
    fun modelsByEngine_groupsSherpaModels() {
        val grouped = ModelInfo.modelsByEngine
        val sherpa = grouped[EngineType.SHERPA_ONNX]
        assertNotNull(sherpa)
        assertEquals(3, sherpa.size)
        assertTrue(sherpa.any { it.id == "sensevoice-small" })
        assertTrue(sherpa.any { it.id == "parakeet-tdt-0.6b-v2-int8" })
        assertTrue(sherpa.any { it.id == "tinyllama-1.1b-ik-llama-cpp" })
        assertNull(grouped[EngineType.WHISPER_CPP])
        assertNull(grouped[EngineType.SHERPA_ONNX_STREAMING])
    }

    @Test
    fun inferenceMethodLabel_isEngineSpecific() {
        val model = ModelInfo.availableModels.first()
        assertEquals("sherpa-onnx offline (ONNX Runtime)", model.inferenceMethod)
    }

    @Test
    fun enumCardinality_isExpected() {
        assertEquals(3, EngineType.entries.size)
        assertEquals(5, SherpaModelType.entries.size)
    }

    @Test
    fun dataClassEquality_stillWorks() {
        val a = ModelInfo(
            id = "test",
            displayName = "Test",
            engineType = EngineType.WHISPER_CPP,
            sherpaModelType = null,
            parameterCount = "1M",
            sizeOnDisk = "~1 MB",
            description = "desc",
            files = listOf(ModelFile("https://huggingface.co/test.bin", "test.bin"))
        )
        val b = a.copy()
        assertEquals(a, b)
    }

    @Test
    fun ikLlamaCard_isInformationalOnly() {
        val model = ModelInfo.availableModels.first { it.id == "tinyllama-1.1b-ik-llama-cpp" }
        assertEquals(false, model.isSelectable)
        assertEquals(0, model.files.size)
        assertTrue(model.inferenceMethod.contains("ik_llama.cpp"))
        assertNotNull(model.availabilityNote)
    }
}
