package com.voiceping.offlinetranscription.util

object FormatUtils {
    fun formatDuration(seconds: Double): String {
        val totalSeconds = maxOf(0, seconds.toInt())
        val hours = totalSeconds / 3600
        val minutes = (totalSeconds % 3600) / 60
        val secs = totalSeconds % 60
        return if (hours > 0) {
            String.format("%d:%02d:%02d", hours, minutes, secs)
        } else {
            String.format("%d:%02d", minutes, secs)
        }
    }

}
