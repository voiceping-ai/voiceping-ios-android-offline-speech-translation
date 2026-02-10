package com.voiceping.offlinetranscription.service

import android.content.Context
import android.os.Build
import android.view.translation.TranslationContext
import android.view.translation.TranslationManager
import android.view.translation.TranslationRequest
import android.view.translation.TranslationRequestValue
import android.view.translation.TranslationResponse
import android.view.translation.TranslationSpec
import android.view.translation.Translator
import androidx.annotation.RequiresApi
import kotlinx.coroutines.suspendCancellableCoroutine
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class AndroidNativeTranslator(context: Context) {
    private val appContext = context.applicationContext
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private var translator: Translator? = null
    private var currentSourceLanguageCode: String? = null
    private var currentTargetLanguageCode: String? = null

    suspend fun translate(
        text: String,
        sourceLanguageCode: String,
        targetLanguageCode: String
    ): String {
        val normalized = text.trim()
        if (normalized.isEmpty()) return ""
        if (sourceLanguageCode == targetLanguageCode) return normalized

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            throw UnsupportedOperationException("TranslationManager requires Android 12+.")
        }

        ensureTranslator(sourceLanguageCode, targetLanguageCode)
        val activeTranslator = translator
            ?: throw UnsupportedOperationException("No on-device translator available.")

        return translateApi31(activeTranslator, normalized)
    }

    fun close() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            translator?.destroy()
        }
        translator = null
        executor.shutdownNow()
    }

    private suspend fun ensureTranslator(sourceLanguageCode: String, targetLanguageCode: String) {
        if (sourceLanguageCode == currentSourceLanguageCode &&
            targetLanguageCode == currentTargetLanguageCode &&
            translator != null &&
            isTranslatorActive()
        ) {
            return
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            throw UnsupportedOperationException("TranslationManager requires Android 12+.")
        }

        createTranslatorApi31(sourceLanguageCode, targetLanguageCode)
        currentSourceLanguageCode = sourceLanguageCode
        currentTargetLanguageCode = targetLanguageCode
    }

    @RequiresApi(Build.VERSION_CODES.S)
    private suspend fun translateApi31(
        activeTranslator: Translator,
        normalized: String
    ): String {
        return suspendCancellableCoroutine { continuation ->
            val request = TranslationRequest.Builder()
                .setFlags(TranslationRequest.FLAG_TRANSLATION_RESULT)
                .setTranslationRequestValues(
                    listOf(TranslationRequestValue.forText(normalized))
                )
                .build()

            activeTranslator.translate(request, null, executor) { response ->
                if (!continuation.isActive) return@translate

                if (response.translationStatus != TranslationResponse.TRANSLATION_STATUS_SUCCESS) {
                    continuation.resumeWithException(
                        IllegalStateException(
                            "Translation failed with status=${response.translationStatus}"
                        )
                    )
                    return@translate
                }

                val translatedValue = response.translationResponseValues.get(0)
                val translatedText = translatedValue?.text?.toString()?.trim()
                continuation.resume(if (translatedText.isNullOrEmpty()) normalized else translatedText)
            }
        }
    }

    private fun isTranslatorActive(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        return isTranslatorActiveApi31(translator)
    }

    @RequiresApi(Build.VERSION_CODES.S)
    private fun isTranslatorActiveApi31(candidate: Translator?): Boolean {
        return candidate?.isDestroyed == false
    }

    @RequiresApi(Build.VERSION_CODES.S)
    private suspend fun createTranslatorApi31(
        sourceLanguageCode: String,
        targetLanguageCode: String
    ) {
        val manager = appContext.getSystemService(TranslationManager::class.java)
            ?: throw UnsupportedOperationException("TranslationManager is unavailable.")

        val sourceSpec = TranslationSpec(
            android.icu.util.ULocale.forLanguageTag(sourceLanguageCode),
            TranslationSpec.DATA_FORMAT_TEXT
        )
        val targetSpec = TranslationSpec(
            android.icu.util.ULocale.forLanguageTag(targetLanguageCode),
            TranslationSpec.DATA_FORMAT_TEXT
        )

        val capabilities = manager.getOnDeviceTranslationCapabilities(
            TranslationSpec.DATA_FORMAT_TEXT,
            TranslationSpec.DATA_FORMAT_TEXT
        )

        val isPairSupported = capabilities.any { capability ->
            val sourceMatches = capability.sourceSpec.locale.toLanguageTag()
                .equals(sourceSpec.locale.toLanguageTag(), ignoreCase = true)
            val targetMatches = capability.targetSpec.locale.toLanguageTag()
                .equals(targetSpec.locale.toLanguageTag(), ignoreCase = true)
            val stateSupported = capability.state == android.view.translation.TranslationCapability.STATE_ON_DEVICE ||
                capability.state == android.view.translation.TranslationCapability.STATE_AVAILABLE_TO_DOWNLOAD ||
                capability.state == android.view.translation.TranslationCapability.STATE_DOWNLOADING
            sourceMatches && targetMatches && stateSupported
        }

        if (!isPairSupported) {
            throw UnsupportedOperationException(
                "Language pair $sourceLanguageCode -> $targetLanguageCode is not supported on-device."
            )
        }

        translator?.destroy()
        translator = null

        val translationContext = TranslationContext.Builder(sourceSpec, targetSpec)
            .setTranslationFlags(TranslationContext.FLAG_LOW_LATENCY)
            .build()

        val createdTranslator = suspendCancellableCoroutine<Translator> { continuation ->
            manager.createOnDeviceTranslator(translationContext, executor) { created ->
                if (!continuation.isActive) return@createOnDeviceTranslator
                if (created == null) {
                    continuation.resumeWithException(
                        IllegalStateException("Failed to create native translator instance.")
                    )
                } else {
                    continuation.resume(created)
                }
            }
        }

        translator = createdTranslator
    }
}
