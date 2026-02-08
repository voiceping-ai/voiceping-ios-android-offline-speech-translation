package com.voiceping.offlinetranscription.ui.setup

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.voiceping.offlinetranscription.model.EngineType
import com.voiceping.offlinetranscription.model.ModelInfo
import com.voiceping.offlinetranscription.model.ModelState
import com.voiceping.offlinetranscription.ui.components.ModelPickerRow

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ModelSetupScreen(viewModel: ModelSetupViewModel) {
    val modelState by viewModel.modelState.collectAsState()
    val downloadProgress by viewModel.downloadProgress.collectAsState()
    val selectedModel by viewModel.selectedModel.collectAsState()
    val lastError by viewModel.lastError.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(title = { Text("Setup") })
        }
    ) { paddingValues ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
                .padding(horizontal = 16.dp)
                .verticalScroll(rememberScrollState()),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Spacer(modifier = Modifier.height(40.dp))

            // Header
            Icon(
                imageVector = Icons.Filled.GraphicEq,
                contentDescription = null,
                modifier = Modifier.size(72.dp),
                tint = MaterialTheme.colorScheme.primary
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = "Offline Transcription",
                style = MaterialTheme.typography.headlineLarge
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = "Download a speech recognition model to get started. Models are stored on-device for fully offline use.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 16.dp)
            )

            Spacer(modifier = Modifier.height(24.dp))

            // Model Picker — grouped by engine
            Text(
                text = "Select Model",
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.align(Alignment.Start)
            )
            Spacer(modifier = Modifier.height(12.dp))

            val isBusy = modelState == ModelState.Downloading || modelState == ModelState.Loading

            ModelInfo.modelsByEngine.forEach { (engineType, models) ->
                Text(
                    text = engineLabel(engineType),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier
                        .align(Alignment.Start)
                        .padding(bottom = 4.dp)
                )
                models.forEach { model ->
                    ModelPickerRow(
                        model = model,
                        isSelected = selectedModel.id == model.id,
                        isDownloaded = viewModel.isModelDownloaded(model),
                        enabled = !isBusy,
                        onClick = { viewModel.selectAndSetup(model) }
                    )
                    Spacer(modifier = Modifier.height(8.dp))
                }
                Spacer(modifier = Modifier.height(8.dp))
            }

            // Download / Loading progress
            if (modelState == ModelState.Downloading) {
                Spacer(modifier = Modifier.height(16.dp))
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(
                        text = "Downloading ${selectedModel.displayName}...",
                        style = MaterialTheme.typography.bodyMedium
                    )
                    Spacer(modifier = Modifier.height(8.dp))
                    LinearProgressIndicator(
                        progress = { downloadProgress },
                        modifier = Modifier.fillMaxWidth()
                    )
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(
                        text = "${(downloadProgress * 100).toInt()}%",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            } else if (modelState == ModelState.Loading) {
                Spacer(modifier = Modifier.height(16.dp))
                CircularProgressIndicator()
                Spacer(modifier = Modifier.height(8.dp))
                Text("Loading model...")
            }

            lastError?.let { error ->
                Spacer(modifier = Modifier.height(8.dp))
                Text(
                    text = error.message,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error
                )
            }

            Spacer(modifier = Modifier.height(32.dp))
        }
    }
}

private fun engineLabel(type: EngineType): String = when (type) {
    EngineType.WHISPER_CPP -> "Whisper (whisper.cpp)"
    EngineType.SHERPA_ONNX -> "Moonshine / SenseVoice / Omnilingual (sherpa-onnx)"
    EngineType.SHERPA_ONNX_STREAMING -> "Streaming (sherpa-onnx)"
}
