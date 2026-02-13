package com.voiceping.offlinetranscription.service

import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Tests for [WhisperEngine.normalizeLanguageCode] which normalizes ASR-detected
 * language codes into plain BCP-47 base form.
 *
 * Critical for translation: SenseVoice returns "<|en|>" format which must be
 * stripped before comparison/use in ML Kit, Android System translator, and TTS.
 */
class LanguageCodeNormalizationTest {

    @Test
    fun normalizeLanguageCode_plainCode_returnsAsIs() {
        assertEquals("en", WhisperEngine.normalizeLanguageCode("en"))
        assertEquals("ja", WhisperEngine.normalizeLanguageCode("ja"))
        assertEquals("zh", WhisperEngine.normalizeLanguageCode("zh"))
        assertEquals("es", WhisperEngine.normalizeLanguageCode("es"))
    }

    @Test
    fun normalizeLanguageCode_senseVoiceFormat_stripsMarkers() {
        assertEquals("en", WhisperEngine.normalizeLanguageCode("<|en|>"))
        assertEquals("ja", WhisperEngine.normalizeLanguageCode("<|ja|>"))
        assertEquals("zh", WhisperEngine.normalizeLanguageCode("<|zh|>"))
        assertEquals("ko", WhisperEngine.normalizeLanguageCode("<|ko|>"))
        assertEquals("de", WhisperEngine.normalizeLanguageCode("<|de|>"))
    }

    @Test
    fun normalizeLanguageCode_bcp47WithRegion_stripsRegion() {
        assertEquals("en", WhisperEngine.normalizeLanguageCode("en-US"))
        assertEquals("zh", WhisperEngine.normalizeLanguageCode("zh-Hans"))
        assertEquals("pt", WhisperEngine.normalizeLanguageCode("pt-BR"))
        assertEquals("es", WhisperEngine.normalizeLanguageCode("es-419"))
    }

    @Test
    fun normalizeLanguageCode_uppercase_lowercases() {
        assertEquals("en", WhisperEngine.normalizeLanguageCode("EN"))
        assertEquals("ja", WhisperEngine.normalizeLanguageCode("JA"))
        assertEquals("en", WhisperEngine.normalizeLanguageCode("En-US"))
    }

    @Test
    fun normalizeLanguageCode_withWhitespace_trims() {
        assertEquals("en", WhisperEngine.normalizeLanguageCode("  en  "))
        assertEquals("ja", WhisperEngine.normalizeLanguageCode(" <|ja|> "))
    }

    @Test
    fun normalizeLanguageCode_null_returnsNull() {
        assertNull(WhisperEngine.normalizeLanguageCode(null))
    }

    @Test
    fun normalizeLanguageCode_blank_returnsNull() {
        assertNull(WhisperEngine.normalizeLanguageCode(""))
        assertNull(WhisperEngine.normalizeLanguageCode("   "))
    }

    @Test
    fun normalizeLanguageCode_emptyAfterStripping_returnsNull() {
        assertNull(WhisperEngine.normalizeLanguageCode("<||>"))
        assertNull(WhisperEngine.normalizeLanguageCode("<|  |>"))
    }

    @Test
    fun normalizeLanguageCode_nonLetters_returnsNull() {
        // Codes containing digits or special characters should be rejected
        assertNull(WhisperEngine.normalizeLanguageCode("en2"))
        assertNull(WhisperEngine.normalizeLanguageCode("12"))
        assertNull(WhisperEngine.normalizeLanguageCode("<|123|>"))
    }

    @Test
    fun normalizeLanguageCode_partialSenseVoiceMarkers_handledGracefully() {
        // If only one marker is present, still strip it
        assertEquals("en", WhisperEngine.normalizeLanguageCode("<|en"))
        assertEquals("ja", WhisperEngine.normalizeLanguageCode("ja|>"))
    }
}
