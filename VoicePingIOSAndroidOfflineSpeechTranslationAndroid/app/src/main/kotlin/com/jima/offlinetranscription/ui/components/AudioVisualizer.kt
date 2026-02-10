package com.voiceping.offlinetranscription.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

private const val BAR_COUNT = 50
private const val BAR_SPACING_DP = 2f
private const val ENERGY_THRESHOLD = 0.3f

@Composable
fun AudioVisualizer(
    energyLevels: List<Float>,
    modifier: Modifier = Modifier
) {
    val primaryColor = MaterialTheme.colorScheme.primary
    val dimColor = primaryColor.copy(alpha = 0.3f)

    Canvas(
        modifier = modifier
            .fillMaxWidth()
            .height(60.dp)
    ) {
        val displayLevels = if (energyLevels.isEmpty()) {
            List(BAR_COUNT) { 0f }
        } else {
            val suffix = energyLevels.takeLast(BAR_COUNT)
            val padding = List(maxOf(0, BAR_COUNT - suffix.size)) { 0f }
            suffix + padding
        }

        val totalSpacing = BAR_SPACING_DP * (BAR_COUNT - 1)
        val barWidth = maxOf(2f, (size.width - totalSpacing) / BAR_COUNT)

        displayLevels.forEachIndexed { index, level ->
            val barHeight = maxOf(4f, level * size.height)
            val x = index * (barWidth + BAR_SPACING_DP)
            val y = (size.height - barHeight) / 2

            drawRoundRect(
                color = if (level > ENERGY_THRESHOLD) primaryColor else dimColor,
                topLeft = Offset(x, y),
                size = Size(barWidth, barHeight),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(2f, 2f)
            )
        }
    }
}
