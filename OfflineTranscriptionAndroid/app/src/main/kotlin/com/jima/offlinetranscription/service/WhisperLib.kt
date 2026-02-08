package com.voiceping.offlinetranscription.service

object WhisperLib {
    init {
        System.loadLibrary("whisper_jni")
    }

    /** Initialize a whisper context from a model file path. Returns context pointer (0 on failure). */
    external fun initContext(modelPath: String): Long

    /** Run full transcription on audio data. Returns 0 on success. */
    external fun transcribe(
        contextPtr: Long,
        audioData: FloatArray,
        numThreads: Int,
        translate: Boolean,
        language: String
    ): Int

    /** Get the number of text segments from the last transcription. */
    external fun getSegmentCount(contextPtr: Long): Int

    /** Get the text of a specific segment. */
    external fun getSegmentText(contextPtr: Long, index: Int): String

    /** Get the start time (in centiseconds) of a specific segment. */
    external fun getSegmentStartTime(contextPtr: Long, index: Int): Long

    /** Get the end time (in centiseconds) of a specific segment. */
    external fun getSegmentEndTime(contextPtr: Long, index: Int): Long

    /** Free a whisper context. */
    external fun freeContext(contextPtr: Long)
}
