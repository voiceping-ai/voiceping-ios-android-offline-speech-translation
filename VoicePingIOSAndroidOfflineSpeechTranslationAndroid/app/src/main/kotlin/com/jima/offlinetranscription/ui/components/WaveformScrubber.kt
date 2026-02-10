package com.voiceping.offlinetranscription.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp
import com.voiceping.offlinetranscription.util.FormatUtils

@Composable
fun WaveformScrubber(
    bars: FloatArray,
    progress: Float,
    isPlaying: Boolean,
    currentTimeMs: Int,
    durationMs: Int,
    onSeek: (Float) -> Unit,
    onTogglePlayPause: () -> Unit,
    modifier: Modifier = Modifier
) {
    Column(modifier = modifier) {
        // Waveform canvas
        WaveformCanvas(
            bars = bars,
            progress = progress,
            onSeek = onSeek,
            modifier = Modifier
                .fillMaxWidth()
                .height(60.dp)
        )

        Spacer(modifier = Modifier.height(8.dp))

        // Controls row
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth()
        ) {
            IconButton(onClick = onTogglePlayPause) {
                Icon(
                    if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                    contentDescription = if (isPlaying) "Pause" else "Play"
                )
            }

            Text(
                text = FormatUtils.formatDuration(currentTimeMs / 1000.0),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            Spacer(modifier = Modifier.weight(1f))

            Text(
                text = FormatUtils.formatDuration(durationMs / 1000.0),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun WaveformCanvas(
    bars: FloatArray,
    progress: Float,
    onSeek: (Float) -> Unit,
    modifier: Modifier = Modifier
) {
    val primaryColor = MaterialTheme.colorScheme.primary
    val dimColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.2f)
    val scrubberColor = MaterialTheme.colorScheme.primary

    Canvas(
        modifier = modifier
            .pointerInput(Unit) {
                detectTapGestures { offset ->
                    val fraction = (offset.x / size.width).coerceIn(0f, 1f)
                    onSeek(fraction)
                }
            }
            .pointerInput(Unit) {
                detectHorizontalDragGestures { change, _ ->
                    val fraction = (change.position.x / size.width).coerceIn(0f, 1f)
                    onSeek(fraction)
                }
            }
    ) {
        if (bars.isEmpty()) return@Canvas

        val barCount = bars.size
        val totalSpacing = 1.dp.toPx() * (barCount - 1)
        val barWidth = ((size.width - totalSpacing) / barCount).coerceAtLeast(1f)
        val spacing = if (barCount > 1) (size.width - barWidth * barCount) / (barCount - 1) else 0f
        val maxHeight = size.height
        val centerY = maxHeight / 2f

        for (i in 0 until barCount) {
            val x = i * (barWidth + spacing)
            val barFraction = i.toFloat() / barCount
            val level = bars[i].coerceIn(0f, 1f)
            val barHeight = (level * maxHeight).coerceAtLeast(2.dp.toPx())
            val color = if (barFraction <= progress) primaryColor else dimColor

            drawRoundRect(
                color = color,
                topLeft = Offset(x, centerY - barHeight / 2),
                size = Size(barWidth, barHeight),
                cornerRadius = CornerRadius(1.dp.toPx())
            )
        }

        // Scrubber line
        val scrubX = progress * size.width
        drawLine(
            color = scrubberColor,
            start = Offset(scrubX, 0f),
            end = Offset(scrubX, maxHeight),
            strokeWidth = 2.dp.toPx()
        )
    }
}
