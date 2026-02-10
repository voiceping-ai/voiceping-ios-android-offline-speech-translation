package com.voiceping.offlinetranscription.ui.transcription

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import android.content.pm.PackageManager
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import com.voiceping.offlinetranscription.BuildConfig
import com.voiceping.offlinetranscription.model.ModelInfo
import com.voiceping.offlinetranscription.model.ModelState
import com.voiceping.offlinetranscription.service.E2ETestResult
import com.voiceping.offlinetranscription.ui.components.AudioVisualizer
import com.voiceping.offlinetranscription.ui.components.RecordButton
import com.voiceping.offlinetranscription.util.FormatUtils

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TranscriptionScreen(viewModel: TranscriptionViewModel, onChangeModel: () -> Unit = {}) {
    val context = LocalContext.current

    // Runtime mic permission request
    val permissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted) {
            viewModel.startRecordingWithPreparation()
        }
    }

    fun onRecordClick() {
        val hasPermission = ContextCompat.checkSelfPermission(
            context, Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED

        if (viewModel.isRecording.value) {
            viewModel.toggleRecording()
        } else if (hasPermission) {
            viewModel.startRecordingWithPreparation()
        } else {
            permissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
        }
    }
    val isRecording by viewModel.isRecording.collectAsState()
    val confirmedText by viewModel.confirmedText.collectAsState()
    val hypothesisText by viewModel.hypothesisText.collectAsState()
    val lastError by viewModel.lastError.collectAsState()
    val showSaveConfirmation by viewModel.showSaveConfirmation.collectAsState()
    val selectedModel by viewModel.selectedModel.collectAsState()
    val useVAD by viewModel.useVAD.collectAsState()
    val enableTimestamps by viewModel.enableTimestamps.collectAsState()
    val translationEnabled by viewModel.translationEnabled.collectAsState()
    val speakTranslatedAudio by viewModel.speakTranslatedAudio.collectAsState()
    val translationSourceLanguageCode by viewModel.translationSourceLanguageCode.collectAsState()
    val translationTargetLanguageCode by viewModel.translationTargetLanguageCode.collectAsState()
    val ttsRate by viewModel.ttsRate.collectAsState()
    val translatedConfirmedText by viewModel.translatedConfirmedText.collectAsState()
    val translatedHypothesisText by viewModel.translatedHypothesisText.collectAsState()
    val translationWarning by viewModel.translationWarning.collectAsState()
    val displayConfirmedText = remember(confirmedText) { confirmedText.trim() }
    val displayHypothesisText = remember(hypothesisText) { hypothesisText.trim() }
    val displayTranslatedConfirmedText = remember(translatedConfirmedText) { translatedConfirmedText.trim() }
    val displayTranslatedHypothesisText = remember(translatedHypothesisText) { translatedHypothesisText.trim() }
    val displayTranslationWarning = remember(translationWarning) { translationWarning?.trim().orEmpty() }

    var showSettings by remember { mutableStateOf(false) }
    val clipboardManager = LocalClipboardManager.current
    val scrollState = rememberScrollState()
    val bottomPanelScrollState = rememberScrollState()

    // Elapsed recording timer
    var elapsedSeconds by remember { mutableStateOf(0) }
    LaunchedEffect(isRecording) {
        if (isRecording) {
            elapsedSeconds = 0
            while (true) {
                kotlinx.coroutines.delay(1000)
                elapsedSeconds++
            }
        }
    }

    // Auto-scroll when either realtime hypothesis or confirmed text grows.
    LaunchedEffect(displayConfirmedText, displayHypothesisText, isRecording) {
        if (isRecording || displayConfirmedText.isNotEmpty() || displayHypothesisText.isNotEmpty()) {
            scrollState.scrollTo(scrollState.maxValue)
        }
    }

    // Pre-initialize mic recorder setup on screen entry to avoid first-utterance clipping.
    LaunchedEffect(Unit) {
        viewModel.prewarmOnScreenOpen()
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Transcribe") }
            )
        }
    ) { paddingValues ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
        ) {
            // Transcription text area
            Column(
                modifier = Modifier
                    .weight(1f)
                    .verticalScroll(scrollState)
                    .padding(16.dp),
                verticalArrangement = Arrangement.Top
            ) {
                if (displayConfirmedText.isNotEmpty()) {
                    Text(
                        text = displayConfirmedText,
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                }

                if (displayHypothesisText.isNotEmpty()) {
                    Text(
                        text = displayHypothesisText,
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontStyle = FontStyle.Italic
                    )
                }

                if (translationEnabled &&
                    (displayTranslatedConfirmedText.isNotEmpty() || displayTranslatedHypothesisText.isNotEmpty())
                ) {
                    Spacer(modifier = Modifier.height(12.dp))
                    HorizontalDivider()
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(
                        text = "Translation (${translationTargetLanguageCode})",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    if (displayTranslatedConfirmedText.isNotEmpty()) {
                        Text(
                            text = displayTranslatedConfirmedText,
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.primary
                        )
                    }
                    if (displayTranslatedHypothesisText.isNotEmpty()) {
                        Text(
                            text = displayTranslatedHypothesisText,
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.primary.copy(alpha = 0.8f),
                            fontStyle = FontStyle.Italic
                        )
                    }
                    if (displayTranslationWarning.isNotEmpty()) {
                        Text(
                            text = "Warning: $displayTranslationWarning",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.error
                        )
                    }
                } else if (translationEnabled && isRecording &&
                    (displayConfirmedText.isNotEmpty() || displayHypothesisText.isNotEmpty())
                ) {
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(
                        text = "Translating...",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
                    )
                } else if (translationEnabled &&
                    displayTranslationWarning.isNotEmpty() &&
                    (displayConfirmedText.isNotEmpty() || displayHypothesisText.isNotEmpty())
                ) {
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(
                        text = "Warning: $displayTranslationWarning",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error
                    )
                }

                if (displayConfirmedText.isEmpty() && displayHypothesisText.isEmpty() && !isRecording) {
                    Text(
                        text = "Tap the microphone button to start transcribing.",
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
                    )
                }

                if (isRecording && displayConfirmedText.isEmpty() && displayHypothesisText.isEmpty()) {
                    Text(
                        text = "Listening...",
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
                    )
                }
            }

            HorizontalDivider()

            // Keep bottom controls visible: make lower panels scroll when content is tall.
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 340.dp)
                    .verticalScroll(bottomPanelScrollState)
            ) {
                // Audio visualizer + recording stats (isolated to limit recomposition scope)
                if (isRecording) {
                    RecordingStatsBar(viewModel)
                }

                // Model info (always visible)
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 4.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Text(
                        text = "${selectedModel.displayName} · ${selectedModel.languages}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Text(
                        text = selectedModel.inferenceMethod,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f)
                    )
                }

                // E2E Evidence overlay (debug builds only)
                if (BuildConfig.DEBUG) {
                    val e2eResult by viewModel.e2eResult.collectAsState()
                    e2eResult?.let { result ->
                        E2EEvidenceOverlay(result)
                    }
                }

                // Resource stats (isolated to limit recomposition scope)
                ResourceStatsBar(viewModel, isRecording, elapsedSeconds)

                HomeLanguageSpeechCard(
                    translationEnabled = translationEnabled,
                    speakTranslatedAudio = speakTranslatedAudio,
                    translationSourceLanguageCode = translationSourceLanguageCode,
                    translationTargetLanguageCode = translationTargetLanguageCode,
                    ttsRate = ttsRate,
                    translatedConfirmedText = displayTranslatedConfirmedText,
                    translatedHypothesisText = displayTranslatedHypothesisText,
                    translationWarning = displayTranslationWarning,
                    onTranslationEnabledChange = { viewModel.setTranslationEnabled(it) },
                    onSpeakTranslatedAudioChange = { viewModel.setSpeakTranslatedAudio(it) },
                    onSourceLanguageChange = { viewModel.setTranslationSourceLanguageCode(it) },
                    onTargetLanguageChange = { viewModel.setTranslationTargetLanguageCode(it) },
                    onTtsRateChange = { viewModel.setTtsRate(it) }
                )
            }

            // Controls
            val canSave = !isRecording && viewModel.fullText.isNotBlank()
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically
            ) {
                IconButton(
                    onClick = { viewModel.saveTranscription() },
                    enabled = canSave,
                    modifier = Modifier.semantics { contentDescription = "Save" }
                ) {
                    Icon(
                        Icons.Filled.Save,
                        contentDescription = null,
                        tint = if (canSave) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.38f)
                    )
                }

                Spacer(modifier = Modifier.width(12.dp))

                IconButton(
                    onClick = { viewModel.transcribeTestAsset(context) },
                    enabled = !isRecording,
                    modifier = Modifier.semantics { contentDescription = "Test Audio File" }
                ) {
                    Icon(
                        Icons.Filled.AudioFile,
                        contentDescription = null,
                        tint = if (!isRecording) MaterialTheme.colorScheme.onSurfaceVariant
                        else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.38f)
                    )
                }

                Spacer(modifier = Modifier.width(12.dp))

                RecordButton(
                    isRecording = isRecording,
                    onClick = { onRecordClick() }
                )

                Spacer(modifier = Modifier.width(12.dp))

                IconButton(
                    onClick = { showSettings = true },
                    modifier = Modifier.semantics { contentDescription = "Settings" }
                ) {
                    Icon(
                        Icons.Filled.Settings,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
    }

    // Save confirmation
    if (showSaveConfirmation) {
        AlertDialog(
            onDismissRequest = { viewModel.dismissSaveConfirmation() },
            title = { Text("Saved") },
            text = { Text("Transcription saved to history.") },
            confirmButton = {
                TextButton(onClick = { viewModel.dismissSaveConfirmation() }) {
                    Text("OK")
                }
            }
        )
    }

    // Error dialog - dismiss without clearing transcription text
    lastError?.let { error ->
        val isTranslationError =
            error is com.voiceping.offlinetranscription.model.AppError.TranslationUnavailable ||
                error is com.voiceping.offlinetranscription.model.AppError.TranslationFailed
        if (isTranslationError) {
            LaunchedEffect(error) {
                viewModel.dismissError()
            }
            return@let
        }
        val isPermissionError = error is com.voiceping.offlinetranscription.model.AppError.MicrophonePermissionDenied
        AlertDialog(
            onDismissRequest = { viewModel.dismissError() },
            title = { Text(if (isPermissionError) "Permission Required" else "Error") },
            text = { Text(error.message) },
            confirmButton = {
                if (isPermissionError) {
                    TextButton(onClick = {
                        viewModel.dismissError()
                        permissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                    }) {
                        Text("Grant Permission")
                    }
                } else {
                    TextButton(onClick = { viewModel.dismissError() }) {
                        Text("OK")
                    }
                }
            },
            dismissButton = {
                if (isPermissionError) {
                    TextButton(onClick = { viewModel.dismissError() }) {
                        Text("Cancel")
                    }
                }
            }
        )
    }

    // Settings bottom sheet
    if (showSettings) {
        SettingsBottomSheet(
            selectedModel = selectedModel,
            useVAD = useVAD,
            enableTimestamps = enableTimestamps,
            fullText = viewModel.fullText,
            onCopyText = { clipboardManager.setText(AnnotatedString(viewModel.fullText)) },
            onClearTranscription = { viewModel.clearTranscription() },
            onChangeModel = {
                viewModel.stopIfRecording()
                showSettings = false
                onChangeModel()
            },
            onVADChange = { viewModel.setUseVAD(it) },
            onTimestampsChange = { viewModel.setEnableTimestamps(it) },
            onDismiss = { showSettings = false }
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SettingsBottomSheet(
    selectedModel: ModelInfo,
    useVAD: Boolean,
    enableTimestamps: Boolean,
    fullText: String,
    onCopyText: () -> Unit,
    onClearTranscription: () -> Unit,
    onChangeModel: () -> Unit,
    onVADChange: (Boolean) -> Unit,
    onTimestampsChange: (Boolean) -> Unit,
    onDismiss: () -> Unit
) {
    val sheetState = rememberModalBottomSheetState()

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text(
                text = "Settings",
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier.padding(bottom = 16.dp)
            )

            // Actions
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                OutlinedButton(
                    onClick = onCopyText,
                    enabled = fullText.isNotBlank(),
                    modifier = Modifier
                        .weight(1f)
                        .semantics { contentDescription = "settings_copy_text" }
                ) {
                    Icon(Icons.Filled.ContentCopy, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(modifier = Modifier.width(4.dp))
                    Text("Copy Text")
                }
                OutlinedButton(
                    onClick = onClearTranscription,
                    enabled = fullText.isNotBlank(),
                    modifier = Modifier
                        .weight(1f)
                        .semantics { contentDescription = "settings_clear_transcription" }
                ) {
                    Icon(Icons.Filled.Delete, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(modifier = Modifier.width(4.dp))
                    Text("Clear")
                }
            }

            OutlinedButton(
                onClick = onChangeModel,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 8.dp)
                    .semantics { contentDescription = "settings_change_model" }
            ) {
                Icon(Icons.Filled.SwapHoriz, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(modifier = Modifier.width(4.dp))
                Text("Change Model")
            }

            HorizontalDivider(modifier = Modifier.padding(vertical = 12.dp))

            // Current Model
            Text(
                text = "Current Model",
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 8.dp),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text(selectedModel.displayName)
                Text(
                    selectedModel.parameterCount,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))

            // Transcription Settings
            Text(
                text = "Transcription Settings",
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 4.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("Voice Activity Detection")
                Switch(checked = useVAD, onCheckedChange = onVADChange)
            }

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 4.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("Enable Timestamps")
                Switch(checked = enableTimestamps, onCheckedChange = onTimestampsChange)
            }

            Spacer(modifier = Modifier.height(32.dp))
        }
    }
}

@Composable
private fun HomeLanguageSpeechCard(
    translationEnabled: Boolean,
    speakTranslatedAudio: Boolean,
    translationSourceLanguageCode: String,
    translationTargetLanguageCode: String,
    ttsRate: Float,
    translatedConfirmedText: String,
    translatedHypothesisText: String,
    translationWarning: String,
    onTranslationEnabledChange: (Boolean) -> Unit,
    onSpeakTranslatedAudioChange: (Boolean) -> Unit,
    onSourceLanguageChange: (String) -> Unit,
    onTargetLanguageChange: (String) -> Unit,
    onTtsRateChange: (Float) -> Unit
) {
    val ttsText = remember(translatedConfirmedText, translatedHypothesisText) {
        listOf(translatedConfirmedText.trim(), translatedHypothesisText.trim())
            .filter { it.isNotEmpty() }
            .joinToString(" ")
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f))
            .padding(12.dp)
    ) {
        Text(
            text = "Language & Speech",
            style = MaterialTheme.typography.titleSmall
        )

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 6.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("Enable Translation")
            Switch(
                checked = translationEnabled,
                onCheckedChange = onTranslationEnabledChange
            )
        }

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 2.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("Speak Translated Audio")
            Switch(
                checked = speakTranslatedAudio,
                enabled = translationEnabled,
                onCheckedChange = onSpeakTranslatedAudioChange
            )
        }

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Box(modifier = Modifier.weight(1f)) {
                LanguageDropdownField(
                    title = "Source",
                    selectedCode = translationSourceLanguageCode,
                    enabled = translationEnabled,
                    onLanguageSelected = onSourceLanguageChange
                )
            }
            Box(modifier = Modifier.weight(1f)) {
                LanguageDropdownField(
                    title = "Target",
                    selectedCode = translationTargetLanguageCode,
                    enabled = translationEnabled,
                    onLanguageSelected = onTargetLanguageChange
                )
            }
        }

        Text(
            text = "Speech rate: ${String.format("%.2f", ttsRate)}",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 8.dp)
        )
        Slider(
            value = ttsRate,
            onValueChange = onTtsRateChange,
            valueRange = 0.25f..2.0f,
            enabled = translationEnabled && speakTranslatedAudio
        )

        Text(
            text = "TTS Text",
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Text(
            text = if (ttsText.isBlank()) "No translated text yet." else ttsText,
            style = MaterialTheme.typography.bodySmall,
            color = if (ttsText.isBlank()) {
                MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f)
            } else {
                MaterialTheme.colorScheme.onSurface
            },
            maxLines = 3
        )
        if (translationWarning.isNotEmpty()) {
            Text(
                text = "Warning: $translationWarning",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.padding(top = 6.dp)
            )
        }
    }
}

private data class TranslationLanguageOption(
    val code: String,
    val name: String
) {
    val displayName: String
        get() = "$name ($code)"
}

private val TRANSLATION_LANGUAGE_OPTIONS = listOf(
    TranslationLanguageOption("en", "English"),
    TranslationLanguageOption("ja", "Japanese"),
    TranslationLanguageOption("es", "Spanish"),
    TranslationLanguageOption("fr", "French"),
    TranslationLanguageOption("de", "German"),
    TranslationLanguageOption("it", "Italian"),
    TranslationLanguageOption("pt", "Portuguese"),
    TranslationLanguageOption("ko", "Korean"),
    TranslationLanguageOption("zh", "Chinese"),
    TranslationLanguageOption("ru", "Russian"),
    TranslationLanguageOption("ar", "Arabic"),
    TranslationLanguageOption("hi", "Hindi"),
    TranslationLanguageOption("id", "Indonesian"),
    TranslationLanguageOption("vi", "Vietnamese"),
    TranslationLanguageOption("th", "Thai"),
    TranslationLanguageOption("tr", "Turkish"),
    TranslationLanguageOption("nl", "Dutch"),
    TranslationLanguageOption("sv", "Swedish"),
    TranslationLanguageOption("pl", "Polish")
)

private fun translationLanguageDisplayName(code: String): String {
    val normalized = code.trim().lowercase()
    val option = TRANSLATION_LANGUAGE_OPTIONS.firstOrNull {
        it.code.equals(normalized, ignoreCase = true)
    }
    return option?.displayName ?: normalized.ifEmpty { "Select language" }
}

@Composable
private fun LanguageDropdownField(
    title: String,
    selectedCode: String,
    enabled: Boolean,
    onLanguageSelected: (String) -> Unit
) {
    var expanded by remember { mutableStateOf(false) }
    val selectedLabel = remember(selectedCode) {
        translationLanguageDisplayName(selectedCode)
    }

    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(
            text = title,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        Box {
            OutlinedButton(
                onClick = { if (enabled) expanded = true },
                enabled = enabled,
                modifier = Modifier.fillMaxWidth(),
                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 10.dp)
            ) {
                Text(
                    text = selectedLabel,
                    style = MaterialTheme.typography.bodyMedium,
                    maxLines = 1,
                    modifier = Modifier.weight(1f)
                )
                Icon(
                    Icons.Filled.ArrowDropDown,
                    contentDescription = null
                )
            }

            DropdownMenu(
                expanded = expanded,
                onDismissRequest = { expanded = false },
                modifier = Modifier.heightIn(max = 320.dp)
            ) {
                TRANSLATION_LANGUAGE_OPTIONS.forEach { option ->
                    DropdownMenuItem(
                        text = { Text(option.displayName) },
                        onClick = {
                            onLanguageSelected(option.code)
                            expanded = false
                        },
                        trailingIcon = if (option.code.equals(selectedCode, ignoreCase = true)) {
                            { Icon(Icons.Filled.Check, contentDescription = null) }
                        } else {
                            null
                        }
                    )
                }
            }
        }
    }
}

@Composable
private fun E2EEvidenceOverlay(result: E2ETestResult) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
            .padding(8.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = "E2E EVIDENCE",
                style = MaterialTheme.typography.labelSmall,
                fontFamily = FontFamily.Monospace
            )
            Text(
                text = if (result.pass) "PASS" else "FAIL",
                style = MaterialTheme.typography.labelSmall,
                color = if (result.pass) MaterialTheme.colorScheme.onPrimary
                else MaterialTheme.colorScheme.onError,
                modifier = Modifier
                    .clip(RoundedCornerShape(12.dp))
                    .background(
                        if (result.pass) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.error
                    )
                    .padding(horizontal = 8.dp, vertical = 2.dp)
            )
        }
        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text = "Model: ${result.modelId}",
            style = MaterialTheme.typography.labelSmall,
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Text(
            text = "Engine: ${result.engine}",
            style = MaterialTheme.typography.labelSmall,
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Text(
            text = "Duration: ${"%.0f".format(result.durationMs)} ms",
            style = MaterialTheme.typography.labelSmall,
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Text(
            text = "TTS starts: ${result.ttsStartCount}",
            style = MaterialTheme.typography.labelSmall,
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Text(
            text = "TTS mic guard violations: ${result.ttsMicGuardViolations}",
            style = MaterialTheme.typography.labelSmall,
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Text(
            text = "Mic stopped for TTS: ${result.micStoppedForTts}",
            style = MaterialTheme.typography.labelSmall,
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        if (result.transcript.isNotEmpty()) {
            Text(
                text = result.transcript.take(120),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2
            )
        }
    }
}

/** Isolated composable for high-frequency recording stats — limits recomposition scope. */
@Composable
private fun RecordingStatsBar(viewModel: TranscriptionViewModel) {
    val bufferEnergy by viewModel.bufferEnergy.collectAsState()
    val bufferSeconds by viewModel.bufferSeconds.collectAsState()
    val tokensPerSecond by viewModel.tokensPerSecond.collectAsState()
    val micPeakLevel = remember(bufferEnergy) { bufferEnergy.takeLast(12).maxOrNull() ?: 0f }

    AudioVisualizer(
        energyLevels = bufferEnergy,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp)
    )

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                Icons.Filled.Schedule,
                contentDescription = null,
                modifier = Modifier.size(14.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.width(4.dp))
            Text(
                text = FormatUtils.formatDuration(bufferSeconds),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = String.format("mic %.3f", micPeakLevel),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            if (tokensPerSecond > 0) {
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = String.format("%.1f tok/s", tokensPerSecond),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

/** Isolated composable for resource stats — limits recomposition scope from CPU/RAM polling. */
@Composable
private fun ResourceStatsBar(viewModel: TranscriptionViewModel, isRecording: Boolean, elapsedSeconds: Int) {
    val cpuPercent by viewModel.cpuPercent.collectAsState()
    val memoryMB by viewModel.memoryMB.collectAsState()
    val tokensPerSecond by viewModel.tokensPerSecond.collectAsState()

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically
    ) {
        if (isRecording) {
            Text(
                text = "${elapsedSeconds}s",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.width(16.dp))
        }
        Text(
            text = String.format("CPU %.0f%%", cpuPercent),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(modifier = Modifier.width(16.dp))
        Text(
            text = String.format("RAM %.0f MB", memoryMB),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        if (tokensPerSecond > 0) {
            Spacer(modifier = Modifier.width(16.dp))
            Text(
                text = String.format("%.1f tok/s", tokensPerSecond),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}
