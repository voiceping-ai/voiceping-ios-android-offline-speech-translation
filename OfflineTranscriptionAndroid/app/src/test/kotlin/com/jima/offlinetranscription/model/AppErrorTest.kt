package com.voiceping.offlinetranscription.model

import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class AppErrorTest {

    @Test
    fun microphonePermissionDenied_hasNonEmptyMessage() {
        val error = AppError.MicrophonePermissionDenied()
        assertTrue(error.message.isNotEmpty())
    }

    @Test
    fun microphonePermissionDenied_hasExpectedMessage() {
        val error = AppError.MicrophonePermissionDenied()
        assertEquals("Microphone access was denied. Please enable it in Settings.", error.message)
    }

    @Test
    fun modelDownloadFailed_hasNonEmptyMessage() {
        val error = AppError.ModelDownloadFailed(RuntimeException("network timeout"))
        assertTrue(error.message.isNotEmpty())
    }

    @Test
    fun modelDownloadFailed_includesCauseMessage() {
        val cause = RuntimeException("network timeout")
        val error = AppError.ModelDownloadFailed(cause)
        assertTrue(error.message.contains("network timeout"))
    }

    @Test
    fun modelLoadFailed_hasNonEmptyMessage() {
        val error = AppError.ModelLoadFailed(RuntimeException("corrupt file"))
        assertTrue(error.message.isNotEmpty())
    }

    @Test
    fun modelLoadFailed_includesCauseMessage() {
        val cause = RuntimeException("corrupt file")
        val error = AppError.ModelLoadFailed(cause)
        assertTrue(error.message.contains("corrupt file"))
    }

    @Test
    fun transcriptionFailed_hasNonEmptyMessage() {
        val error = AppError.TranscriptionFailed(RuntimeException("out of memory"))
        assertTrue(error.message.isNotEmpty())
    }

    @Test
    fun transcriptionFailed_includesCauseMessage() {
        val cause = RuntimeException("out of memory")
        val error = AppError.TranscriptionFailed(cause)
        assertTrue(error.message.contains("out of memory"))
    }

    @Test
    fun noModelSelected_hasNonEmptyMessage() {
        val error = AppError.NoModelSelected()
        assertTrue(error.message.isNotEmpty())
    }

    @Test
    fun noModelSelected_hasExpectedMessage() {
        val error = AppError.NoModelSelected()
        assertEquals("No transcription model selected.", error.message)
    }

    @Test
    fun modelNotReady_hasNonEmptyMessage() {
        val error = AppError.ModelNotReady()
        assertTrue(error.message.isNotEmpty())
    }

    @Test
    fun modelNotReady_hasExpectedMessage() {
        val error = AppError.ModelNotReady()
        assertEquals("The transcription model is not ready yet.", error.message)
    }

    @Test
    fun allErrorVariants_canBeCreatedWithoutCrashing() {
        val errors = listOf(
            AppError.MicrophonePermissionDenied(),
            AppError.ModelDownloadFailed(RuntimeException("test")),
            AppError.ModelLoadFailed(RuntimeException("test")),
            AppError.TranscriptionFailed(RuntimeException("test")),
            AppError.TranslationUnavailable(),
            AppError.TranslationFailed(RuntimeException("test")),
            AppError.TtsFailed(RuntimeException("test")),
            AppError.NoModelSelected(),
            AppError.ModelNotReady()
        )
        assertEquals(9, errors.size)
    }

    @Test
    fun allErrorVariants_areSubtypesOfAppError() {
        val errors: List<AppError> = listOf(
            AppError.MicrophonePermissionDenied(),
            AppError.ModelDownloadFailed(RuntimeException("test")),
            AppError.ModelLoadFailed(RuntimeException("test")),
            AppError.TranscriptionFailed(RuntimeException("test")),
            AppError.TranslationUnavailable(),
            AppError.TranslationFailed(RuntimeException("test")),
            AppError.TtsFailed(RuntimeException("test")),
            AppError.NoModelSelected(),
            AppError.ModelNotReady()
        )
        errors.forEach { error ->
            assertTrue(error is AppError, "${error::class.simpleName} should be an AppError")
        }
    }

    @Test
    fun modelDownloadFailed_withNullCauseMessage_handlesGracefully() {
        // Exception with null message -> localizedMessage returns null
        val cause = RuntimeException(null as String?)
        val error = AppError.ModelDownloadFailed(cause)
        // Should not crash; message will contain "null" string interpolation
        assertTrue(error.message.isNotEmpty())
    }
}
