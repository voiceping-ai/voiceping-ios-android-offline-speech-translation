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
        id = "test-single",
        displayName = "Test Single",
        engineType = EngineType.SHERPA_ONNX,
        sherpaModelType = SherpaModelType.SENSE_VOICE,
        parameterCount = "39M",
        sizeOnDisk = "~80 MB",
        description = "Test model",
        files = listOf(ModelFile("https://example.com/model.int8.onnx", "model.int8.onnx"))
    )

    private val multiFileModel = ModelInfo(
        id = "test-multi",
        displayName = "Test Multi",
        engineType = EngineType.SHERPA_ONNX,
        sherpaModelType = SherpaModelType.SENSE_VOICE,
        parameterCount = "234M",
        sizeOnDisk = "~240 MB",
        description = "Test model",
        files = listOf(
            ModelFile("https://example.com/model.int8.onnx", "model.int8.onnx"),
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
        assertEquals("test-single", dir.name)
        assertEquals(tempDir.absolutePath, dir.parentFile?.absolutePath)
    }

    @Test
    fun modelDir_usesModelId_forMultiFileModel() {
        val dir = downloader.modelDir(multiFileModel)
        assertEquals("test-multi", dir.name)
    }

    // -- modelFilePath --

    @Test
    fun modelFilePath_returnsPathToFirstFile() {
        val path = downloader.modelFilePath(singleFileModel)
        assertTrue(path.endsWith("test-single/model.int8.onnx"), "Expected path ending with test-single/model.int8.onnx but got $path")
    }

    @Test
    fun modelFilePath_forMultiFile_returnsFirstFile() {
        val path = downloader.modelFilePath(multiFileModel)
        assertTrue(path.endsWith("test-multi/model.int8.onnx"))
    }

    // -- isModelDownloaded --

    @Test
    fun isModelDownloaded_returnsFalse_whenNoFilesExist() {
        assertFalse(downloader.isModelDownloaded(singleFileModel))
    }

    @Test
    fun isModelDownloaded_returnsTrue_whenSingleFileExists() {
        val dir = File(tempDir, "test-single")
        dir.mkdirs()
        File(dir, "model.int8.onnx").writeText("fake model data")

        assertTrue(downloader.isModelDownloaded(singleFileModel))
    }

    @Test
    fun isModelDownloaded_returnsFalse_whenPartialMultiFileDownload() {
        val dir = File(tempDir, "test-multi")
        dir.mkdirs()
        // Only create one of the 2 required files
        File(dir, "model.int8.onnx").writeText("data")
        // Missing: tokens.txt

        assertFalse(downloader.isModelDownloaded(multiFileModel))
    }

    @Test
    fun isModelDownloaded_returnsTrue_whenAllMultiFilesExist() {
        val dir = File(tempDir, "test-multi")
        dir.mkdirs()
        multiFileModel.files.forEach { file ->
            File(dir, file.localName).writeText("fake data")
        }

        assertTrue(downloader.isModelDownloaded(multiFileModel))
    }

    @Test
    fun isModelDownloaded_ignoresTempFiles() {
        val dir = File(tempDir, "test-single")
        dir.mkdirs()
        // Only a .tmp file exists, not the final file
        File(dir, "model.int8.onnx.tmp").writeText("incomplete data")

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
