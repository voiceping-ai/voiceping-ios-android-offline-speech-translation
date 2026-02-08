package com.voiceping.offlinetranscription.util

import kotlin.math.max
import kotlin.math.sqrt

/**
 * Downsamples audio data to a fixed number of RMS energy bars for waveform display.
 */
object WaveformGenerator {

    fun generate(samples: FloatArray, barCount: Int = 200): FloatArray {
        if (samples.isEmpty()) return FloatArray(barCount)

        val samplesPerBar = max(1, samples.size / barCount)
        val bars = FloatArray(barCount)

        for (i in 0 until barCount) {
            val start = i * samplesPerBar
            val end = minOf(start + samplesPerBar, samples.size)
            if (start >= samples.size) break

            var sumSquares = 0f
            for (j in start until end) {
                sumSquares += samples[j] * samples[j]
            }
            bars[i] = sqrt(sumSquares / (end - start))
        }

        val peak = bars.max()
        if (peak > 0f) {
            for (i in bars.indices) {
                bars[i] /= peak
            }
        }

        return bars
    }

    /**
     * Generate waveform bars from a WAV file by reading raw PCM bytes.
     * Skips the 44-byte header, reads 16-bit little-endian samples.
     */
    fun generateFromWavFile(wavFile: java.io.File, barCount: Int = 200): FloatArray {
        if (!wavFile.exists() || wavFile.length() <= 44) return FloatArray(barCount)

        val bytes = wavFile.readBytes()
        val sampleCount = (bytes.size - 44) / 2
        if (sampleCount <= 0) return FloatArray(barCount)

        val samples = FloatArray(sampleCount)
        for (i in 0 until sampleCount) {
            val offset = 44 + i * 2
            if (offset + 1 >= bytes.size) break
            val lo = bytes[offset].toInt() and 0xFF
            val hi = bytes[offset + 1].toInt()
            val int16 = (hi shl 8) or lo
            samples[i] = int16.toShort().toFloat() / 32767f
        }

        return generate(samples, barCount)
    }
}
