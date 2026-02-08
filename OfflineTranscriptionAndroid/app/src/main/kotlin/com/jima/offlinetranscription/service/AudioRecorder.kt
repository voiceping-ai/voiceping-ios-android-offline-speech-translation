package com.voiceping.offlinetranscription.service

import android.Manifest
import android.annotation.SuppressLint
import android.content.pm.PackageManager
import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import androidx.core.content.ContextCompat
import android.util.Log
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
        const val SAMPLE_RATE = 16000
        private const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        private const val CHUNK_SIZE = 1600 // 100ms at 16kHz
        private const val PROBE_CHUNK_SIZE = 320 // 20ms at 16kHz
        private const val PROBE_READS = 8
        private const val PROBE_EPSILON = 0.0005f
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
        val source: RecorderSource,
        val format: RecorderFormat,
    )

    private var audioRecord: AudioRecord? = null
    private var activeConfig: RecorderConfig? = null
    // Use ArrayList with initial capacity to reduce reallocation overhead
    private val audioBuffer = ArrayList<Float>(SAMPLE_RATE * 60) // Pre-allocate ~1 min
    private val energyHistory = ArrayList<Float>(500)
    private var droppedSampleCount = 0

    @Volatile
    var isRecording = false
        private set

    fun hasPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            context, Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
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
        get() = synchronized(energyHistory) { energyHistory.takeLast(30).maxOrNull() ?: 0f }

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

    @Suppress("MissingPermission")
    suspend fun startRecording() {
        if (!hasPermission()) throw SecurityException("RECORD_AUDIO permission not granted")

        val (record, config) = createAudioRecordWithFallback()

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
            "Recording started source=${config.source.label} format=${config.format.name}"
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
                if (energyHistory.size > 500) energyHistory.removeAt(0)
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
        var bestConfig: RecorderConfig? = null
        var bestProbePeak = -1f

        for (source in sourceOrder) {
            for (format in preferredOrder) {
                var candidate: AudioRecord? = null
                try {
                    candidate = createAudioRecord(source, format)
                    if (candidate.state != AudioRecord.STATE_INITIALIZED) {
                        candidate.release()
                        continue
                    }
                    val probePeak = probeInputPeak(candidate, format)
                    if (probePeak > bestProbePeak + PROBE_EPSILON) {
                        bestProbePeak = probePeak
                        bestConfig = RecorderConfig(source, format)
                    }
                } catch (e: Throwable) {
                    lastError = e
                } finally {
                    try {
                        candidate?.release()
                    } catch (_: Throwable) {
                    }
                }
            }
        }

        val chosen = bestConfig ?: throw IllegalStateException(
            "AudioRecord failed to initialize (unsupported audio config?)",
            lastError
        )

        val finalRecord = createAudioRecord(chosen.source, chosen.format)
        if (finalRecord.state != AudioRecord.STATE_INITIALIZED) {
            finalRecord.release()
            throw IllegalStateException("Failed to initialize selected AudioRecord config")
        }

        if (chosen.source != RecorderSource.Mic) {
            Log.w("AudioRecorder", "Using fallback audio source ${chosen.source.label}")
        }
        if (chosen.format == RecorderFormat.PcmFloat) {
            Log.w("AudioRecorder", "Using fallback PCM_FLOAT microphone capture")
        }
        Log.i(
            "AudioRecorder",
            "Selected audio source=${chosen.source.label} format=${chosen.format.name} probePeak=${"%.4f".format(bestProbePeak)}"
        )

        return finalRecord to chosen
    }

    private fun probeInputPeak(record: AudioRecord, format: RecorderFormat): Float {
        var maxPeak = 0f
        try {
            record.startRecording()
            if (record.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                return 0f
            }

            when (format) {
                RecorderFormat.PcmFloat -> {
                    val chunk = FloatArray(PROBE_CHUNK_SIZE)
                    var validSamples = 0
                    var clippedSamples = 0
                    repeat(PROBE_READS) {
                        val read = record.read(chunk, 0, chunk.size, AudioRecord.READ_BLOCKING)
                        if (read > 0) {
                            for (i in 0 until read) {
                                val raw = chunk[i]
                                if (!raw.isFinite()) continue
                                val absRaw = abs(raw)
                                if (absRaw > 8f) continue
                                val v = absRaw.coerceIn(0f, 1f)
                                validSamples += 1
                                if (v >= 0.99f) clippedSamples += 1
                                if (v > maxPeak) maxPeak = v
                            }
                        }
                    }
                    if (validSamples == 0) return 0f
                    val clippedRatio = clippedSamples.toFloat() / validSamples.toFloat()
                    if (clippedRatio > 0.7f) return 0f
                }
                RecorderFormat.Pcm16Bit -> {
                    val chunk = ShortArray(PROBE_CHUNK_SIZE)
                    repeat(PROBE_READS) {
                        val read = record.read(chunk, 0, chunk.size, AudioRecord.READ_BLOCKING)
                        if (read > 0) {
                            for (i in 0 until read) {
                                val v = abs(chunk[i] / 32768.0f)
                                if (v > maxPeak) maxPeak = v
                            }
                        }
                    }
                }
            }
        } catch (_: Throwable) {
            return 0f
        } finally {
            try {
                record.stop()
            } catch (_: Throwable) {
            }
        }
        return maxPeak
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
                appendChunkAndEnergy(read) { index -> chunk[index] / 32768.0f }
            }
        }
    }

    private inline fun appendChunkAndEnergy(
        readCount: Int,
        sampleAt: (Int) -> Float
    ) {
        if (readCount <= 0) return

        val normalized = FloatArray(readCount)
        var peak = 0f
        for (i in 0 until readCount) {
            val raw = sampleAt(i).coerceIn(-1f, 1f)
            normalized[i] = raw
            peak = max(peak, abs(raw))
        }

        // On emulators host mic can be extremely quiet; apply bounded auto gain.
        val gain = when {
            peak <= 0f -> 1f
            peak < 0.002f -> min(64f, 0.20f / peak)
            peak < 0.01f -> min(24f, 0.20f / peak)
            peak < 0.03f -> min(8f, 0.20f / peak)
            else -> 1f
        }

        var sumSquares = 0.0
        synchronized(audioBuffer) {
            audioBuffer.ensureCapacity(audioBuffer.size + readCount)
            for (i in 0 until readCount) {
                val sample = (normalized[i] * gain).coerceIn(-1f, 1f)
                sumSquares += sample * sample
                audioBuffer.add(sample)
            }
        }

        val rms = sqrt(sumSquares / readCount).toFloat()
        synchronized(energyHistory) {
            energyHistory.add(rms)
            if (energyHistory.size > 500) {
                energyHistory.removeAt(0)
            }
        }
    }

}
