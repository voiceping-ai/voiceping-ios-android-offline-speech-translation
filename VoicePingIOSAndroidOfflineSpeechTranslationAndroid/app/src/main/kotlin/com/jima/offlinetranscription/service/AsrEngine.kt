package com.voiceping.offlinetranscription.service

/**
 * Abstraction over ASR backends (sherpa-onnx offline).
 * Handles model loading, transcription, and resource cleanup.
 */
interface AsrEngine {
    /** Load a model from the given directory path. Returns true on success. */
    suspend fun loadModel(modelPath: String): Boolean

    /** Transcribe audio samples (16kHz mono float). Returns segments with timestamps. */
    suspend fun transcribe(
        audioSamples: FloatArray,
        numThreads: Int,
        language: String
    ): List<TranscriptionSegment>

    /** Whether a model is currently loaded and ready for transcription. */
    val isLoaded: Boolean

    /** Release all native resources. Must be called before discarding the engine. */
    fun release()
}
