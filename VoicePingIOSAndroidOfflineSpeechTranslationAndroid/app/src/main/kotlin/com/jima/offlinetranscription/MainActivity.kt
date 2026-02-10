package com.voiceping.offlinetranscription

import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.voiceping.offlinetranscription.model.ModelInfo
import com.voiceping.offlinetranscription.model.ModelState
import com.voiceping.offlinetranscription.ui.navigation.AppNavigation
import com.voiceping.offlinetranscription.ui.theme.OfflineTranscriptionTheme
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull

class MainActivity : ComponentActivity() {
    private fun e2eLoadTimeoutMs(modelId: String): Long = when {
        modelId.contains("large") -> 1_200_000L
        modelId.contains("omnilingual") -> 600_000L
        modelId.contains("parakeet") -> 900_000L
        modelId.contains("small") -> 1_200_000L
        modelId.contains("base") -> 600_000L
        else -> 120_000L
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        val app = application as OfflineTranscriptionApp
        val isE2E = intent.getBooleanExtra("e2e_test", false)
        val e2eModelId = intent.getStringExtra("model_id")
        val e2eTranslationSource = intent.getStringExtra("translation_source") ?: "en"
        val e2eTranslationTarget = intent.getStringExtra("translation_target") ?: "ja"

        setContent {
            OfflineTranscriptionTheme {
                var isLoading by remember { mutableStateOf(true) }

                LaunchedEffect(Unit) {
                    if (isE2E && e2eModelId != null) {
                        // E2E test mode: select specific model, download, load, transcribe
                        val model = ModelInfo.availableModels.find { it.id == e2eModelId }
                        if (model != null) {
                            Log.i("E2E", "Auto-test mode: selecting $e2eModelId")
                            app.whisperEngine.setSelectedModel(model)
                            // Force translation + TTS in E2E mode for evidence capture.
                            app.whisperEngine.setTranslationEnabled(true)
                            app.whisperEngine.setSpeakTranslatedAudio(true)
                            app.whisperEngine.setTranslationSourceLanguageCode(e2eTranslationSource)
                            app.whisperEngine.setTranslationTargetLanguageCode(e2eTranslationTarget)
                            app.whisperEngine.setupModel()

                            // Wait for model to load (with timeout and error escape)
                            val timeoutMs = e2eLoadTimeoutMs(e2eModelId)
                            Log.i("E2E", "Waiting for model to load (timeout=${timeoutMs}ms)...")
                            val finalState = withTimeoutOrNull(timeoutMs) {
                                app.whisperEngine.modelState.first {
                                    it == ModelState.Loaded || it == ModelState.Unloaded
                                }
                            }
                            if (finalState != ModelState.Loaded) {
                                Log.e("E2E", "Model failed to load (state=$finalState), aborting E2E")
                                app.whisperEngine.writeE2EFailure(
                                    modelId = e2eModelId,
                                    error = "model load failed/timed out (state=$finalState, timeout_ms=$timeoutMs)"
                                )
                                isLoading = false
                                return@LaunchedEffect
                            }
                            Log.i("E2E", "Model loaded, starting transcription...")
                            isLoading = false

                            delay(500)
                            // Prefer adb-pushed file (E2E scripts), fall back to bundled asset
                            val adbFile = java.io.File("/data/local/tmp/test_speech.wav")
                            val wavPath = if (adbFile.exists()) {
                                adbFile.absolutePath
                            } else {
                                val cached = java.io.File(cacheDir, "test_speech.wav")
                                if (!cached.exists()) {
                                    assets.open("test_speech.wav").use { input ->
                                        cached.outputStream().use { output -> input.copyTo(output) }
                                    }
                                }
                                cached.absolutePath
                            }
                            app.whisperEngine.transcribeFile(wavPath)
                        } else {
                            Log.e("E2E", "Model $e2eModelId not found")
                            app.whisperEngine.writeE2EFailure(
                                modelId = e2eModelId,
                                error = "model not found"
                            )
                            app.whisperEngine.loadModelIfAvailable()
                            isLoading = false
                        }
                    } else {
                        app.whisperEngine.loadModelIfAvailable()
                        isLoading = false
                    }
                }

                if (isLoading) {
                    val modelState by app.whisperEngine.modelState.collectAsState()
                    Box(
                        modifier = Modifier.fillMaxSize(),
                        contentAlignment = Alignment.Center
                    ) {
                        if (modelState == ModelState.Loading || modelState == ModelState.Downloading) {
                            CircularProgressIndicator()
                        }
                    }
                } else {
                    AppNavigation(
                        engine = app.whisperEngine,
                        database = app.database
                    )
                }
            }
        }
    }
}
