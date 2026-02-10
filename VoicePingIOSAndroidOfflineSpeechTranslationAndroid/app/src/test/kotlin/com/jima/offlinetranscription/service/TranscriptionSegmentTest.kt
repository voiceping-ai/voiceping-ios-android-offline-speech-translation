package com.voiceping.offlinetranscription.service

import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals

class TranscriptionSegmentTest {

    @Test
    fun creation_withValidValues_succeeds() {
        val segment = TranscriptionSegment(
            text = "Hello world",
            startMs = 0,
            endMs = 1000
        )
        assertEquals("Hello world", segment.text)
        assertEquals(0L, segment.startMs)
        assertEquals(1000L, segment.endMs)
    }

    @Test
    fun creation_withEmptyText_succeeds() {
        val segment = TranscriptionSegment(
            text = "",
            startMs = 0,
            endMs = 0
        )
        assertEquals("", segment.text)
    }

    @Test
    fun creation_withLargeTimestamps_succeeds() {
        val segment = TranscriptionSegment(
            text = "Late in the audio",
            startMs = 3_600_000,
            endMs = 3_601_000
        )
        assertEquals(3_600_000L, segment.startMs)
        assertEquals(3_601_000L, segment.endMs)
    }

    @Test
    fun equality_sameValues_areEqual() {
        val a = TranscriptionSegment("Hello", 100, 200)
        val b = TranscriptionSegment("Hello", 100, 200)
        assertEquals(a, b)
    }

    @Test
    fun equality_differentText_areNotEqual() {
        val a = TranscriptionSegment("Hello", 100, 200)
        val b = TranscriptionSegment("World", 100, 200)
        assertNotEquals(a, b)
    }

    @Test
    fun equality_differentStartMs_areNotEqual() {
        val a = TranscriptionSegment("Hello", 100, 200)
        val b = TranscriptionSegment("Hello", 150, 200)
        assertNotEquals(a, b)
    }

    @Test
    fun equality_differentEndMs_areNotEqual() {
        val a = TranscriptionSegment("Hello", 100, 200)
        val b = TranscriptionSegment("Hello", 100, 250)
        assertNotEquals(a, b)
    }

    @Test
    fun hashCode_equalObjects_haveSameHashCode() {
        val a = TranscriptionSegment("Hello", 100, 200)
        val b = TranscriptionSegment("Hello", 100, 200)
        assertEquals(a.hashCode(), b.hashCode())
    }

    @Test
    fun copy_createsModifiedCopy() {
        val original = TranscriptionSegment("Hello", 100, 200)
        val copied = original.copy(text = "World")
        assertEquals("World", copied.text)
        assertEquals(100L, copied.startMs)
        assertEquals(200L, copied.endMs)
    }

    @Test
    fun toString_containsAllFields() {
        val segment = TranscriptionSegment("Hello", 100, 200)
        val str = segment.toString()
        assertTrue(str.contains("Hello"))
        assertTrue(str.contains("100"))
        assertTrue(str.contains("200"))
    }

    @Test
    fun destructuring_worksCorrectly() {
        val segment = TranscriptionSegment("Hello", 100, 200)
        val (text, startMs, endMs) = segment
        assertEquals("Hello", text)
        assertEquals(100L, startMs)
        assertEquals(200L, endMs)
    }

    private fun assertTrue(condition: Boolean) {
        kotlin.test.assertTrue(condition)
    }
}
