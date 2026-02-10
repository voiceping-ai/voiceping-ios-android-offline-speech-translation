package com.voiceping.offlinetranscription.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

@Composable
fun RecordButton(
    isRecording: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    val containerColor by animateColorAsState(
        targetValue = if (isRecording) Color(0xFFE53935) else MaterialTheme.colorScheme.primary,
        label = "recordButtonColor"
    )

    val desc = if (isRecording) "Stop recording" else "Start recording"
    FloatingActionButton(
        onClick = onClick,
        modifier = modifier
            .size(72.dp)
            .semantics { contentDescription = desc },
        shape = CircleShape,
        containerColor = containerColor,
        contentColor = Color.White,
        elevation = FloatingActionButtonDefaults.elevation(defaultElevation = 6.dp)
    ) {
        Icon(
            imageVector = if (isRecording) Icons.Filled.Stop else Icons.Filled.Mic,
            contentDescription = null,
            modifier = Modifier.size(32.dp)
        )
    }
}
