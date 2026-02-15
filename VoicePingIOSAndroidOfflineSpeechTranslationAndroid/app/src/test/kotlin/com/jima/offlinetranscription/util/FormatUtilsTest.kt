package com.voiceping.offlinetranscription.util

import org.junit.Test
import kotlin.test.assertEquals

class FormatUtilsTest {

    // --- formatDuration ---

    @Test
    fun formatDuration_zeroSeconds_returns0Colon00() {
        assertEquals("0:00", FormatUtils.formatDuration(0.0))
    }

    @Test
    fun formatDuration_oneSecond_returns0Colon01() {
        assertEquals("0:01", FormatUtils.formatDuration(1.0))
    }

    @Test
    fun formatDuration_59Seconds_returns0Colon59() {
        assertEquals("0:59", FormatUtils.formatDuration(59.0))
    }

    @Test
    fun formatDuration_60Seconds_returns1Colon00() {
        assertEquals("1:00", FormatUtils.formatDuration(60.0))
    }

    @Test
    fun formatDuration_61Seconds_returns1Colon01() {
        assertEquals("1:01", FormatUtils.formatDuration(61.0))
    }

    @Test
    fun formatDuration_3661Seconds_returns1Colon01Colon01() {
        assertEquals("1:01:01", FormatUtils.formatDuration(3661.0))
    }

    @Test
    fun formatDuration_3600Seconds_returns1Colon00Colon00() {
        assertEquals("1:00:00", FormatUtils.formatDuration(3600.0))
    }

    @Test
    fun formatDuration_negativeValue_clampsToZero() {
        assertEquals("0:00", FormatUtils.formatDuration(-1.0))
    }

    @Test
    fun formatDuration_fractionalSeconds_truncatesDecimal() {
        assertEquals("0:01", FormatUtils.formatDuration(1.9))
    }

    @Test
    fun formatDuration_largeNegativeValue_clampsToZero() {
        assertEquals("0:00", FormatUtils.formatDuration(-3661.0))
    }

}
