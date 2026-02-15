package com.voiceping.offlinetranscription.util

import com.voiceping.offlinetranscription.service.AudioConstants
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Writes Float32 audio samples to a 16-bit PCM WAV file (16kHz mono).
 */
object WavWriter {

    private const val HEADER_SIZE = 44
    private const val BITS_PER_SAMPLE = 16
    private const val NUM_CHANNELS = 1
    private const val CHUNK_SIZE = 4096

    fun write(samples: FloatArray, sampleRate: Int = AudioConstants.SAMPLE_RATE, outputFile: File) {
        val dataSize = samples.size * (BITS_PER_SAMPLE / 8) * NUM_CHANNELS
        val fileSize = HEADER_SIZE + dataSize

        outputFile.parentFile?.mkdirs()

        BufferedOutputStream(FileOutputStream(outputFile)).use { out ->
            // Write WAV header
            out.write(buildHeader(sampleRate, dataSize, fileSize))

            // Write PCM data in chunks to avoid doubling memory
            val buf = ByteBuffer.allocate(CHUNK_SIZE * 2).order(ByteOrder.LITTLE_ENDIAN)
            var offset = 0
            while (offset < samples.size) {
                buf.clear()
                val end = minOf(offset + CHUNK_SIZE, samples.size)
                for (i in offset until end) {
                    val clamped = samples[i].coerceIn(-1f, 1f)
                    val int16 = (clamped * 32767f).toInt().toShort()
                    buf.putShort(int16)
                }
                out.write(buf.array(), 0, buf.position())
                offset = end
            }
        }
    }

    private fun buildHeader(sampleRate: Int, dataSize: Int, fileSize: Int): ByteArray {
        val byteRate = sampleRate * NUM_CHANNELS * (BITS_PER_SAMPLE / 8)
        val blockAlign = NUM_CHANNELS * (BITS_PER_SAMPLE / 8)

        return ByteBuffer.allocate(HEADER_SIZE).order(ByteOrder.LITTLE_ENDIAN).apply {
            // RIFF chunk
            put("RIFF".toByteArray(Charsets.US_ASCII))
            putInt(fileSize - 8)
            put("WAVE".toByteArray(Charsets.US_ASCII))

            // fmt sub-chunk
            put("fmt ".toByteArray(Charsets.US_ASCII))
            putInt(16)           // sub-chunk size
            putShort(1)          // PCM format
            putShort(NUM_CHANNELS.toShort())
            putInt(sampleRate)
            putInt(byteRate)
            putShort(blockAlign.toShort())
            putShort(BITS_PER_SAMPLE.toShort())

            // data sub-chunk
            put("data".toByteArray(Charsets.US_ASCII))
            putInt(dataSize)
        }.array()
    }
}
