package com.voiceping.offlinetranscription.ui.components

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.voiceping.offlinetranscription.BuildConfig

@Composable
fun AppVersionLabel(modifier: Modifier = Modifier) {
    Text(
        text = "Offline Transcription v${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f),
        modifier = modifier
    )
}
