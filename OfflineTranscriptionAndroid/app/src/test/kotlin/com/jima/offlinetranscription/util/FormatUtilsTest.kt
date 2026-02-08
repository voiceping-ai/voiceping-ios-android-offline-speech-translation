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

    // --- formatFileSize ---

    @Test
    fun formatFileSize_zeroBytes_returns0B() {
        assertEquals("0 B", FormatUtils.formatFileSize(0))
    }

    @Test
    fun formatFileSize_1023Bytes_returns1023B() {
        assertEquals("1023 B", FormatUtils.formatFileSize(1023))
    }

    @Test
    fun formatFileSize_1024Bytes_returns1KB() {
        assertEquals("1 KB", FormatUtils.formatFileSize(1024))
    }

    @Test
    fun formatFileSize_1048576Bytes_returns1MB() {
        assertEquals("1 MB", FormatUtils.formatFileSize(1_048_576))
    }

    @Test
    fun formatFileSize_1073741824Bytes_returns1Point0GB() {
        assertEquals("1.0 GB", FormatUtils.formatFileSize(1_073_741_824))
    }

    @Test
    fun formatFileSize_halfGB_fallsToMB() {
        // 536870912 < 1073741824 (1 GB threshold), so falls to MB branch
        assertEquals("512 MB", FormatUtils.formatFileSize(536_870_912))
    }

    @Test
    fun formatFileSize_500KB_returns500KB() {
        assertEquals("500 KB", FormatUtils.formatFileSize(512_000))
    }

    @Test
    fun formatFileSize_1500MB_returns1Point4GB() {
        assertEquals("1.4 GB", FormatUtils.formatFileSize(1_500_000_000))
    }
}
