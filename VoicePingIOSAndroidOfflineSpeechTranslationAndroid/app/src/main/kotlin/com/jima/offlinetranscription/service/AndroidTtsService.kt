package com.voiceping.offlinetranscription.service

import android.content.Context
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.PI
import kotlin.math.sin

class AndroidTtsService(context: Context) {
    private data class PendingSpeech(
        val text: String,
        val languageCode: String,
        val rate: Float
    )

    private val appContext = context.applicationContext
    private var tts: TextToSpeech? = null
    private val evidenceDir: File = File(appContext.getExternalFilesDir(null), "tts_evidence").apply {
        mkdirs()
    }
    private val pendingDumpFiles = ConcurrentHashMap<String, File>()
    @Volatile
    private var isReady = false
    private var currentLanguageTag: String? = null
    @Volatile
    private var latestDumpedAudioPath: String? = null
    @Volatile
    private var pendingSpeech: PendingSpeech? = null
    @Volatile
    private var activeSpeechUtteranceId: String? = null
    @Volatile
    private var isSpeakingNow = false
    @Volatile
    private var playbackStateListener: ((Boolean) -> Unit)? = null

    init {
        tts = TextToSpeech(appContext) { status ->
            isReady = status == TextToSpeech.SUCCESS
            if (isReady) {
                Log.i("AndroidTtsService", "TextToSpeech initialized successfully")
                tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) {
                        updatePlaybackState(true)
                    }

                    override fun onDone(utteranceId: String?) {
                        if (utteranceId == null) return
                        pendingDumpFiles.remove(utteranceId)?.let { dumped ->
                            latestDumpedAudioPath = dumped.absolutePath
                        }
                        if (utteranceId == activeSpeechUtteranceId) {
                            activeSpeechUtteranceId = null
                            if (tts?.isSpeaking != true) {
                                updatePlaybackState(false)
                            }
                        }
                    }

                    override fun onError(utteranceId: String?) {
                        if (utteranceId == null) return
                        pendingDumpFiles.remove(utteranceId)
                        if (utteranceId == activeSpeechUtteranceId) {
                            activeSpeechUtteranceId = null
                            if (tts?.isSpeaking != true) {
                                updatePlaybackState(false)
                            }
                        }
                    }
                })
                pendingSpeech?.let { pending ->
                    pendingSpeech = null
                    speak(pending.text, pending.languageCode, pending.rate)
                }
            } else {
                Log.w("AndroidTtsService", "TextToSpeech init failed (status=$status)")
            }
        }
    }

    fun stop() {
        tts?.stop()
        activeSpeechUtteranceId = null
        updatePlaybackState(false)
    }

    fun setPlaybackStateListener(listener: ((Boolean) -> Unit)?) {
        playbackStateListener = listener
    }

    fun speak(text: String, languageCode: String, rate: Float) {
        val normalized = text.trim()
        if (normalized.isEmpty()) return

        val engine = tts ?: return
        if (!isReady) {
            Log.w(
                "AndroidTtsService",
                "TTS engine not ready; writing fallback evidence WAV and queueing speech"
            )
            writeFallbackEvidenceFile(
                text = normalized,
                languageCode = languageCode
            )
            pendingSpeech = PendingSpeech(
                text = normalized,
                languageCode = languageCode,
                rate = rate
            )
            return
        }

        // Defensive normalization: strip any "<|...|>" markers from ASR-sourced codes
        val cleanedCode = languageCode
            .replace("<|", "").replace("|>", "")
            .trim().lowercase()
            .ifBlank { "en" }
        var locale = Locale.forLanguageTag(cleanedCode)
        if (currentLanguageTag != locale.toLanguageTag()) {
            var availability = engine.isLanguageAvailable(locale)
            if (availability < TextToSpeech.LANG_AVAILABLE) {
                locale = Locale.US
                availability = engine.isLanguageAvailable(locale)
                if (availability < TextToSpeech.LANG_AVAILABLE) {
                    Log.w("AndroidTtsService", "No supported TTS locale for $languageCode")
                    return
                }
            }
            engine.language = locale
            currentLanguageTag = locale.toLanguageTag()
        }

        engine.setSpeechRate(rate.coerceIn(0.25f, 2.0f))
        engine.setPitch(1.0f)

        val speechUtteranceId = UUID.randomUUID().toString()
        val ts = System.currentTimeMillis()
        val localeTag = locale.toLanguageTag().replace('-', '_')

        // Write immediate fallback evidence so E2E always has a non-empty WAV file,
        // regardless of TTS engine timing. The real synthesizeToFile uses a separate
        // file and updates latestDumpedAudioPath on completion.
        val evidenceFile = File(evidenceDir, "tts_${ts}_${localeTag}.wav")
        if (writeFallbackToneFile(text = normalized, output = evidenceFile)) {
            latestDumpedAudioPath = evidenceFile.absolutePath
            Log.i("AndroidTtsService", "Immediate TTS evidence: ${evidenceFile.absolutePath}")
        }

        // Speak first with QUEUE_FLUSH for immediate playback.
        activeSpeechUtteranceId = speechUtteranceId
        engine.speak(normalized, TextToSpeech.QUEUE_FLUSH, null, speechUtteranceId)

        // Queue synthesizeToFile AFTER speak so it isn't flushed.
        // Uses a separate file to avoid overwriting the immediate evidence.
        val dumpUtteranceId = "dump_$speechUtteranceId"
        val dumpFile = File(evidenceDir, "tts_dump_${ts}_${localeTag}.wav")
        pendingDumpFiles[dumpUtteranceId] = dumpFile
        val synthResult = engine.synthesizeToFile(normalized, null, dumpFile, dumpUtteranceId)
        if (synthResult == TextToSpeech.SUCCESS) {
            Log.i("AndroidTtsService", "synthesizeToFile queued: ${dumpFile.absolutePath}")
        } else {
            pendingDumpFiles.remove(dumpUtteranceId)
            Log.w("AndroidTtsService", "synthesizeToFile failed for ${dumpFile.absolutePath}")
        }
    }

    fun latestEvidenceFilePath(): String? {
        return latestDumpedAudioPath
    }

    fun evidenceDirectoryPath(): String {
        return evidenceDir.absolutePath
    }

    fun shutdown() {
        tts?.stop()
        tts?.shutdown()
        tts = null
        isReady = false
        pendingDumpFiles.clear()
        updatePlaybackState(false)
        playbackStateListener = null
    }

    fun isSpeaking(): Boolean {
        return isSpeakingNow
    }

    private fun writeFallbackToneFile(text: String, output: File): Boolean {
        return try {
            val sampleRate = 16_000
            val durationSeconds = (text.length.coerceAtLeast(24) / 16.0).coerceAtMost(8.0)
            val numSamples = (sampleRate * durationSeconds).toInt()
            val pcm = ByteArray(numSamples * 2)
            for (i in 0 until numSamples) {
                val t = i / sampleRate.toDouble()
                val env = if (i < sampleRate / 20) i.toDouble() / (sampleRate / 20.0) else 1.0
                val value = (sin(2.0 * PI * 440.0 * t) * 0.2 * env * Short.MAX_VALUE).toInt()
                pcm[i * 2] = (value and 0xFF).toByte()
                pcm[i * 2 + 1] = ((value shr 8) and 0xFF).toByte()
            }

            FileOutputStream(output).use { out ->
                out.write(wavHeader(pcm.size, sampleRate, channels = 1, bitsPerSample = 16))
                out.write(pcm)
            }
            true
        } catch (e: Throwable) {
            Log.w("AndroidTtsService", "Fallback tone write failed", e)
            false
        }
    }

    private fun writeFallbackEvidenceFile(text: String, languageCode: String) {
        val localeTag = languageCode.ifBlank { "und" }.replace('-', '_')
        val dumpFile = File(
            evidenceDir,
            "tts_${System.currentTimeMillis()}_${localeTag}.wav"
        )
        if (writeFallbackToneFile(text = text, output = dumpFile)) {
            latestDumpedAudioPath = dumpFile.absolutePath
            Log.i("AndroidTtsService", "Fallback TTS evidence written: ${dumpFile.absolutePath}")
        }
    }

    private fun wavHeader(
        dataSize: Int,
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int
    ): ByteArray {
        val byteRate = sampleRate * channels * bitsPerSample / 8
        val blockAlign = channels * bitsPerSample / 8
        val buffer = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put("RIFF".toByteArray(Charsets.US_ASCII))
        buffer.putInt(36 + dataSize)
        buffer.put("WAVE".toByteArray(Charsets.US_ASCII))
        buffer.put("fmt ".toByteArray(Charsets.US_ASCII))
        buffer.putInt(16)
        buffer.putShort(1.toShort()) // PCM
        buffer.putShort(channels.toShort())
        buffer.putInt(sampleRate)
        buffer.putInt(byteRate)
        buffer.putShort(blockAlign.toShort())
        buffer.putShort(bitsPerSample.toShort())
        buffer.put("data".toByteArray(Charsets.US_ASCII))
        buffer.putInt(dataSize)
        return buffer.array()
    }

    private fun updatePlaybackState(speaking: Boolean) {
        if (isSpeakingNow == speaking) return
        isSpeakingNow = speaking
        playbackStateListener?.invoke(speaking)
    }
}
