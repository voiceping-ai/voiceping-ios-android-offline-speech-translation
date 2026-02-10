package com.voiceping.offlinetranscription.service

import com.voiceping.offlinetranscription.model.EngineType
import com.voiceping.offlinetranscription.model.ModelFile
import com.voiceping.offlinetranscription.model.ModelInfo
import com.voiceping.offlinetranscription.model.SherpaModelType
import org.junit.After
import org.junit.Before
import org.junit.Test
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ModelDownloaderTest {

    private lateinit var tempDir: File
    private lateinit var downloader: ModelDownloader

    private val singleFileModel = ModelInfo(
        id = "whisper-test",
        displayName = "Whisper Test",
        engineType = EngineType.WHISPER_CPP,
        parameterCount = "39M",
        sizeOnDisk = "~80 MB",
        description = "Test model",
        files = listOf(ModelFile("https://example.com/ggml-tiny.bin", "ggml-tiny.bin"))
    )

    private val multiFileModel = ModelInfo(
        id = "moonshine-test",
        displayName = "Moonshine Test",
        engineType = EngineType.SHERPA_ONNX,
        sherpaModelType = SherpaModelType.MOONSHINE,
        parameterCount = "27M",
        sizeOnDisk = "~125 MB",
        description = "Test model",
        files = listOf(
            ModelFile("https://example.com/preprocess.onnx", "preprocess.onnx"),
            ModelFile("https://example.com/encode.int8.onnx", "encode.int8.onnx"),
            ModelFile("https://example.com/uncached_decode.int8.onnx", "uncached_decode.int8.onnx"),
            ModelFile("https://example.com/cached_decode.int8.onnx", "cached_decode.int8.onnx"),
            ModelFile("https://example.com/tokens.txt", "tokens.txt"),
        )
    )

    @Before
    fun setUp() {
        tempDir = File(System.getProperty("java.io.tmpdir"), "model_downloader_test_${System.nanoTime()}")
        tempDir.mkdirs()
        downloader = ModelDownloader(tempDir)
    }

    @After
    fun tearDown() {
        tempDir.deleteRecursively()
    }

    // -- modelDir --

    @Test
    fun modelDir_returnsSubdirectoryNamedByModelId() {
        val dir = downloader.modelDir(singleFileModel)
        assertEquals("whisper-test", dir.name)
        assertEquals(tempDir.absolutePath, dir.parentFile?.absolutePath)
    }

    @Test
    fun modelDir_usesModelId_forMultiFileModel() {
        val dir = downloader.modelDir(multiFileModel)
        assertEquals("moonshine-test", dir.name)
    }

    // -- modelFilePath --

    @Test
    fun modelFilePath_returnsPathToFirstFile() {
        val path = downloader.modelFilePath(singleFileModel)
        assertTrue(path.endsWith("whisper-test/ggml-tiny.bin"), "Expected path ending with whisper-test/ggml-tiny.bin but got $path")
    }

    @Test
    fun modelFilePath_forMultiFile_returnsFirstFile() {
        val path = downloader.modelFilePath(multiFileModel)
        assertTrue(path.endsWith("moonshine-test/preprocess.onnx"))
    }

    // -- isModelDownloaded --

    @Test
    fun isModelDownloaded_returnsFalse_whenNoFilesExist() {
        assertFalse(downloader.isModelDownloaded(singleFileModel))
    }

    @Test
    fun isModelDownloaded_returnsTrue_whenSingleFileExists() {
        val dir = File(tempDir, "whisper-test")
        dir.mkdirs()
        File(dir, "ggml-tiny.bin").writeText("fake model data")

        assertTrue(downloader.isModelDownloaded(singleFileModel))
    }

    @Test
    fun isModelDownloaded_returnsFalse_whenPartialMultiFileDownload() {
        val dir = File(tempDir, "moonshine-test")
        dir.mkdirs()
        // Only create some of the 5 required files
        File(dir, "preprocess.onnx").writeText("data")
        File(dir, "encode.int8.onnx").writeText("data")
        File(dir, "tokens.txt").writeText("data")
        // Missing: uncached_decode.int8.onnx, cached_decode.int8.onnx

        assertFalse(downloader.isModelDownloaded(multiFileModel))
    }

    @Test
    fun isModelDownloaded_returnsTrue_whenAllMultiFilesExist() {
        val dir = File(tempDir, "moonshine-test")
        dir.mkdirs()
        multiFileModel.files.forEach { file ->
            File(dir, file.localName).writeText("fake data")
        }

        assertTrue(downloader.isModelDownloaded(multiFileModel))
    }

    @Test
    fun isModelDownloaded_ignoresTempFiles() {
        val dir = File(tempDir, "whisper-test")
        dir.mkdirs()
        // Only a .tmp file exists, not the final file
        File(dir, "ggml-tiny.bin.tmp").writeText("incomplete data")

        assertFalse(downloader.isModelDownloaded(singleFileModel))
    }

    // -- Catalog models --

    @Test
    fun isModelDownloaded_worksWithRealCatalogModels() {
        // Verify isModelDownloaded works for each real catalog model
        ModelInfo.availableModels.forEach { model ->
            assertFalse(
                downloader.isModelDownloaded(model),
                "Fresh downloader should report ${model.id} as not downloaded"
            )
        }
    }
}
