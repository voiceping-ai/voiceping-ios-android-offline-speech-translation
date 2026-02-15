package com.voiceping.offlinetranscription.service

/** Audio-related constants shared across AudioRecorder, WhisperEngine, and ASR engines. */
object AudioConstants {
    /** Standard sample rate for all ASR engines (16 kHz mono). */
    const val SAMPLE_RATE = 16000

    /** PCM 16-bit maximum value for int-to-float normalization. */
    const val PCM_16BIT_MAX = 32768.0f

    /** Maximum energy history size before trimming. */
    const val MAX_ENERGY_HISTORY_SIZE = 500

    /** Recent energy window size for peak level calculation. */
    const val RECENT_ENERGY_WINDOW = 30

    // -- Auto-gain thresholds (for quiet mic compensation) --

    /** Target peak level for auto-gain normalization. */
    const val GAIN_TARGET_LEVEL = 0.20f

    /** Peak below this → maximum gain (64x). */
    const val GAIN_THRESHOLD_VERY_QUIET = 0.002f
    const val GAIN_MAX_VERY_QUIET = 64f

    /** Peak below this → moderate gain (24x). */
    const val GAIN_THRESHOLD_QUIET = 0.01f
    const val GAIN_MAX_QUIET = 24f

    /** Peak below this → light gain (8x). */
    const val GAIN_THRESHOLD_LOW = 0.03f
    const val GAIN_MAX_LOW = 8f
}
