package com.voiceping.offlinetranscription.service

import android.Manifest
import android.app.Activity
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import com.voiceping.offlinetranscription.model.AudioInputMode
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt
import kotlin.coroutines.coroutineContext

class AudioRecorder(private val context: Context) {

    companion object {
        const val SAMPLE_RATE = AudioConstants.SAMPLE_RATE
        private const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        private const val CHUNK_SIZE = AudioConstants.SAMPLE_RATE / 10 // 100ms at 16kHz
    }

    private enum class RecorderFormat(val audioEncoding: Int, val bytesPerSample: Int) {
        PcmFloat(AudioFormat.ENCODING_PCM_FLOAT, 4),
        Pcm16Bit(AudioFormat.ENCODING_PCM_16BIT, 2),
    }

    private enum class RecorderSource(val source: Int, val label: String) {
        Mic(MediaRecorder.AudioSource.MIC, "MIC"),
        VoiceRecognition(MediaRecorder.AudioSource.VOICE_RECOGNITION, "VOICE_RECOGNITION"),
        Camcorder(MediaRecorder.AudioSource.CAMCORDER, "CAMCORDER"),
        Default(MediaRecorder.AudioSource.DEFAULT, "DEFAULT"),
    }

    private data class RecorderConfig(
        val inputMode: AudioInputMode,
        val source: RecorderSource?,
        val format: RecorderFormat,
    ) {
        val sourceLabel: String
            get() = when (inputMode) {
                AudioInputMode.MICROPHONE -> source?.label ?: "MIC"
                AudioInputMode.SYSTEM_PLAYBACK -> "SYSTEM_PLAYBACK"
            }
    }

    private var audioRecord: AudioRecord? = null
    private var activeConfig: RecorderConfig? = null
    private var preferredConfig: RecorderConfig? = null
    private var mediaProjection: MediaProjection? = null
    // Use ArrayList with initial capacity to reduce reallocation overhead
    private val audioBuffer = ArrayList<Float>(SAMPLE_RATE * 60) // Pre-allocate ~1 min
    private val energyHistory = ArrayList<Float>(500)
    private var droppedSampleCount = 0

    @Volatile
    var isRecording = false
        private set

    val isSystemAudioCaptureSupported: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    val hasSystemAudioCapturePermission: Boolean
        get() = mediaProjection != null

    fun hasPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            context, Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
    }

    fun setSystemAudioCapturePermission(resultCode: Int, data: Intent?): Boolean {
        clearSystemAudioCapturePermission()
        if (!isSystemAudioCaptureSupported) return false
        if (resultCode != Activity.RESULT_OK || data == null) return false
        val manager = context.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as? MediaProjectionManager
            ?: return false
        mediaProjection = manager.getMediaProjection(resultCode, data)
        return mediaProjection != null
    }

    fun clearSystemAudioCapturePermission() {
        mediaProjection?.stop()
        mediaProjection = null
    }

    val samples: FloatArray
        get() = synchronized(audioBuffer) { audioBuffer.toFloatArray() }

    val sampleCount: Int
        get() = synchronized(audioBuffer) { droppedSampleCount + audioBuffer.size }

    val relativeEnergy: List<Float>
        get() = synchronized(energyHistory) { energyHistory.toList() }

    val bufferSeconds: Double
        get() = synchronized(audioBuffer) { (droppedSampleCount + audioBuffer.size).toDouble() / SAMPLE_RATE }

    val maxRecentEnergy: Float
        get() = synchronized(energyHistory) { energyHistory.takeLast(AudioConstants.RECENT_ENERGY_WINDOW).maxOrNull() ?: 0f }

    /** True if early samples were trimmed during recording (audio WAV will be incomplete). */
    val hasDroppedSamples: Boolean
        get() = synchronized(audioBuffer) { droppedSampleCount > 0 }

    /** Return a subrange of the audio buffer as a FloatArray. Indices are clamped to valid range. */
    fun samplesRange(fromIndex: Int, toIndex: Int): FloatArray {
        synchronized(audioBuffer) {
            val absoluteFrom = fromIndex.coerceAtLeast(0)
            val absoluteTo = toIndex.coerceAtLeast(absoluteFrom)
            val localFrom = (absoluteFrom - droppedSampleCount).coerceIn(0, audioBuffer.size)
            val localTo = (absoluteTo - droppedSampleCount).coerceIn(localFrom, audioBuffer.size)
            if (localFrom == localTo) return FloatArray(0)
            return audioBuffer.subList(localFrom, localTo).toFloatArray()
        }
    }

    /**
     * Discard old audio samples before an absolute sample index.
     * Returns the number of samples actually dropped.
     */
    fun discardSamples(beforeAbsoluteIndex: Int): Int {
        synchronized(audioBuffer) {
            val target = beforeAbsoluteIndex.coerceAtLeast(0)
            val dropCount = (target - droppedSampleCount).coerceIn(0, audioBuffer.size)
            if (dropCount == 0) return 0
            audioBuffer.subList(0, dropCount).clear()
            droppedSampleCount += dropCount
            return dropCount
        }
    }

    fun reset() {
        synchronized(audioBuffer) {
            audioBuffer.clear()
            droppedSampleCount = 0
        }
        synchronized(energyHistory) { energyHistory.clear() }
    }

    /**
     * Pre-initialize the recorder config so first real recording starts with minimal latency.
     * Safe to call multiple times; no-op without permission or while recording.
     */
    fun prewarm(inputMode: AudioInputMode = AudioInputMode.MICROPHONE) {
        if (inputMode != AudioInputMode.MICROPHONE) return
        if (!hasPermission() || isRecording) return
        var record: AudioRecord? = null
        try {
            val (createdRecord, config) = createAudioRecordWithFallback()
            record = createdRecord
            preferredConfig = config
            record.startRecording()
            if (record.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                when (config.format) {
                    RecorderFormat.PcmFloat -> {
                        val scratch = FloatArray(CHUNK_SIZE)
                        repeat(2) {
                            record.read(scratch, 0, scratch.size, AudioRecord.READ_BLOCKING)
                        }
                    }
                    RecorderFormat.Pcm16Bit -> {
                        val scratch = ShortArray(CHUNK_SIZE)
                        repeat(2) {
                            record.read(scratch, 0, scratch.size, AudioRecord.READ_BLOCKING)
                        }
                    }
                }
            }
            Log.i("AudioRecorder", "Prewarmed source=${config.sourceLabel} format=${config.format.name}")
        } catch (e: Throwable) {
            Log.w("AudioRecorder", "Prewarm failed", e)
        } finally {
            try {
                record?.stop()
            } catch (_: Throwable) {
            }
            record?.release()
        }
    }

    @Suppress("MissingPermission")
    suspend fun startRecording(inputMode: AudioInputMode = AudioInputMode.MICROPHONE) {
        if (!hasPermission()) throw SecurityException("RECORD_AUDIO permission not granted")

        val (record, config) = when (inputMode) {
            AudioInputMode.MICROPHONE -> createAudioRecordWithFallback()
            AudioInputMode.SYSTEM_PLAYBACK -> createSystemPlaybackAudioRecord()
        }

        audioRecord = record
        activeConfig = config
        record.startRecording()
        if (record.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            record.release()
            audioRecord = null
            activeConfig = null
            throw IllegalStateException("AudioRecord failed to enter RECORDSTATE_RECORDING")
        }

        Log.i(
            "AudioRecorder",
            "Recording started source=${config.sourceLabel} format=${config.format.name}"
        )
        isRecording = true

        withContext(Dispatchers.IO) {
            when (config.format) {
                RecorderFormat.PcmFloat -> readFloatAudioLoop()
                RecorderFormat.Pcm16Bit -> readPcm16AudioLoop()
            }
        }
    }

    fun stopRecording() {
        isRecording = false
        try {
            audioRecord?.stop()
        } catch (e: IllegalStateException) {
            Log.w("AudioRecorder", "stop() called on uninitialized AudioRecord", e)
        }
        audioRecord?.release()
        audioRecord = null
        activeConfig = null
    }

    /** Inject pre-recorded samples into the buffer (for testing without mic). */
    fun injectSamples(data: FloatArray) {
        synchronized(audioBuffer) {
            for (sample in data) {
                audioBuffer.add(sample)
            }
        }
        // Add energy entries so the visualizer works
        val chunkCount = data.size / CHUNK_SIZE
        for (i in 0 until chunkCount) {
            val offset = i * CHUNK_SIZE
            var sumSquares = 0.0
            val end = minOf(offset + CHUNK_SIZE, data.size)
            for (j in offset until end) {
                sumSquares += data[j] * data[j]
            }
            val rms = sqrt(sumSquares / (end - offset)).toFloat()
            synchronized(energyHistory) {
                energyHistory.add(rms)
                if (energyHistory.size > AudioConstants.MAX_ENERGY_HISTORY_SIZE) energyHistory.removeAt(0)
            }
        }
    }

    private fun createAudioRecordWithFallback(): Pair<AudioRecord, RecorderConfig> {
        val preferredOrder = listOf(RecorderFormat.Pcm16Bit, RecorderFormat.PcmFloat)
        val sourceOrder = listOf(
            RecorderSource.Mic,
            RecorderSource.VoiceRecognition,
            RecorderSource.Camcorder,
            RecorderSource.Default
        )
        var lastError: Throwable? = null

        // Fast path: reuse the last known working config to avoid startup probe latency.
        preferredConfig?.let { cached ->
            if (cached.inputMode != AudioInputMode.MICROPHONE || cached.source == null) {
                preferredConfig = null
                return@let
            }
            try {
                val cachedRecord = createAudioRecord(cached.source, cached.format)
                if (cachedRecord.state == AudioRecord.STATE_INITIALIZED) {
                    return cachedRecord to cached
                }
                cachedRecord.release()
            } catch (e: Throwable) {
                lastError = e
            }
        }

        for (source in sourceOrder) {
            for (format in preferredOrder) {
                try {
                    val candidate = createAudioRecord(source, format)
                    if (candidate.state == AudioRecord.STATE_INITIALIZED) {
                        val chosen = RecorderConfig(
                            inputMode = AudioInputMode.MICROPHONE,
                            source = source,
                            format = format
                        )
                        preferredConfig = chosen
                        if (chosen.source != RecorderSource.Mic) {
                            Log.w("AudioRecorder", "Using fallback audio source ${chosen.sourceLabel}")
                        }
                        if (chosen.format == RecorderFormat.PcmFloat) {
                            Log.w("AudioRecorder", "Using fallback PCM_FLOAT microphone capture")
                        }
                        Log.i(
                            "AudioRecorder",
                            "Selected audio source=${chosen.sourceLabel} format=${chosen.format.name}"
                        )
                        return candidate to chosen
                    }
                    candidate.release()
                } catch (e: Throwable) {
                    lastError = e
                }
            }
        }

        throw IllegalStateException(
            "AudioRecord failed to initialize (unsupported audio config?)",
            lastError
        )
    }

    @SuppressLint("MissingPermission")
    private fun createSystemPlaybackAudioRecord(): Pair<AudioRecord, RecorderConfig> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            throw IllegalStateException("System playback capture requires API 29+")
        }
        val projection = mediaProjection
            ?: throw IllegalStateException("System playback capture permission not granted")

        val minBufferSize = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            CHANNEL_CONFIG,
            AudioFormat.ENCODING_PCM_16BIT
        )
        if (minBufferSize <= 0) {
            throw IllegalStateException("Invalid min buffer size for playback capture")
        }
        val desiredBufferSize = CHUNK_SIZE * RecorderFormat.Pcm16Bit.bytesPerSample * 4
        val bufferSizeInBytes = maxOf(minBufferSize, desiredBufferSize)

        val format = AudioFormat.Builder()
            .setSampleRate(SAMPLE_RATE)
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setChannelMask(CHANNEL_CONFIG)
            .build()

        val captureConfig = AudioPlaybackCaptureConfiguration.Builder(projection)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()

        val record = AudioRecord.Builder()
            .setAudioFormat(format)
            .setBufferSizeInBytes(bufferSizeInBytes)
            .setAudioPlaybackCaptureConfig(captureConfig)
            .build()

        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            throw IllegalStateException("AudioPlaybackCapture AudioRecord failed to initialize")
        }

        val config = RecorderConfig(
            inputMode = AudioInputMode.SYSTEM_PLAYBACK,
            source = null,
            format = RecorderFormat.Pcm16Bit
        )
        return record to config
    }

    @SuppressLint("MissingPermission")
    private fun createAudioRecord(source: RecorderSource, format: RecorderFormat): AudioRecord {
        val minBufferSize = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            CHANNEL_CONFIG,
            format.audioEncoding
        )
        if (minBufferSize <= 0) {
            throw IllegalStateException("Invalid min buffer size for encoding=${format.audioEncoding}")
        }

        val desiredBufferSize = CHUNK_SIZE * format.bytesPerSample * 4
        val bufferSizeInBytes = maxOf(minBufferSize, desiredBufferSize)

        return AudioRecord(
            source.source,
            SAMPLE_RATE,
            CHANNEL_CONFIG,
            format.audioEncoding,
            bufferSizeInBytes
        )
    }

    private suspend fun readFloatAudioLoop() {
        val chunk = FloatArray(CHUNK_SIZE)
        while (coroutineContext.isActive && isRecording) {
            val read = audioRecord?.read(chunk, 0, CHUNK_SIZE, AudioRecord.READ_BLOCKING) ?: -1
            if (read > 0) {
                appendChunkAndEnergy(read) { index -> chunk[index] }
            }
        }
    }

    private suspend fun readPcm16AudioLoop() {
        val chunk = ShortArray(CHUNK_SIZE)
        while (coroutineContext.isActive && isRecording) {
            val read = audioRecord?.read(chunk, 0, CHUNK_SIZE, AudioRecord.READ_BLOCKING) ?: -1
            if (read > 0) {
                appendChunkAndEnergy(read) { index -> chunk[index] / AudioConstants.PCM_16BIT_MAX }
            }
        }
    }

    private inline fun appendChunkAndEnergy(
        readCount: Int,
        sampleAt: (Int) -> Float
    ) {
        if (readCount <= 0) return

        // First pass: find peak for auto-gain calculation
        var peak = 0f
        for (i in 0 until readCount) {
            peak = max(peak, abs(sampleAt(i).coerceIn(-1f, 1f)))
        }

        // Apply bounded auto gain for quiet microphones.
        val gain = when {
            peak <= 0f -> 1f
            peak < AudioConstants.GAIN_THRESHOLD_VERY_QUIET -> min(AudioConstants.GAIN_MAX_VERY_QUIET, AudioConstants.GAIN_TARGET_LEVEL / peak)
            peak < AudioConstants.GAIN_THRESHOLD_QUIET -> min(AudioConstants.GAIN_MAX_QUIET, AudioConstants.GAIN_TARGET_LEVEL / peak)
            peak < AudioConstants.GAIN_THRESHOLD_LOW -> min(AudioConstants.GAIN_MAX_LOW, AudioConstants.GAIN_TARGET_LEVEL / peak)
            else -> 1f
        }

        // Second pass: apply gain and append directly (no intermediate array)
        var sumSquares = 0.0
        synchronized(audioBuffer) {
            audioBuffer.ensureCapacity(audioBuffer.size + readCount)
            for (i in 0 until readCount) {
                val sample = (sampleAt(i).coerceIn(-1f, 1f) * gain).coerceIn(-1f, 1f)
                sumSquares += sample * sample
                audioBuffer.add(sample)
            }
        }

        val rms = sqrt(sumSquares / readCount).toFloat()
        synchronized(energyHistory) {
            energyHistory.add(rms)
            if (energyHistory.size > AudioConstants.MAX_ENERGY_HISTORY_SIZE) {
                energyHistory.removeAt(0)
            }
        }
    }

}
