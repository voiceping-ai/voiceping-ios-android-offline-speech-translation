package com.voiceping.offlinetranscription.service

/**
 * Abstraction over different ASR backends (whisper.cpp, sherpa-onnx offline, sherpa-onnx streaming).
 * Each implementation handles model loading, transcription, and resource cleanup.
 */
interface AsrEngine {
    /** Load a model from the given directory/file path. Returns true on success. */
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

    // -- Streaming support (default no-ops for offline engines) --

    /** Whether this engine supports real-time streaming transcription. */
    val isStreaming: Boolean get() = false

    /** Feed audio samples to the streaming decoder. Scaled to [-32768, 32768] internally. */
    fun feedAudio(samples: FloatArray) {}

    /** Poll the current streaming result. Returns null if no text available. */
    fun getStreamingResult(): TranscriptionSegment? = null

    /** Check if an utterance endpoint (trailing silence) has been detected. */
    fun isEndpointDetected(): Boolean = false

    /** Reset streaming state for the next utterance after endpoint detection. */
    fun resetStreamingState() {}
}
