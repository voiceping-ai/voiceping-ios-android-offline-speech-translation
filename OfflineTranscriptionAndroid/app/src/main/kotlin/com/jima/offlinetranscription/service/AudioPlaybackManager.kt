package com.voiceping.offlinetranscription.service

import android.media.MediaPlayer
import android.util.Log
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File

/**
 * Manages audio playback of WAV files with position tracking.
 * Call [release] when done to free resources.
 */
class AudioPlaybackManager {

    private var mediaPlayer: MediaPlayer? = null
    private var pollingJob: Job? = null

    private val _isPlaying = MutableStateFlow(false)
    val isPlaying: StateFlow<Boolean> = _isPlaying.asStateFlow()

    private val _currentPositionMs = MutableStateFlow(0)
    val currentPositionMs: StateFlow<Int> = _currentPositionMs.asStateFlow()

    private val _durationMs = MutableStateFlow(0)
    val durationMs: StateFlow<Int> = _durationMs.asStateFlow()

    fun load(audioFile: File) {
        release()
        if (!audioFile.exists()) {
            Log.w("AudioPlayback", "File not found: ${audioFile.absolutePath}")
            return
        }

        try {
            mediaPlayer = MediaPlayer().apply {
                setDataSource(audioFile.absolutePath)
                prepare()
                _durationMs.value = duration
                setOnCompletionListener {
                    _isPlaying.value = false
                    _currentPositionMs.value = 0
                    seekTo(0)
                    stopPolling()
                }
            }
        } catch (e: Exception) {
            Log.e("AudioPlayback", "Failed to load audio", e)
        }
    }

    fun togglePlayPause() {
        val player = mediaPlayer ?: return
        if (player.isPlaying) {
            player.pause()
            _isPlaying.value = false
            stopPolling()
        } else {
            player.start()
            _isPlaying.value = true
            startPolling()
        }
    }

    fun seekTo(fraction: Float) {
        val player = mediaPlayer ?: return
        val ms = (fraction * player.duration).toInt().coerceIn(0, player.duration)
        player.seekTo(ms)
        _currentPositionMs.value = ms
    }

    fun release() {
        stopPolling()
        mediaPlayer?.release()
        mediaPlayer = null
        _isPlaying.value = false
        _currentPositionMs.value = 0
        _durationMs.value = 0
    }

    private fun startPolling() {
        stopPolling()
        pollingJob = CoroutineScope(Dispatchers.Main).launch {
            while (isActive) {
                mediaPlayer?.let { player ->
                    if (player.isPlaying) {
                        _currentPositionMs.value = player.currentPosition
                    }
                }
                delay(50)
            }
        }
    }

    private fun stopPolling() {
        pollingJob?.cancel()
        pollingJob = null
    }
}
