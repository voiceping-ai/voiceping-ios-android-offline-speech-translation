package com.voiceping.offlinetranscription.service

import android.util.Log
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.Translator
import com.google.mlkit.nl.translate.TranslatorOptions
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Offline translator backed by Google ML Kit Translation.
 *
 * Each language pair requires a ~30 MB model download (happens once).
 * Models are cached on device and work fully offline after download.
 */
class MlKitTranslator {
    companion object {
        private const val TAG = "MlKitTranslator"

        /** Map of BCP-47 codes to ML Kit TranslateLanguage codes. */
        val SUPPORTED_LANGUAGES: Map<String, String> by lazy {
            TranslateLanguage.getAllLanguages().associateBy { it }
        }
    }

    private var translator: Translator? = null
    private var currentSourceLang: String? = null
    private var currentTargetLang: String? = null

    private val _modelReady = MutableStateFlow(false)
    val modelReady: StateFlow<Boolean> = _modelReady.asStateFlow()

    private val _downloadStatus = MutableStateFlow<String?>(null)
    val downloadStatus: StateFlow<String?> = _downloadStatus.asStateFlow()

    /**
     * Translate [text] from [sourceLanguageCode] to [targetLanguageCode].
     * Downloads the required language model if not already present.
     *
     * @param sourceLanguageCode BCP-47 language code (e.g. "en", "ja", "es")
     * @param targetLanguageCode BCP-47 language code
     * @return translated text, or the original text if translation fails
     */
    suspend fun translate(
        text: String,
        sourceLanguageCode: String,
        targetLanguageCode: String
    ): String {
        val normalized = text.trim()
        if (normalized.isEmpty()) return ""
        if (sourceLanguageCode == targetLanguageCode) return normalized

        val srcLang = toMlKitLanguage(sourceLanguageCode)
            ?: throw UnsupportedOperationException(
                "Language '$sourceLanguageCode' is not supported by ML Kit Translation."
            )
        val tgtLang = toMlKitLanguage(targetLanguageCode)
            ?: throw UnsupportedOperationException(
                "Language '$targetLanguageCode' is not supported by ML Kit Translation."
            )

        ensureTranslator(srcLang, tgtLang)

        val activeTranslator = translator
            ?: throw IllegalStateException("Translator not available after setup.")

        return suspendCancellableCoroutine { continuation ->
            activeTranslator.translate(normalized)
                .addOnSuccessListener { translatedText ->
                    if (continuation.isActive) {
                        continuation.resume(translatedText ?: normalized)
                    }
                }
                .addOnFailureListener { e ->
                    if (continuation.isActive) {
                        continuation.resumeWithException(e)
                    }
                }
        }
    }

    fun close() {
        translator?.close()
        translator = null
        currentSourceLang = null
        currentTargetLang = null
        _modelReady.value = false
        _downloadStatus.value = null
    }

    private suspend fun ensureTranslator(sourceLang: String, targetLang: String) {
        if (sourceLang == currentSourceLang &&
            targetLang == currentTargetLang &&
            translator != null &&
            _modelReady.value
        ) {
            return
        }

        // Close previous translator
        translator?.close()
        translator = null
        currentSourceLang = null
        currentTargetLang = null
        _modelReady.value = false
        _downloadStatus.value = "Downloading translation model..."

        val options = TranslatorOptions.Builder()
            .setSourceLanguage(sourceLang)
            .setTargetLanguage(targetLang)
            .build()

        val newTranslator = Translation.getClient(options)

        // Download model if needed (wifi not required for offline-first app)
        val conditions = DownloadConditions.Builder().build()

        suspendCancellableCoroutine { continuation ->
            newTranslator.downloadModelIfNeeded(conditions)
                .addOnSuccessListener {
                    // Only assign after download succeeds to avoid stale translator on cancellation
                    translator = newTranslator
                    currentSourceLang = sourceLang
                    currentTargetLang = targetLang
                    _modelReady.value = true
                    _downloadStatus.value = null
                    Log.i(TAG, "Translation model ready: $sourceLang -> $targetLang")
                    if (continuation.isActive) {
                        continuation.resume(Unit)
                    }
                }
                .addOnFailureListener { e ->
                    newTranslator.close()
                    _modelReady.value = false
                    _downloadStatus.value = "Model download failed: ${e.localizedMessage}"
                    Log.e(TAG, "Failed to download translation model: $sourceLang -> $targetLang", e)
                    if (continuation.isActive) {
                        continuation.resumeWithException(e)
                    }
                }
        }
    }

    /**
     * Convert a BCP-47 language code to an ML Kit TranslateLanguage constant.
     * ML Kit uses BCP-47 codes directly, but we validate against supported languages.
     */
    private fun toMlKitLanguage(bcp47Code: String): String? {
        // Defensive normalization: strip SenseVoice "<|en|>" markers and region subtags
        val code = bcp47Code
            .replace("<|", "").replace("|>", "")
            .trim().lowercase()
            .split("-").first()
        return if (code.isNotBlank() && TranslateLanguage.getAllLanguages().contains(code)) code else null
    }
}
