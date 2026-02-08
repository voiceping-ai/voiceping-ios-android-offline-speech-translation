package com.voiceping.offlinetranscription.service

/**
 * Manages chunk-based windowing for streaming ASR inference.
 *
 * Audio is divided into fixed-size chunks (default 15s). Each chunk is
 * transcribed independently; when the buffer crosses a chunk boundary,
 * the current hypothesis is confirmed and accumulated into [completedChunksText].
 *
 * This class is pure Kotlin with no Android dependencies, making it
 * straightforward to unit test every chunking scenario.
 */
class StreamingChunkManager(
    private val chunkSeconds: Float = CHUNK_SECONDS,
    private val sampleRate: Int = 16000,
    private val minNewAudioSeconds: Float = MIN_NEW_AUDIO_SECONDS
) {
    var completedChunksText: String = ""
        private set
    var confirmedSegments = mutableListOf<TranscriptionSegment>()
        private set
    var prevUnconfirmedSegments: List<TranscriptionSegment> = emptyList()
        private set
    var lastConfirmedSegmentEndMs: Long = 0
        private set
    var consecutiveSilentWindows: Int = 0

    /** Latest confirmed text (completedChunksText + within-chunk confirmed). */
    var confirmedText: String = ""
        internal set
    /** Latest hypothesis text (unconfirmed segments in current chunk). */
    var hypothesisText: String = ""
        private set

    val chunkSamples: Int get() = (sampleRate * chunkSeconds).toInt()

    companion object {
        const val CHUNK_SECONDS = 15.0f
        const val MIN_NEW_AUDIO_SECONDS = 1.0f
        private val WHITESPACE_REGEX = "\\s+".toRegex()
    }

    /**
     * Check if the buffer has crossed a chunk boundary, and if so,
     * finalize the current chunk. Returns the audio slice range
     * (startSample, endSample, sliceOffsetMs) for the current chunk window.
     *
     * @param currentBufferSamples total samples currently in the audio buffer
     * @return a [SliceInfo] describing the audio slice to transcribe, or null
     *         if there's nothing to transcribe yet.
     */
    fun computeSlice(currentBufferSamples: Int): SliceInfo? {
        val bufferEndSeconds = currentBufferSamples.toFloat() / sampleRate
        val chunkStartSeconds = lastConfirmedSegmentEndMs.toFloat() / 1000f
        val chunkEndSeconds = chunkStartSeconds + chunkSeconds

        if (bufferEndSeconds > chunkEndSeconds) {
            finalizeCurrentChunk()
            lastConfirmedSegmentEndMs = (chunkEndSeconds * 1000).toLong()
        }

        val sliceStartSample = ((lastConfirmedSegmentEndMs * sampleRate) / 1000).toInt()
        val currentChunkEndSeconds = lastConfirmedSegmentEndMs.toFloat() / 1000f + chunkSeconds
        val sliceEndSample = minOf(
            (currentChunkEndSeconds * sampleRate).toInt(),
            currentBufferSamples
        )

        if (sliceEndSample <= sliceStartSample) return null

        return SliceInfo(
            startSample = sliceStartSample,
            endSample = sliceEndSample,
            sliceOffsetMs = lastConfirmedSegmentEndMs
        )
    }

    /**
     * Process transcription result segments from the engine.
     * Handles segment confirmation (matching consecutive identical segments)
     * and timestamp offset adjustment.
     */
    fun processTranscriptionResult(
        newSegments: List<TranscriptionSegment>,
        sliceOffsetMs: Long = 0
    ) {
        val adjustedSegments = if (sliceOffsetMs > 0) {
            newSegments.map { seg ->
                seg.copy(
                    startMs = seg.startMs + sliceOffsetMs,
                    endMs = seg.endMs + sliceOffsetMs
                )
            }
        } else {
            newSegments
        }

        if (prevUnconfirmedSegments.isNotEmpty() && adjustedSegments.isNotEmpty()) {
            var matchCount = 0
            for ((prev, new) in prevUnconfirmedSegments.zip(adjustedSegments)) {
                if (normalizeText(prev.text) == normalizeText(new.text)) {
                    matchCount++
                } else {
                    break
                }
            }

            if (matchCount > 0) {
                val newlyConfirmed = adjustedSegments.take(matchCount)
                confirmedSegments.addAll(newlyConfirmed)

                newlyConfirmed.lastOrNull()?.let {
                    lastConfirmedSegmentEndMs = it.endMs
                }

                val unconfirmed = adjustedSegments.drop(matchCount)
                prevUnconfirmedSegments = unconfirmed
                val withinChunkConfirmed = renderSegmentsText(confirmedSegments)
                confirmedText = joinChunkTexts(completedChunksText, withinChunkConfirmed)
                hypothesisText = renderSegmentsText(unconfirmed)
                return
            }
        }

        prevUnconfirmedSegments = adjustedSegments
        hypothesisText = renderSegmentsText(adjustedSegments)
    }

    /**
     * Finalize the current chunk: combine all within-chunk segments into
     * [completedChunksText], then reset per-chunk state.
     * NEVER resets audio buffer (caller manages audio).
     */
    fun finalizeCurrentChunk() {
        val allSegments = confirmedSegments + prevUnconfirmedSegments
        val chunkText = renderSegmentsText(allSegments)
        if (chunkText.isNotBlank()) {
            completedChunksText = if (completedChunksText.isEmpty()) {
                chunkText
            } else {
                "$completedChunksText $chunkText"
            }
        }
        confirmedSegments.clear()
        prevUnconfirmedSegments = emptyList()
        confirmedText = completedChunksText
        hypothesisText = ""
    }

    /**
     * Finalize the trailing audio after recording stops.
     * Processes the final transcription segments with their offset.
     */
    fun finalizeTrailing(segments: List<TranscriptionSegment>, sliceOffsetMs: Long) {
        val adjusted = segments.map { seg ->
            seg.copy(
                startMs = seg.startMs + sliceOffsetMs,
                endMs = seg.endMs + sliceOffsetMs
            )
        }
        confirmedSegments.addAll(adjusted)
        val withinChunkConfirmed = renderSegmentsText(confirmedSegments)
        confirmedText = joinChunkTexts(completedChunksText, withinChunkConfirmed)
        hypothesisText = ""
    }

    /** Adaptive delay: increase polling interval during silence to save CPU/battery. */
    fun adaptiveDelay(): Float {
        return when {
            consecutiveSilentWindows > 5 -> minOf(minNewAudioSeconds * 3f, 3f)
            consecutiveSilentWindows > 2 -> minNewAudioSeconds * 2f
            else -> minNewAudioSeconds
        }
    }

    /** Get the full transcription text (confirmed + hypothesis). */
    fun fullTranscriptionText(): String {
        return normalizeText(
            listOf(confirmedText, hypothesisText)
                .filter { it.isNotBlank() }
                .joinToString(" ")
        )
    }

    /** Reset all state for a new session. */
    fun reset() {
        completedChunksText = ""
        confirmedSegments.clear()
        prevUnconfirmedSegments = emptyList()
        lastConfirmedSegmentEndMs = 0
        consecutiveSilentWindows = 0
        confirmedText = ""
        hypothesisText = ""
    }

    fun renderSegmentsText(segments: List<TranscriptionSegment>): String {
        return segments.asSequence()
            .map { normalizeText(it.text) }
            .filter { it.isNotBlank() }
            .joinToString(" ")
    }

    fun joinChunkTexts(vararg parts: String): String {
        return parts.filter { it.isNotBlank() }.joinToString(" ")
    }

    fun normalizeText(text: String): String {
        return text.replace(WHITESPACE_REGEX, " ").trim()
    }

    data class SliceInfo(
        val startSample: Int,
        val endSample: Int,
        val sliceOffsetMs: Long
    )
}
