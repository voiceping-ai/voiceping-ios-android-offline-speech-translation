package com.voiceping.offlinetranscription.service

import android.content.Context
import android.icu.util.ULocale
import android.os.Build
import android.os.CancellationSignal
import android.util.Log
import android.view.translation.TranslationContext
import android.view.translation.TranslationManager
import android.view.translation.TranslationRequest
import android.view.translation.TranslationRequestValue
import android.view.translation.TranslationResponse
import android.view.translation.TranslationSpec
import android.view.translation.Translator
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import java.util.concurrent.Executors
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * On-device translator backed by Android's [TranslationManager] (API 31+).
 *
 * Uses the system's built-in translation models. Language packs are managed by the OS
 * (downloaded via Settings > System > Languages). This translator works fully offline
 * once language packs are installed.
 *
 * Falls back gracefully: [isAvailable] returns false on API < 31 or when no translation
 * service is installed on the device.
 */
class AndroidSystemTranslator(private val context: Context) {

    companion object {
        private const val TAG = "AndroidSystemTranslator"
    }

    private val executor = Executors.newSingleThreadExecutor()
    private var translator: Translator? = null
    private var currentSourceLang: String? = null
    private var currentTargetLang: String? = null

    private val _modelReady = MutableStateFlow(false)
    val modelReady: StateFlow<Boolean> = _modelReady.asStateFlow()

    private val _downloadStatus = MutableStateFlow<String?>(null)
    val downloadStatus: StateFlow<String?> = _downloadStatus.asStateFlow()

    /** Whether the Android system translation service is available on this device. */
    val isAvailable: Boolean
        get() {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
            return try {
                val tm = context.getSystemService(TranslationManager::class.java)
                tm != null
            } catch (e: Throwable) {
                false
            }
        }

    /**
     * Translate [text] from [sourceLanguageCode] to [targetLanguageCode].
     *
     * @param sourceLanguageCode BCP-47 language code (e.g. "en", "ja")
     * @param targetLanguageCode BCP-47 language code
     * @return translated text
     * @throws UnsupportedOperationException if the API is not available or the language pair is not supported
     */
    suspend fun translate(
        text: String,
        sourceLanguageCode: String,
        targetLanguageCode: String
    ): String {
        val normalized = text.trim()
        if (normalized.isEmpty()) return ""
        if (sourceLanguageCode == targetLanguageCode) return normalized

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            throw UnsupportedOperationException(
                "Android System Translation requires API 31+. Current: ${Build.VERSION.SDK_INT}"
            )
        }

        ensureTranslator(sourceLanguageCode, targetLanguageCode)

        val activeTranslator = translator
            ?: throw IllegalStateException("Translator not available after setup.")

        return doTranslate(activeTranslator, normalized)
    }

    fun close() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            translator?.destroy()
        }
        translator = null
        currentSourceLang = null
        currentTargetLang = null
        _modelReady.value = false
        _downloadStatus.value = null
        executor.shutdown()
    }

    private suspend fun ensureTranslator(sourceLang: String, targetLang: String) {
        if (sourceLang == currentSourceLang &&
            targetLang == currentTargetLang &&
            translator != null
        ) {
            return
        }

        // Close previous
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            translator?.destroy()
        }
        translator = null

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            throw UnsupportedOperationException("Requires API 31+")
        }

        _modelReady.value = false
        _downloadStatus.value = "Setting up system translator..."

        val tm = context.getSystemService(TranslationManager::class.java)
            ?: throw UnsupportedOperationException("TranslationManager not available on this device.")

        // Defensive normalization: strip SenseVoice "<|en|>" markers and region subtags
        val normalizedSource = sourceLang.replace("<|", "").replace("|>", "")
            .trim().lowercase().split("-").first()
        val normalizedTarget = targetLang.replace("<|", "").replace("|>", "")
            .trim().lowercase().split("-").first()

        if (normalizedSource.isBlank() || normalizedTarget.isBlank()) {
            throw UnsupportedOperationException(
                "Invalid language codes: source='$sourceLang', target='$targetLang'"
            )
        }

        val sourceSpec = TranslationSpec(
            ULocale(normalizedSource),
            TranslationSpec.DATA_FORMAT_TEXT
        )
        val targetSpec = TranslationSpec(
            ULocale(normalizedTarget),
            TranslationSpec.DATA_FORMAT_TEXT
        )

        val translationContext = TranslationContext.Builder(sourceSpec, targetSpec).build()

        val newTranslator = withTimeout(15_000) {
            suspendCancellableCoroutine { continuation ->
                tm.createOnDeviceTranslator(translationContext, executor) { translator ->
                    if (continuation.isActive) {
                        continuation.resume(translator)
                    }
                }
            }
        }

        translator = newTranslator
        currentSourceLang = normalizedSource
        currentTargetLang = normalizedTarget
        _modelReady.value = true
        _downloadStatus.value = null
        Log.i(TAG, "System translator ready: $normalizedSource -> $normalizedTarget")
    }

    private suspend fun doTranslate(translator: Translator, text: String): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            throw UnsupportedOperationException("Requires API 31+")
        }

        val request = TranslationRequest.Builder()
            .setTranslationRequestValues(listOf(TranslationRequestValue.forText(text)))
            .setFlags(TranslationRequest.FLAG_TRANSLATION_RESULT)
            .build()

        return suspendCancellableCoroutine { continuation ->
            translator.translate(request, null as CancellationSignal?, executor) { response ->
                try {
                    val status = response.translationStatus
                    if (status != TranslationResponse.TRANSLATION_STATUS_SUCCESS) {
                        if (continuation.isActive) {
                            continuation.resumeWithException(
                                UnsupportedOperationException(
                                    "System translation failed with status: $status"
                                )
                            )
                        }
                        return@translate
                    }

                    val values = response.translationResponseValues
                    val translated = if (values.size() > 0) {
                        values.valueAt(0)?.text?.toString() ?: text
                    } else {
                        text
                    }
                    if (continuation.isActive) {
                        continuation.resume(translated)
                    }
                } catch (e: Throwable) {
                    if (continuation.isActive) {
                        continuation.resumeWithException(e)
                    }
                }
            }
        }
    }
}
