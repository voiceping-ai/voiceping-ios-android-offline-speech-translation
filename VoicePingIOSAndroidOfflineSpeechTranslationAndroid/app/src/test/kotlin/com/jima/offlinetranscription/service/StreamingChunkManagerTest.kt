package com.voiceping.offlinetranscription.service

import org.junit.Before
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Comprehensive tests for the chunk-based streaming inference logic.
 *
 * Each test verifies a specific scenario in the streaming inference pipeline:
 * chunk boundary detection, segment confirmation, text accumulation,
 * adaptive delay, timestamp offsetting, and state management.
 */
class StreamingChunkManagerTest {

    private lateinit var manager: StreamingChunkManager

    @Before
    fun setup() {
        manager = StreamingChunkManager(
            chunkSeconds = 15.0f,
            sampleRate = 16000,
            minNewAudioSeconds = 1.0f
        )
    }

    // ============================================================
    // Case 1: Single chunk — audio < 15s, no finalization needed
    // ============================================================

    @Test
    fun singleChunk_underBoundary_noFinalization() {
        // 10 seconds of audio (160000 samples) — well under 15s chunk
        val slice = manager.computeSlice(160000)

        assertNotNull(slice)
        assertEquals(0, slice.startSample)
        assertEquals(160000, slice.endSample)
        assertEquals(0L, slice.sliceOffsetMs)
        assertEquals("", manager.completedChunksText)
    }

    @Test
    fun singleChunk_processResult_setsHypothesis() {
        val segments = listOf(
            TranscriptionSegment("Hello world", 0, 5000)
        )
        manager.processTranscriptionResult(segments)

        assertEquals("", manager.confirmedText)
        assertEquals("Hello world", manager.hypothesisText)
    }

    @Test
    fun singleChunk_twoIdenticalResults_confirmsFirst() {
        // First pass: sets as unconfirmed
        val segments1 = listOf(
            TranscriptionSegment("Hello world", 0, 5000)
        )
        manager.processTranscriptionResult(segments1)
        assertEquals("Hello world", manager.hypothesisText)
        assertEquals("", manager.confirmedText)

        // Second pass: same text → confirmed
        val segments2 = listOf(
            TranscriptionSegment("Hello world", 0, 5000),
            TranscriptionSegment("How are you", 5000, 10000)
        )
        manager.processTranscriptionResult(segments2)
        assertEquals("Hello world", manager.confirmedText)
        assertEquals("How are you", manager.hypothesisText)
    }

    @Test
    fun singleChunk_confirmedSegmentEndMs_advances() {
        val segments1 = listOf(TranscriptionSegment("Hello", 0, 3000))
        manager.processTranscriptionResult(segments1)

        val segments2 = listOf(
            TranscriptionSegment("Hello", 0, 3000),
            TranscriptionSegment("World", 3000, 6000)
        )
        manager.processTranscriptionResult(segments2)

        assertEquals(3000L, manager.lastConfirmedSegmentEndMs)
    }

    // ============================================================
    // Case 2: Chunk boundary crossing — triggers finalization
    // ============================================================

    @Test
    fun chunkBoundary_16sAudio_triggersFinalization() {
        // Add unconfirmed hypothesis (no confirmation — lastConfirmedSegmentEndMs stays 0)
        val segments = listOf(TranscriptionSegment("chunk one text", 0, 14000))
        manager.processTranscriptionResult(segments)

        // 16s of audio (256000 samples) > 0 + 15s boundary → triggers finalization
        val slice = manager.computeSlice(256000)

        assertNotNull(slice)
        // After finalization, completedChunksText should have the hypothesis text
        assertTrue(manager.completedChunksText.isNotEmpty())
        // Chunk boundary at 15s
        assertEquals(15000L, manager.lastConfirmedSegmentEndMs)
    }

    @Test
    fun chunkBoundary_hypothesisIncludedInFinalization() {
        // Add unconfirmed segments (hypothesis)
        val segments = listOf(TranscriptionSegment("hypothesis text", 0, 14000))
        manager.processTranscriptionResult(segments)

        // Cross boundary — hypothesis should be finalized into completedChunksText
        manager.computeSlice(256000)

        assertTrue(manager.completedChunksText.contains("hypothesis text"))
    }

    @Test
    fun chunkBoundary_clearsPerChunkState() {
        // Add hypothesis only (no confirmation) so lastConfirmedSegmentEndMs stays 0
        val segments = listOf(TranscriptionSegment("text", 0, 5000))
        manager.processTranscriptionResult(segments)

        // Cross 15s boundary with 16s of audio
        manager.computeSlice(256000)

        assertTrue(manager.confirmedSegments.isEmpty())
        assertEquals(emptyList(), manager.prevUnconfirmedSegments)
        assertEquals("", manager.hypothesisText)
    }

    // ============================================================
    // Case 3: Multiple chunk boundaries — text accumulates
    // ============================================================

    @Test
    fun multipleChunks_textAccumulates() {
        // Chunk 0: 0-15s
        val seg1 = listOf(TranscriptionSegment("First chunk", 0, 14000))
        manager.processTranscriptionResult(seg1)
        manager.computeSlice(256000) // Cross 15s boundary

        // Chunk 1: 15s-30s
        val seg2 = listOf(TranscriptionSegment("Second chunk", 0, 14000))
        manager.processTranscriptionResult(seg2, sliceOffsetMs = 15000)
        manager.computeSlice(496000) // Cross 30s boundary (31s)

        assertTrue(manager.completedChunksText.contains("First chunk"))
        assertTrue(manager.completedChunksText.contains("Second chunk"))
    }

    @Test
    fun multipleChunks_confirmedTextIncludesAllChunks() {
        // Chunk 0
        val seg1 = listOf(TranscriptionSegment("alpha", 0, 14000))
        manager.processTranscriptionResult(seg1)
        manager.computeSlice(256000)

        // Chunk 1 — add new segments in new chunk
        val seg2 = listOf(TranscriptionSegment("beta", 0, 5000))
        manager.processTranscriptionResult(seg2, sliceOffsetMs = 15000)

        // confirmedText should include completedChunksText (alpha) + nothing new confirmed yet
        // hypothesisText should be "beta"
        assertEquals("alpha", manager.confirmedText)
        assertEquals("beta", manager.hypothesisText)
    }

    @Test
    fun threeChunks_allTextPreserved() {
        // Simulate 3 chunks of transcription
        for (i in 0 until 3) {
            val offsetMs = (i * 15000).toLong()
            val seg = listOf(TranscriptionSegment("chunk$i", 0, 14000))
            manager.processTranscriptionResult(seg, sliceOffsetMs = offsetMs)
            // Cross each 15s boundary
            val samplesAt = ((i + 1) * 15 + 1) * 16000
            manager.computeSlice(samplesAt)
        }

        assertTrue(manager.completedChunksText.contains("chunk0"))
        assertTrue(manager.completedChunksText.contains("chunk1"))
        assertTrue(manager.completedChunksText.contains("chunk2"))
    }

    // ============================================================
    // Case 4: Timestamp offset adjustment
    // ============================================================

    @Test
    fun timestampOffset_segmentsAdjustedCorrectly() {
        // Simulate chunk 1 (starts at 15s = 15000ms offset)
        val segments = listOf(
            TranscriptionSegment("hello", 0, 3000),
            TranscriptionSegment("world", 3000, 6000)
        )
        manager.processTranscriptionResult(segments, sliceOffsetMs = 15000)

        // Internal segments should have adjusted timestamps
        val unconfirmed = manager.prevUnconfirmedSegments
        assertEquals(2, unconfirmed.size)
        assertEquals(15000L, unconfirmed[0].startMs)
        assertEquals(18000L, unconfirmed[0].endMs)
        assertEquals(18000L, unconfirmed[1].startMs)
        assertEquals(21000L, unconfirmed[1].endMs)
    }

    @Test
    fun timestampOffset_zeroOffset_noAdjustment() {
        val segments = listOf(TranscriptionSegment("hello", 500, 3000))
        manager.processTranscriptionResult(segments, sliceOffsetMs = 0)

        assertEquals(500L, manager.prevUnconfirmedSegments[0].startMs)
        assertEquals(3000L, manager.prevUnconfirmedSegments[0].endMs)
    }

    @Test
    fun timestampOffset_confirmationUsesAdjustedTimestamps() {
        // First pass with offset
        val seg1 = listOf(TranscriptionSegment("hello", 0, 3000))
        manager.processTranscriptionResult(seg1, sliceOffsetMs = 15000)

        // Second pass confirms — lastConfirmedSegmentEndMs should be adjusted
        val seg2 = listOf(
            TranscriptionSegment("hello", 0, 3000),
            TranscriptionSegment("world", 3000, 6000)
        )
        manager.processTranscriptionResult(seg2, sliceOffsetMs = 15000)

        // 3000 + 15000 = 18000
        assertEquals(18000L, manager.lastConfirmedSegmentEndMs)
    }

    // ============================================================
    // Case 5: Adaptive delay scaling during silence
    // ============================================================

    @Test
    fun adaptiveDelay_noSilence_returnsBase() {
        manager.consecutiveSilentWindows = 0
        assertEquals(1.0f, manager.adaptiveDelay())
    }

    @Test
    fun adaptiveDelay_fewSilentWindows_returnsBase() {
        manager.consecutiveSilentWindows = 2
        assertEquals(1.0f, manager.adaptiveDelay())
    }

    @Test
    fun adaptiveDelay_moderateSilence_returns2x() {
        manager.consecutiveSilentWindows = 3
        assertEquals(2.0f, manager.adaptiveDelay())
    }

    @Test
    fun adaptiveDelay_5SilentWindows_returns2x() {
        manager.consecutiveSilentWindows = 5
        assertEquals(2.0f, manager.adaptiveDelay())
    }

    @Test
    fun adaptiveDelay_manySilentWindows_returns3x() {
        manager.consecutiveSilentWindows = 6
        assertEquals(3.0f, manager.adaptiveDelay())
    }

    @Test
    fun adaptiveDelay_extremeSilence_capped() {
        manager.consecutiveSilentWindows = 100
        // 1.0 * 3 = 3.0, capped at 3.0
        assertEquals(3.0f, manager.adaptiveDelay())
    }

    // ============================================================
    // Case 6: Segment confirmation logic (matching consecutive)
    // ============================================================

    @Test
    fun confirmation_noMatch_remainsHypothesis() {
        val seg1 = listOf(TranscriptionSegment("hello", 0, 3000))
        manager.processTranscriptionResult(seg1)

        val seg2 = listOf(TranscriptionSegment("goodbye", 0, 3000))
        manager.processTranscriptionResult(seg2)

        assertEquals("", manager.confirmedText)
        assertEquals("goodbye", manager.hypothesisText)
    }

    @Test
    fun confirmation_partialMatch_confirmsMatchingPrefix() {
        val seg1 = listOf(
            TranscriptionSegment("hello", 0, 3000),
            TranscriptionSegment("world", 3000, 6000)
        )
        manager.processTranscriptionResult(seg1)

        val seg2 = listOf(
            TranscriptionSegment("hello", 0, 3000),
            TranscriptionSegment("everyone", 3000, 6000),
            TranscriptionSegment("here", 6000, 9000)
        )
        manager.processTranscriptionResult(seg2)

        assertEquals("hello", manager.confirmedText)
        assertEquals("everyone here", manager.hypothesisText)
    }

    @Test
    fun confirmation_fullMatch_confirmsAll() {
        val seg1 = listOf(
            TranscriptionSegment("a", 0, 1000),
            TranscriptionSegment("b", 1000, 2000)
        )
        manager.processTranscriptionResult(seg1)

        val seg2 = listOf(
            TranscriptionSegment("a", 0, 1000),
            TranscriptionSegment("b", 1000, 2000)
        )
        manager.processTranscriptionResult(seg2)

        assertEquals("a b", manager.confirmedText)
        assertEquals("", manager.hypothesisText)
    }

    @Test
    fun confirmation_textNormalized_trailingSpacesIgnored() {
        val seg1 = listOf(TranscriptionSegment("  hello  ", 0, 3000))
        manager.processTranscriptionResult(seg1)

        val seg2 = listOf(
            TranscriptionSegment("hello", 0, 3000),
            TranscriptionSegment("world", 3000, 6000)
        )
        manager.processTranscriptionResult(seg2)

        assertEquals("hello", manager.confirmedText)
    }

    // ============================================================
    // Case 7: Reset clears all chunk state
    // ============================================================

    @Test
    fun reset_clearsEverything() {
        // Build up some state
        manager.processTranscriptionResult(
            listOf(TranscriptionSegment("text", 0, 5000))
        )
        manager.computeSlice(256000) // Cross boundary
        manager.consecutiveSilentWindows = 10

        manager.reset()

        assertEquals("", manager.completedChunksText)
        assertTrue(manager.confirmedSegments.isEmpty())
        assertEquals(emptyList(), manager.prevUnconfirmedSegments)
        assertEquals(0L, manager.lastConfirmedSegmentEndMs)
        assertEquals(0, manager.consecutiveSilentWindows)
        assertEquals("", manager.confirmedText)
        assertEquals("", manager.hypothesisText)
    }

    @Test
    fun reset_afterMultipleChunks_clearsAll() {
        for (i in 0 until 3) {
            manager.processTranscriptionResult(
                listOf(TranscriptionSegment("chunk$i", 0, 14000)),
                sliceOffsetMs = (i * 15000).toLong()
            )
            manager.computeSlice(((i + 1) * 15 + 1) * 16000)
        }

        manager.reset()

        assertEquals("", manager.completedChunksText)
        assertEquals(0L, manager.lastConfirmedSegmentEndMs)
        assertEquals("", manager.fullTranscriptionText())
    }

    // ============================================================
    // Case 8: Final flush (trailing audio after recording stop)
    // ============================================================

    @Test
    fun finalizeTrailing_addsToConfirmedText() {
        // Simulate one completed chunk
        manager.processTranscriptionResult(
            listOf(TranscriptionSegment("first chunk", 0, 14000))
        )
        manager.computeSlice(256000)

        // Final flush with trailing audio
        val trailing = listOf(TranscriptionSegment("trailing text", 0, 3000))
        manager.finalizeTrailing(trailing, sliceOffsetMs = 15000)

        assertTrue(manager.confirmedText.contains("first chunk"))
        assertTrue(manager.confirmedText.contains("trailing text"))
        assertEquals("", manager.hypothesisText)
    }

    @Test
    fun finalizeTrailing_adjustsTimestamps() {
        val trailing = listOf(TranscriptionSegment("tail", 0, 2000))
        manager.finalizeTrailing(trailing, sliceOffsetMs = 30000)

        val confirmed = manager.confirmedSegments
        assertEquals(1, confirmed.size)
        assertEquals(30000L, confirmed[0].startMs)
        assertEquals(32000L, confirmed[0].endMs)
    }

    @Test
    fun finalizeTrailing_emptySegments_noChange() {
        manager.finalizeTrailing(emptyList(), sliceOffsetMs = 15000)
        assertEquals("", manager.confirmedText)
    }

    // ============================================================
    // Case 9: fullTranscriptionText combines confirmed + hypothesis
    // ============================================================

    @Test
    fun fullText_confirmedOnly() {
        val seg1 = listOf(TranscriptionSegment("hello", 0, 3000))
        manager.processTranscriptionResult(seg1)
        manager.processTranscriptionResult(seg1) // confirm

        assertEquals("hello", manager.fullTranscriptionText())
    }

    @Test
    fun fullText_hypothesisOnly() {
        manager.processTranscriptionResult(
            listOf(TranscriptionSegment("hypothesis", 0, 3000))
        )
        assertEquals("hypothesis", manager.fullTranscriptionText())
    }

    @Test
    fun fullText_confirmedAndHypothesis() {
        val seg1 = listOf(TranscriptionSegment("confirmed", 0, 3000))
        manager.processTranscriptionResult(seg1)

        val seg2 = listOf(
            TranscriptionSegment("confirmed", 0, 3000),
            TranscriptionSegment("hypothesis", 3000, 6000)
        )
        manager.processTranscriptionResult(seg2)

        assertEquals("confirmed hypothesis", manager.fullTranscriptionText())
    }

    @Test
    fun fullText_withCompletedChunks() {
        // Build completed chunk
        manager.processTranscriptionResult(
            listOf(TranscriptionSegment("old chunk", 0, 14000))
        )
        manager.computeSlice(256000) // Cross boundary

        // New hypothesis in current chunk
        manager.processTranscriptionResult(
            listOf(TranscriptionSegment("new text", 0, 3000)),
            sliceOffsetMs = 15000
        )

        val full = manager.fullTranscriptionText()
        assertTrue(full.contains("old chunk"))
        assertTrue(full.contains("new text"))
    }

    // ============================================================
    // Case 10: computeSlice edge cases
    // ============================================================

    @Test
    fun computeSlice_zeroSamples_returnsNull() {
        assertNull(manager.computeSlice(0))
    }

    @Test
    fun computeSlice_exactlyAtBoundary_noFinalization() {
        // Exactly 15s = 240000 samples — not exceeding boundary
        val slice = manager.computeSlice(240000)

        assertNotNull(slice)
        assertEquals(0, slice.startSample)
        assertEquals(240000, slice.endSample)
        assertEquals("", manager.completedChunksText) // No finalization
    }

    @Test
    fun computeSlice_oneOverBoundary_triggersFinalization() {
        // 15s + 1 sample = 240001 samples
        val slice = manager.computeSlice(240001)

        assertNotNull(slice)
        assertEquals(15000L, manager.lastConfirmedSegmentEndMs) // Finalized
    }

    @Test
    fun computeSlice_sliceBoundedToChunkSeconds() {
        // 25s of audio (400000 samples) — slice should be at most 15s
        val slice = manager.computeSlice(400000)

        assertNotNull(slice)
        val sliceDurationSamples = slice.endSample - slice.startSample
        // Max 15s = 240000 samples
        assertTrue(sliceDurationSamples <= 240000)
    }

    @Test
    fun computeSlice_afterSecondChunk_offsetCorrect() {
        // Cross first boundary
        manager.computeSlice(256000)
        assertEquals(15000L, manager.lastConfirmedSegmentEndMs)

        // Get slice in second chunk (20s = 320000 samples)
        val slice = manager.computeSlice(320000)
        assertNotNull(slice)
        assertEquals(240000, slice.startSample) // 15s * 16000
        assertEquals(15000L, slice.sliceOffsetMs)
    }

    // ============================================================
    // Case 11: Helper methods
    // ============================================================

    @Test
    fun joinChunkTexts_filtersBlank() {
        assertEquals("a b", manager.joinChunkTexts("a", "", "b", "  "))
    }

    @Test
    fun joinChunkTexts_allBlank_returnsEmpty() {
        assertEquals("", manager.joinChunkTexts("", "  ", ""))
    }

    @Test
    fun joinChunkTexts_single_returnsUnchanged() {
        assertEquals("hello", manager.joinChunkTexts("hello"))
    }

    @Test
    fun normalizeText_collapsesWhitespace() {
        assertEquals("hello world", manager.normalizeText("  hello   world  "))
    }

    @Test
    fun normalizeText_emptyString() {
        assertEquals("", manager.normalizeText(""))
    }

    @Test
    fun renderSegmentsText_filtersBlankSegments() {
        val segments = listOf(
            TranscriptionSegment("hello", 0, 1000),
            TranscriptionSegment("  ", 1000, 2000),
            TranscriptionSegment("world", 2000, 3000)
        )
        assertEquals("hello world", manager.renderSegmentsText(segments))
    }

    @Test
    fun renderSegmentsText_emptyList() {
        assertEquals("", manager.renderSegmentsText(emptyList()))
    }

    // ============================================================
    // Case 12: Custom chunk size
    // ============================================================

    @Test
    fun customChunkSize_5seconds_boundsCorrectly() {
        val smallChunkManager = StreamingChunkManager(
            chunkSeconds = 5.0f,
            sampleRate = 16000,
            minNewAudioSeconds = 0.5f
        )

        // 6s of audio (96000 samples) > 5s boundary
        val slice = smallChunkManager.computeSlice(96000)

        assertNotNull(slice)
        assertEquals(5000L, smallChunkManager.lastConfirmedSegmentEndMs)
    }

    @Test
    fun customChunkSize_adaptiveDelayScales() {
        val customManager = StreamingChunkManager(
            chunkSeconds = 15.0f,
            sampleRate = 16000,
            minNewAudioSeconds = 0.5f
        )
        customManager.consecutiveSilentWindows = 3
        assertEquals(1.0f, customManager.adaptiveDelay()) // 0.5 * 2 = 1.0
    }

    // ============================================================
    // Case 13: Realtime multi-pass simulation
    // ============================================================

    @Test
    fun realtimeSimulation_graduallyGrowingBuffer() {
        // Simulate a real recording session: buffer grows, engine returns
        // gradually improving transcription. Key: engine results are slice-relative,
        // and computeSlice provides the offset.
        val sampleRate = 16000

        // t=2s: first transcription (slice 0-2s, offset=0)
        var slice = manager.computeSlice(2 * sampleRate)
        assertNotNull(slice)
        manager.processTranscriptionResult(
            listOf(TranscriptionSegment("The quick", 0, 2000)),
            sliceOffsetMs = slice!!.sliceOffsetMs
        )
        assertEquals("The quick", manager.hypothesisText)
        assertEquals("", manager.confirmedText)

        // t=4s: refined transcription (slice still 0-4s, offset=0, no confirmation yet)
        slice = manager.computeSlice(4 * sampleRate)
        assertNotNull(slice)
        manager.processTranscriptionResult(
            listOf(
                TranscriptionSegment("The quick", 0, 2000),
                TranscriptionSegment("brown fox", 2000, 4000)
            ),
            sliceOffsetMs = slice!!.sliceOffsetMs
        )
        assertEquals("The quick", manager.confirmedText)
        assertEquals("brown fox", manager.hypothesisText)

        // t=8s: slice now starts at 2s (lastConfirmedSegmentEndMs=2000),
        // so engine returns segments relative to 2s
        slice = manager.computeSlice(8 * sampleRate)
        assertNotNull(slice)
        assertEquals(2000L, slice!!.sliceOffsetMs)
        manager.processTranscriptionResult(
            listOf(
                TranscriptionSegment("brown fox", 0, 2000),
                TranscriptionSegment("jumps over", 2000, 6000)
            ),
            sliceOffsetMs = slice!!.sliceOffsetMs
        )
        // "brown fox" matched prev → confirmed
        assertEquals("The quick brown fox", manager.confirmedText)
        assertEquals("jumps over", manager.hypothesisText)

        // t=16s: lastConfirmedSegmentEndMs=4000, chunk boundary = 4s+15s = 19s
        // 16s < 19s, so no boundary crossing yet
        slice = manager.computeSlice(16 * sampleRate)
        assertNotNull(slice)
        // Engine returns relative to 4s offset
        manager.processTranscriptionResult(
            listOf(
                TranscriptionSegment("jumps over", 0, 4000),
                TranscriptionSegment("the lazy dog", 4000, 8000)
            ),
            sliceOffsetMs = slice!!.sliceOffsetMs
        )
        // "jumps over" matched prev → confirmed
        assertEquals("The quick brown fox jumps over", manager.confirmedText)
        assertEquals("the lazy dog", manager.hypothesisText)

        // t=20s: now crosses boundary (lastConfirmedSegmentEndMs=8000, boundary=8+15=23s)
        // Still within chunk, but buffer has grown
        val full = manager.fullTranscriptionText()
        assertTrue(full.contains("The quick"))
        assertTrue(full.contains("the lazy dog"))
    }

    @Test
    fun realtimeSimulation_silenceGapsWithAdaptiveDelay() {
        // Simulate: voice → silence → voice pattern
        manager.consecutiveSilentWindows = 0
        assertEquals(1.0f, manager.adaptiveDelay()) // active speech

        // Enter silence
        manager.consecutiveSilentWindows = 1
        assertEquals(1.0f, manager.adaptiveDelay()) // still base
        manager.consecutiveSilentWindows = 3
        assertEquals(2.0f, manager.adaptiveDelay()) // moderate silence
        manager.consecutiveSilentWindows = 6
        assertEquals(3.0f, manager.adaptiveDelay()) // deep silence

        // Voice resumes
        manager.consecutiveSilentWindows = 0
        assertEquals(1.0f, manager.adaptiveDelay()) // back to base
    }

    // ============================================================
    // Case 14: Edge cases — empty/blank segments
    // ============================================================

    @Test
    fun emptySegments_noChange() {
        manager.processTranscriptionResult(emptyList())
        assertEquals("", manager.confirmedText)
        assertEquals("", manager.hypothesisText)
    }

    @Test
    fun blankTextSegments_filteredOut() {
        manager.processTranscriptionResult(
            listOf(TranscriptionSegment("  ", 0, 3000))
        )
        assertEquals("", manager.hypothesisText)
    }

    @Test
    fun finalizeChunk_withOnlyBlankSegments_noTextAccumulated() {
        manager.processTranscriptionResult(
            listOf(TranscriptionSegment("  ", 0, 3000))
        )
        manager.computeSlice(256000) // Cross boundary
        assertEquals("", manager.completedChunksText)
    }

    // ============================================================
    // Case 15: Chunk boundary with confirmed + unconfirmed segments
    // ============================================================

    // ============================================================
    // Case 16: Inference window bounds — slice never exceeds chunk size
    // ============================================================

    @Test
    fun sliceBounds_neverExceedsChunkSamples_3minuteRecording() {
        val sampleRate = 16000
        // Simulate a 3-minute recording, checking slice bounds each second
        for (t in 1..180) {
            val currentSamples = t * sampleRate
            val slice = manager.computeSlice(currentSamples) ?: continue

            val sliceDuration = slice.endSample - slice.startSample
            assertTrue(
                sliceDuration <= manager.chunkSamples,
                "At t=${t}s, slice duration $sliceDuration exceeds chunk ${manager.chunkSamples}"
            )

            // Simulate engine returning a result every iteration
            if (t % 2 == 0) {
                manager.processTranscriptionResult(
                    listOf(TranscriptionSegment("word at $t", 0, 1000)),
                    sliceOffsetMs = slice.sliceOffsetMs
                )
            }
        }

        // 180s / 15s = 12 chunks expected, verify some text accumulated
        assertTrue(manager.completedChunksText.isNotEmpty(),
            "Expected completed chunks after 3 minutes")
    }

    @Test
    fun sliceBounds_afterStartStopCycles_stillBounded() {
        val sampleRate = 16000
        // Simulate 5 start/stop cycles with increasing audio length
        for (cycle in 1..5) {
            manager.reset()
            val durationSeconds = cycle * 20 // 20s, 40s, 60s, 80s, 100s

            for (t in 1..durationSeconds) {
                val currentSamples = t * sampleRate
                val slice = manager.computeSlice(currentSamples) ?: continue

                val sliceDuration = slice.endSample - slice.startSample
                assertTrue(
                    sliceDuration <= manager.chunkSamples,
                    "Cycle $cycle, t=${t}s: slice $sliceDuration > chunk ${manager.chunkSamples}"
                )

                if (t % 3 == 0) {
                    manager.processTranscriptionResult(
                        listOf(TranscriptionSegment("text $t", 0, 1000)),
                        sliceOffsetMs = slice.sliceOffsetMs
                    )
                }
            }
        }
    }

    @Test
    fun sliceBounds_noEagerConfirmation_stillBounded() {
        val sampleRate = 16000
        // Simulate worst case: model keeps changing output, no eager confirmation
        // so lastConfirmedSegmentEndMs never advances from segment matching
        for (t in 1..60) {
            val currentSamples = t * sampleRate
            val slice = manager.computeSlice(currentSamples) ?: continue

            val sliceDuration = slice.endSample - slice.startSample
            assertTrue(
                sliceDuration <= manager.chunkSamples,
                "At t=${t}s, slice $sliceDuration > chunk ${manager.chunkSamples}"
            )

            // Always different text → no confirmation → lastConfirmedSegmentEndMs stays at chunk boundary
            manager.processTranscriptionResult(
                listOf(TranscriptionSegment("unique text $t", 0, (t * 500).toLong())),
                sliceOffsetMs = slice.sliceOffsetMs
            )
        }

        // Verify chunks were finalized despite no eager confirmation
        // 60s / 15s = 4 chunk boundaries crossed
        assertTrue(manager.completedChunksText.isNotEmpty())
    }

    @Test
    fun sliceBounds_inferenceWindowShrinks_withEagerConfirmation() {
        val sampleRate = 16000
        // Simulate eager confirmation working: each pass confirms, advancing the slice start
        val seg1 = listOf(TranscriptionSegment("hello", 0, 3000))
        manager.processTranscriptionResult(seg1)

        // Confirm "hello" → lastConfirmedSegmentEndMs = 3000
        val seg2 = listOf(
            TranscriptionSegment("hello", 0, 3000),
            TranscriptionSegment("world", 3000, 6000)
        )
        manager.processTranscriptionResult(seg2)
        assertEquals(3000L, manager.lastConfirmedSegmentEndMs)

        // Now at t=10s, slice should start at 3s not 0s
        val slice = manager.computeSlice(10 * sampleRate)
        assertNotNull(slice)
        assertEquals(3000 * sampleRate / 1000, slice!!.startSample) // 48000
        val sliceDuration = slice.endSample - slice.startSample
        // Slice should be 10s - 3s = 7s = 112000 samples (less than chunk)
        assertTrue(sliceDuration < manager.chunkSamples,
            "Eager confirmation should shrink the inference window, got $sliceDuration")
    }

    // ============================================================
    // Case 17: Continuous streaming — slice growth + delay interaction
    // ============================================================

    @Test
    fun continuousStreaming_sliceGrowsSawtoothPattern() {
        // Simulate 60s of recording. Slice should grow within each 15s chunk,
        // then drop back to 0 at each chunk boundary (sawtooth pattern).
        val sampleRate = 16000
        var maxSliceInChunk = 0
        var chunkTransitions = 0
        var prevSliceStart = 0

        for (t in 1..60) {
            val currentSamples = t * sampleRate
            val slice = manager.computeSlice(currentSamples) ?: continue

            val sliceDuration = slice.endSample - slice.startSample
            assertTrue(
                sliceDuration <= manager.chunkSamples,
                "At t=${t}s, slice $sliceDuration > chunk ${manager.chunkSamples}"
            )

            // Detect chunk transition: slice start jumps forward
            if (slice.startSample > prevSliceStart && prevSliceStart > 0) {
                chunkTransitions++
            }
            prevSliceStart = slice.startSample
            maxSliceInChunk = maxOf(maxSliceInChunk, sliceDuration)

            // Feed result so the system advances
            manager.processTranscriptionResult(
                listOf(TranscriptionSegment("text", 0, 1000)),
                sliceOffsetMs = slice.sliceOffsetMs
            )
        }

        // 60s / 15s = 4 chunk boundaries (at 15s, 30s, 45s, 60s?)
        assertTrue(chunkTransitions >= 3, "Expected >=3 chunk transitions, got $chunkTransitions")
        // Max slice should be close to chunk size (15s = 240000 samples)
        assertTrue(maxSliceInChunk <= manager.chunkSamples)
    }

    @Test
    fun continuousStreaming_silenceGap_sliceStillBounded() {
        val sampleRate = 16000
        // 5s speech → eager confirmation advances to 3s
        val seg1 = listOf(TranscriptionSegment("speech part", 0, 3000))
        manager.processTranscriptionResult(seg1)
        val seg2 = listOf(
            TranscriptionSegment("speech part", 0, 3000),
            TranscriptionSegment("more speech", 3000, 5000)
        )
        manager.processTranscriptionResult(seg2)
        assertEquals(3000L, manager.lastConfirmedSegmentEndMs)

        // Now simulate silence from 5s to 25s — no new processTranscriptionResult
        // Chunk boundary = 3s + 15s = 18s
        for (t in 5..25) {
            manager.consecutiveSilentWindows = (t - 5).coerceAtMost(10)
            val currentSamples = t * sampleRate
            val slice = manager.computeSlice(currentSamples) ?: continue

            val sliceDuration = slice.endSample - slice.startSample
            assertTrue(
                sliceDuration <= manager.chunkSamples,
                "Silence at t=${t}s: slice $sliceDuration > chunk ${manager.chunkSamples}"
            )

            // At t=18+, chunk boundary should have fired
            if (t > 18) {
                assertTrue(
                    manager.lastConfirmedSegmentEndMs >= 18000L,
                    "At t=${t}s, expected chunk finalization but lastConfirmed=${manager.lastConfirmedSegmentEndMs}"
                )
            }
        }
    }

    @Test
    fun continuousStreaming_adaptiveDelay_scalesCorrectly() {
        // Verify adaptive delay values at each silence threshold
        val customManager = StreamingChunkManager(
            chunkSeconds = 15.0f,
            sampleRate = 16000,
            minNewAudioSeconds = 1.0f
        )

        // Active speech
        customManager.consecutiveSilentWindows = 0
        assertEquals(1.0f, customManager.adaptiveDelay())

        // Mild silence
        customManager.consecutiveSilentWindows = 1
        assertEquals(1.0f, customManager.adaptiveDelay())
        customManager.consecutiveSilentWindows = 2
        assertEquals(1.0f, customManager.adaptiveDelay())

        // Moderate silence → 2x
        customManager.consecutiveSilentWindows = 3
        assertEquals(2.0f, customManager.adaptiveDelay())
        customManager.consecutiveSilentWindows = 5
        assertEquals(2.0f, customManager.adaptiveDelay())

        // Deep silence → 3x (capped)
        customManager.consecutiveSilentWindows = 6
        assertEquals(3.0f, customManager.adaptiveDelay())
        customManager.consecutiveSilentWindows = 100
        assertEquals(3.0f, customManager.adaptiveDelay())

        // Voice resumes → back to 1x
        customManager.consecutiveSilentWindows = 0
        assertEquals(1.0f, customManager.adaptiveDelay())
    }

    // ============================================================
    // Case 18: Start/stop/restart — state isolation between sessions
    // ============================================================

    @Test
    fun startStopRestart_resetClearsAllState() {
        // Session 1: build up state
        manager.processTranscriptionResult(
            listOf(TranscriptionSegment("session one", 0, 5000))
        )
        manager.processTranscriptionResult(
            listOf(
                TranscriptionSegment("session one", 0, 5000),
                TranscriptionSegment("continued", 5000, 10000)
            )
        )
        // Chunk boundary = 5s + 15s = 20s. Need > 20s to trigger finalization.
        manager.computeSlice(21 * 16000) // Cross chunk boundary
        manager.consecutiveSilentWindows = 8

        // Verify state has accumulated
        assertTrue(manager.completedChunksText.isNotEmpty())
        assertTrue(manager.lastConfirmedSegmentEndMs > 0)
        assertTrue(manager.consecutiveSilentWindows > 0)

        // Simulate stop + restart
        manager.reset()

        // Verify all state is clean
        assertEquals("", manager.completedChunksText)
        assertEquals("", manager.confirmedText)
        assertEquals("", manager.hypothesisText)
        assertEquals(0L, manager.lastConfirmedSegmentEndMs)
        assertEquals(0, manager.consecutiveSilentWindows)
        assertTrue(manager.confirmedSegments.isEmpty())
        assertEquals(emptyList(), manager.prevUnconfirmedSegments)
        assertEquals("", manager.fullTranscriptionText())

        // Session 2: fresh start — first slice should start at 0
        val slice = manager.computeSlice(5 * 16000)
        assertNotNull(slice)
        assertEquals(0, slice!!.startSample)
        assertEquals(0L, slice.sliceOffsetMs)
    }

    @Test
    fun startStopRestart_fiveRapidCycles_noAccumulation() {
        val sampleRate = 16000
        for (cycle in 1..5) {
            manager.reset()

            // Each cycle: 10s of audio
            for (t in 1..10) {
                val slice = manager.computeSlice(t * sampleRate) ?: continue
                manager.processTranscriptionResult(
                    listOf(TranscriptionSegment("cycle $cycle word $t", 0, 1000)),
                    sliceOffsetMs = slice.sliceOffsetMs
                )
            }

            // After 10s, verify no cross-cycle state
            assertTrue(
                !manager.completedChunksText.contains("cycle ${cycle - 1}"),
                "Cycle $cycle: found previous cycle text in completedChunksText"
            )
        }
    }

    @Test
    fun startStopRestart_longSession_thenShort_noPenalty() {
        val sampleRate = 16000

        // Session 1: long (90s)
        for (t in 1..90) {
            val slice = manager.computeSlice(t * sampleRate) ?: continue
            manager.processTranscriptionResult(
                listOf(TranscriptionSegment("long session", 0, 1000)),
                sliceOffsetMs = slice.sliceOffsetMs
            )
        }
        val longConfirmedEnd = manager.lastConfirmedSegmentEndMs
        assertTrue(longConfirmedEnd > 60000, "Expected significant progress in 90s session")

        // Reset (stop + restart)
        manager.reset()

        // Session 2: short (3s)
        val slice = manager.computeSlice(3 * sampleRate)
        assertNotNull(slice)
        assertEquals(0, slice!!.startSample, "Short session should start at sample 0")
        assertEquals(0L, slice.sliceOffsetMs, "Short session should have 0 offset")

        // Slice should be exactly 3s, not contaminated by old session
        val sliceDuration = slice.endSample - slice.startSample
        assertEquals(3 * sampleRate, sliceDuration)
    }

    // ============================================================
    // Case 19: Chunk finalization timing — delay doesn't prevent finalization
    // ============================================================

    @Test
    fun chunkFinalization_highDelay_stillTriggersAtBoundary() {
        // Even with high consecutive silence, chunk finalization must happen
        manager.consecutiveSilentWindows = 100 // max delay = 3s
        assertEquals(3.0f, manager.adaptiveDelay())

        // 16s of audio crosses the 15s boundary
        val slice = manager.computeSlice(16 * 16000)
        assertNotNull(slice)

        // Finalization should have occurred
        assertEquals(15000L, manager.lastConfirmedSegmentEndMs)
    }

    @Test
    fun chunkFinalization_preservesTextBeforeBoundary() {
        // Add hypothesis, then cross boundary — text should be preserved
        manager.processTranscriptionResult(
            listOf(TranscriptionSegment("before boundary", 0, 14000))
        )
        manager.consecutiveSilentWindows = 50 // deep silence

        manager.computeSlice(16 * 16000) // Cross boundary

        assertTrue(
            manager.completedChunksText.contains("before boundary"),
            "Text before boundary should be preserved in completedChunksText"
        )
    }

    // ============================================================
    // Case 15: Chunk boundary with confirmed + unconfirmed segments
    // ============================================================

    @Test
    fun chunkBoundary_bothConfirmedAndUnconfirmed_allIncluded() {
        // Pass 1: hypothesis
        manager.processTranscriptionResult(
            listOf(TranscriptionSegment("alpha", 0, 5000))
        )
        // Pass 2: confirm + new hypothesis
        manager.processTranscriptionResult(
            listOf(
                TranscriptionSegment("alpha", 0, 5000),
                TranscriptionSegment("beta", 5000, 10000)
            )
        )

        // "alpha" confirmed (lastConfirmedSegmentEndMs=5000), "beta" unconfirmed
        assertEquals("alpha", manager.confirmedText)
        assertEquals("beta", manager.hypothesisText)

        // Chunk boundary = 5s + 15s = 20s. Need buffer > 20s to trigger.
        // 21s = 336000 samples
        manager.computeSlice(336000)
        assertTrue(manager.completedChunksText.contains("alpha"))
        assertTrue(manager.completedChunksText.contains("beta"))
    }

    @Test
    fun normalizeText_cjkSpacingCollapsed() {
        val input = "そう で、すねこう いう 感じ で 動 いてま。 お願いし ます。"
        val normalized = manager.normalizeText(input)
        assertEquals("そうで、すねこういう感じで動いてま。お願いします。", normalized)
    }

    @Test
    fun normalizeText_englishSpacingPreserved() {
        val input = "Hello   world   from  test"
        val normalized = manager.normalizeText(input)
        assertEquals("Hello world from test", normalized)
    }
}
