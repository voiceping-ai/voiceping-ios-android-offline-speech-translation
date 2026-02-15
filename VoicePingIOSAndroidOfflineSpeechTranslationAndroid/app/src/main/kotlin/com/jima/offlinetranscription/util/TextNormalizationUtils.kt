package com.voiceping.offlinetranscription.util

/**
 * Shared text normalization utilities for CJK spacing and language code handling.
 * Used by WhisperEngine, StreamingChunkManager, SherpaOnnxEngine, and MlKitTranslator.
 */
object TextNormalizationUtils {

    private val WHITESPACE_REGEX = "\\s+".toRegex()
    private const val CJK_CHAR_CLASS =
        "[\\p{IsHan}\\p{IsHiragana}\\p{IsKatakana}\\p{IsHangul}々〆ヵヶー]"
    private val CJK_INNER_SPACE_REGEX =
        "($CJK_CHAR_CLASS)\\s+($CJK_CHAR_CLASS)".toRegex()
    private val SPACE_BEFORE_CJK_PUNCT_REGEX =
        "\\s+([、。！？：；）」』】〉》])".toRegex()
    private val SPACE_AFTER_CJK_OPEN_PUNCT_REGEX =
        "([（「『【〈《])\\s+".toRegex()
    private val SPACE_AFTER_CJK_END_PUNCT_REGEX =
        "([、。！？：；])\\s+($CJK_CHAR_CLASS)".toRegex()

    /**
     * Collapse whitespace and normalize CJK spacing.
     * Removes spaces between CJK characters and around CJK punctuation.
     */
    fun normalizeText(text: String): String {
        val collapsed = text.replace(WHITESPACE_REGEX, " ").trim()
        return normalizeCjkSpacing(collapsed)
    }

    private fun normalizeCjkSpacing(text: String): String {
        var current = text
        while (true) {
            var next = current
            next = CJK_INNER_SPACE_REGEX.replace(next, "$1$2")
            next = SPACE_BEFORE_CJK_PUNCT_REGEX.replace(next, "$1")
            next = SPACE_AFTER_CJK_OPEN_PUNCT_REGEX.replace(next, "$1")
            next = SPACE_AFTER_CJK_END_PUNCT_REGEX.replace(next, "$1$2")
            if (next == current) return next
            current = next
        }
    }

    /**
     * Normalize a language code from any ASR engine into plain BCP-47 base form.
     * Handles SenseVoice's "<|en|>" format, strips region subtags, lowercases.
     * Returns null if the input is blank or empty after normalization.
     */
    fun normalizeLanguageCode(raw: String?): String? {
        if (raw.isNullOrBlank()) return null
        val cleaned = raw
            .replace("<|", "").replace("|>", "")
            .trim().lowercase()
            .split("-").first()
        return cleaned.takeIf { it.isNotBlank() && it.all { c -> c.isLetter() } }
    }
}
