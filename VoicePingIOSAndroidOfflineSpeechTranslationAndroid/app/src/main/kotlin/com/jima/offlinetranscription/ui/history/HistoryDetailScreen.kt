package com.voiceping.offlinetranscription.ui.history

import android.content.Intent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.FileDownload
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp
import com.voiceping.offlinetranscription.data.TranscriptionEntity
import com.voiceping.offlinetranscription.service.AudioPlaybackManager
import com.voiceping.offlinetranscription.ui.components.AppVersionLabel
import com.voiceping.offlinetranscription.ui.components.WaveformScrubber
import com.voiceping.offlinetranscription.util.FormatUtils
import com.voiceping.offlinetranscription.util.SessionExporter
import com.voiceping.offlinetranscription.util.WaveformGenerator
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HistoryDetailScreen(
    record: TranscriptionEntity,
    onBack: () -> Unit
) {
    val clipboardManager = LocalClipboardManager.current
    val context = LocalContext.current
    val dateFormat = SimpleDateFormat("MMM d, yyyy h:mm a", Locale.getDefault())

    // Resolve audio file
    val audioFile = remember(record.audioFileName) {
        record.audioFileName?.let { relPath ->
            val f = File(context.filesDir, relPath)
            if (f.exists()) f else null
        }
    }

    // Audio playback manager
    val playbackManager = remember { AudioPlaybackManager() }
    DisposableEffect(audioFile) {
        audioFile?.let { playbackManager.load(it) }
        onDispose { playbackManager.release() }
    }

    val isPlaying by playbackManager.isPlaying.collectAsState()
    val currentPositionMs by playbackManager.currentPositionMs.collectAsState()
    val durationMs by playbackManager.durationMs.collectAsState()

    // Waveform bars (computed once on IO)
    var waveformBars by remember { mutableStateOf(FloatArray(200)) }
    LaunchedEffect(audioFile) {
        audioFile?.let { file ->
            waveformBars = withContext(Dispatchers.IO) {
                WaveformGenerator.generateFromWavFile(file)
            }
        }
    }

    val progress = if (durationMs > 0) currentPositionMs.toFloat() / durationMs else 0f

    // Export error state
    var showExportError by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Transcription") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    // ZIP export button (only when audio exists)
                    if (audioFile != null) {
                        IconButton(onClick = {
                            try {
                                val result = SessionExporter.export(context, record, audioFile)
                                context.startActivity(result.shareIntent)
                            } catch (e: Exception) {
                                showExportError = true
                            }
                        }) {
                            Icon(Icons.Filled.FileDownload, contentDescription = "Export ZIP")
                        }
                    }
                    IconButton(onClick = {
                        clipboardManager.setText(AnnotatedString(record.text))
                    }) {
                        Icon(Icons.Filled.ContentCopy, contentDescription = "Copy")
                    }
                    IconButton(onClick = {
                        val sendIntent = Intent().apply {
                            action = Intent.ACTION_SEND
                            putExtra(Intent.EXTRA_TEXT, record.text)
                            type = "text/plain"
                        }
                        context.startActivity(Intent.createChooser(sendIntent, "Share transcription"))
                    }) {
                        Icon(Icons.Filled.Share, contentDescription = "Share")
                    }
                }
            )
        }
    ) { paddingValues ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
                .verticalScroll(rememberScrollState())
                .padding(16.dp)
        ) {
            // Metadata
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text(
                    text = dateFormat.format(Date(record.createdAt)),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Text(
                    text = FormatUtils.formatDuration(record.durationSeconds),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            Spacer(modifier = Modifier.height(8.dp))

            Surface(
                shape = MaterialTheme.shapes.small,
                color = MaterialTheme.colorScheme.surfaceVariant
            ) {
                Text(
                    text = "Model: ${record.modelUsed}",
                    style = MaterialTheme.typography.labelSmall,
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp)
                )
            }

            // Waveform player (only if audio exists)
            if (audioFile != null) {
                Spacer(modifier = Modifier.height(16.dp))

                WaveformScrubber(
                    bars = waveformBars,
                    progress = progress,
                    isPlaying = isPlaying,
                    currentTimeMs = currentPositionMs,
                    durationMs = durationMs,
                    onSeek = { fraction -> playbackManager.seekTo(fraction) },
                    onTogglePlayPause = { playbackManager.togglePlayPause() },
                    modifier = Modifier.fillMaxWidth()
                )
            }

            Spacer(modifier = Modifier.height(16.dp))
            HorizontalDivider()
            Spacer(modifier = Modifier.height(16.dp))

            // Full text (selectable)
            SelectionContainer {
                Text(
                    text = record.text,
                    style = MaterialTheme.typography.bodyLarge
                )
            }

            Spacer(modifier = Modifier.height(16.dp))
            AppVersionLabel(
                modifier = Modifier.fillMaxWidth()
            )
        }
    }

    if (showExportError) {
        AlertDialog(
            onDismissRequest = { showExportError = false },
            title = { Text("Export Failed") },
            text = { Text("Unable to create the session export.") },
            confirmButton = {
                TextButton(onClick = { showExportError = false }) {
                    Text("OK")
                }
            }
        )
    }
}
