package com.voiceping.offlinetranscription.model

import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ModelInfoTest {

    @Test
    fun availableModels_hasElevenEntries() {
        assertEquals(11, ModelInfo.availableModels.size)
    }

    @Test
    fun defaultModel_isWhisperBase() {
        assertEquals("whisper-base", ModelInfo.defaultModel.id)
        assertEquals("Whisper Base", ModelInfo.defaultModel.displayName)
        assertEquals(EngineType.WHISPER_CPP, ModelInfo.defaultModel.engineType)
    }

    @Test
    fun availableModels_containsExpectedIds() {
        val ids = ModelInfo.availableModels.map { it.id }
        assertTrue("whisper-tiny" in ids)
        assertTrue("whisper-base" in ids)
        assertTrue("whisper-base-en" in ids)
        assertTrue("whisper-small" in ids)
        assertTrue("whisper-large-v3-turbo" in ids)
        assertTrue("whisper-large-v3-turbo-compressed" in ids)
        assertTrue("moonshine-tiny" in ids)
        assertTrue("moonshine-base" in ids)
        assertTrue("sensevoice-small" in ids)
        assertTrue("omnilingual-300m" in ids)
        assertTrue("zipformer-20m" in ids)
    }

    @Test
    fun modelIds_areUnique() {
        val ids = ModelInfo.availableModels.map { it.id }
        assertEquals(ids.size, ids.toSet().size, "Model IDs must be unique")
    }

    // -- Engine type classification --

    @Test
    fun whisperModels_haveWhisperCppEngineType() {
        ModelInfo.availableModels
            .filter { it.id.startsWith("whisper-") }
            .forEach { model ->
                assertEquals(EngineType.WHISPER_CPP, model.engineType, "Expected WHISPER_CPP for ${model.id}")
                assertNull(model.sherpaModelType, "sherpaModelType should be null for ${model.id}")
            }
    }

    @Test
    fun moonshineModels_haveSherpaOnnxEngine_andMoonshineType() {
        ModelInfo.availableModels
            .filter { it.id.startsWith("moonshine-") }
            .forEach { model ->
                assertEquals(EngineType.SHERPA_ONNX, model.engineType, "Expected SHERPA_ONNX for ${model.id}")
                assertEquals(SherpaModelType.MOONSHINE, model.sherpaModelType, "Expected MOONSHINE for ${model.id}")
            }
    }

    @Test
    fun sensevoiceModels_haveSherpaOnnxEngine_andSenseVoiceType() {
        ModelInfo.availableModels
            .filter { it.id.startsWith("sensevoice-") }
            .forEach { model ->
                assertEquals(EngineType.SHERPA_ONNX, model.engineType, "Expected SHERPA_ONNX for ${model.id}")
                assertEquals(SherpaModelType.SENSE_VOICE, model.sherpaModelType, "Expected SENSE_VOICE for ${model.id}")
            }
    }

    @Test
    fun omnilingualModels_haveSherpaOnnxEngine_andOmnilingualType() {
        ModelInfo.availableModels
            .filter { it.id.startsWith("omnilingual-") }
            .forEach { model ->
                assertEquals(EngineType.SHERPA_ONNX, model.engineType, "Expected SHERPA_ONNX for ${model.id}")
                assertEquals(SherpaModelType.OMNILINGUAL_CTC, model.sherpaModelType, "Expected OMNILINGUAL_CTC for ${model.id}")
            }
    }

    @Test
    fun zipformerModels_haveSherpaOnnxStreamingEngine_andTransducerType() {
        ModelInfo.availableModels
            .filter { it.id.startsWith("zipformer-") }
            .forEach { model ->
                assertEquals(EngineType.SHERPA_ONNX_STREAMING, model.engineType, "Expected SHERPA_ONNX_STREAMING for ${model.id}")
                assertEquals(SherpaModelType.ZIPFORMER_TRANSDUCER, model.sherpaModelType, "Expected ZIPFORMER_TRANSDUCER for ${model.id}")
            }
    }

    // -- File lists --

    @Test
    fun whisperModels_haveSingleFile() {
        ModelInfo.availableModels
            .filter { it.engineType == EngineType.WHISPER_CPP }
            .forEach { model ->
                assertEquals(1, model.files.size, "${model.id} should have exactly 1 file")
                assertTrue(model.files.first().localName.endsWith(".bin"))
            }
    }

    @Test
    fun moonshineModels_haveFiveFiles() {
        ModelInfo.availableModels
            .filter { it.sherpaModelType == SherpaModelType.MOONSHINE }
            .forEach { model ->
                assertEquals(5, model.files.size, "${model.id} should have 5 files")
                val names = model.files.map { it.localName }
                assertTrue("preprocess.onnx" in names, "Missing preprocess.onnx in ${model.id}")
                assertTrue("encode.int8.onnx" in names, "Missing encode.int8.onnx in ${model.id}")
                assertTrue("uncached_decode.int8.onnx" in names)
                assertTrue("cached_decode.int8.onnx" in names)
                assertTrue("tokens.txt" in names, "Missing tokens.txt in ${model.id}")
            }
    }

    @Test
    fun sensevoiceModels_haveTwoFiles() {
        ModelInfo.availableModels
            .filter { it.sherpaModelType == SherpaModelType.SENSE_VOICE }
            .forEach { model ->
                assertEquals(2, model.files.size, "${model.id} should have 2 files")
                val names = model.files.map { it.localName }
                assertTrue("model.int8.onnx" in names, "Missing model.int8.onnx in ${model.id}")
                assertTrue("tokens.txt" in names, "Missing tokens.txt in ${model.id}")
            }
    }

    @Test
    fun omnilingualModels_haveTwoFiles() {
        ModelInfo.availableModels
            .filter { it.sherpaModelType == SherpaModelType.OMNILINGUAL_CTC }
            .forEach { model ->
                assertEquals(2, model.files.size, "${model.id} should have 2 files")
                val names = model.files.map { it.localName }
                assertTrue("model.int8.onnx" in names, "Missing model.int8.onnx in ${model.id}")
                assertTrue("tokens.txt" in names, "Missing tokens.txt in ${model.id}")
            }
    }

    @Test
    fun zipformerModels_haveFourFiles() {
        ModelInfo.availableModels
            .filter { it.sherpaModelType == SherpaModelType.ZIPFORMER_TRANSDUCER }
            .forEach { model ->
                assertEquals(4, model.files.size, "${model.id} should have 4 files")
                val names = model.files.map { it.localName }
                assertTrue(names.any { it.contains("encoder") && it.endsWith(".onnx") }, "Missing encoder in ${model.id}")
                assertTrue(names.any { it.contains("decoder") && it.endsWith(".onnx") }, "Missing decoder in ${model.id}")
                assertTrue(names.any { it.contains("joiner") && it.endsWith(".onnx") }, "Missing joiner in ${model.id}")
                assertTrue("tokens.txt" in names, "Missing tokens.txt in ${model.id}")
            }
    }

    @Test
    fun allFiles_haveValidUrls() {
        ModelInfo.availableModels.forEach { model ->
            model.files.forEach { file ->
                assertTrue(file.url.startsWith("https://"), "URL should start with https:// for ${file.localName} in ${model.id}")
                assertTrue(file.url.contains("huggingface.co"), "URL should be on huggingface for ${file.localName} in ${model.id}")
            }
        }
    }

    @Test
    fun allFiles_haveNonEmptyLocalName() {
        ModelInfo.availableModels.forEach { model ->
            model.files.forEach { file ->
                assertTrue(file.localName.isNotEmpty(), "localName should not be empty in ${model.id}")
            }
        }
    }

    // -- Metadata completeness --

    @Test
    fun eachModel_hasNonEmptyDisplayName() {
        ModelInfo.availableModels.forEach { model ->
            assertTrue(model.displayName.isNotEmpty(), "displayName should not be empty for ${model.id}")
        }
    }

    @Test
    fun eachModel_hasNonEmptyDescription() {
        ModelInfo.availableModels.forEach { model ->
            assertTrue(model.description.isNotEmpty(), "description should not be empty for ${model.id}")
        }
    }

    @Test
    fun eachModel_hasNonEmptyParameterCount() {
        ModelInfo.availableModels.forEach { model ->
            assertTrue(model.parameterCount.isNotEmpty(), "parameterCount should not be empty for ${model.id}")
        }
    }

    @Test
    fun eachModel_hasNonEmptySizeOnDisk() {
        ModelInfo.availableModels.forEach { model ->
            assertTrue(model.sizeOnDisk.isNotEmpty(), "sizeOnDisk should not be empty for ${model.id}")
        }
    }

    // -- Grouped display --

    @Test
    fun modelsByEngine_containsAllEngineTypes() {
        val grouped = ModelInfo.modelsByEngine
        assertTrue(grouped.containsKey(EngineType.WHISPER_CPP))
        assertTrue(grouped.containsKey(EngineType.SHERPA_ONNX))
        assertTrue(grouped.containsKey(EngineType.SHERPA_ONNX_STREAMING))
    }

    @Test
    fun modelsByEngine_whisperCpp_hasSixModels() {
        val whisperModels = ModelInfo.modelsByEngine[EngineType.WHISPER_CPP]
        assertNotNull(whisperModels)
        assertEquals(6, whisperModels.size)
    }

    @Test
    fun modelsByEngine_sherpaOnnx_hasFourModels() {
        val sherpaModels = ModelInfo.modelsByEngine[EngineType.SHERPA_ONNX]
        assertNotNull(sherpaModels)
        assertEquals(4, sherpaModels.size)
    }

    @Test
    fun modelsByEngine_sherpaOnnxStreaming_hasOneModel() {
        val streamingModels = ModelInfo.modelsByEngine[EngineType.SHERPA_ONNX_STREAMING]
        assertNotNull(streamingModels)
        assertEquals(1, streamingModels.size)
        assertEquals("zipformer-20m", streamingModels.first().id)
    }

    // -- Data class behavior --

    @Test
    fun modelInfo_isDataClass_equalityWorks() {
        val a = ModelInfo(
            id = "test", displayName = "Test", engineType = EngineType.WHISPER_CPP,
            parameterCount = "1M", sizeOnDisk = "~1 MB", description = "A test model.",
            files = listOf(ModelFile("https://example.com/test.bin", "test.bin"))
        )
        val b = ModelInfo(
            id = "test", displayName = "Test", engineType = EngineType.WHISPER_CPP,
            parameterCount = "1M", sizeOnDisk = "~1 MB", description = "A test model.",
            files = listOf(ModelFile("https://example.com/test.bin", "test.bin"))
        )
        assertEquals(a, b)
    }

    @Test
    fun modelInfo_isDataClass_copyWorks() {
        val original = ModelInfo.defaultModel
        val copied = original.copy(id = "custom")
        assertEquals("custom", copied.id)
        assertEquals(original.displayName, copied.displayName)
        assertEquals(original.engineType, copied.engineType)
    }

    @Test
    fun modelFile_isDataClass_equalityWorks() {
        val a = ModelFile("https://example.com/file.bin", "file.bin")
        val b = ModelFile("https://example.com/file.bin", "file.bin")
        assertEquals(a, b)
    }

    // -- Enum completeness --

    @Test
    fun engineType_hasThreeValues() {
        assertEquals(3, EngineType.entries.size)
    }

    @Test
    fun sherpaModelType_hasFourValues() {
        assertEquals(4, SherpaModelType.entries.size)
    }
}
