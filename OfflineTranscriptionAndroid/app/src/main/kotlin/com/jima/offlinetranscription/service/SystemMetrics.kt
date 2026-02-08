package com.voiceping.offlinetranscription.service

import android.os.Debug
import java.io.File

/**
 * Lightweight process-level CPU and memory sampling.
 * - CPU%: delta of /proc/self/stat utime+stime between samples
 * - Memory: JVM heap + native heap (whisper.cpp allocations)
 */
class SystemMetrics {

    private var lastCpuTicks: Long = -1
    private var lastUptimeMs: Long = -1

    /** Process CPU usage as 0-100+ (can exceed 100 on multi-core). */
    fun getCpuPercent(): Float {
        try {
            val stat = File("/proc/self/stat").readText()
            val fields = stat.split(" ")
            // Fields 13 and 14 (0-indexed) = utime and stime in clock ticks
            if (fields.size < 15) return 0f
            val utime = fields[13].toLongOrNull() ?: 0L
            val stime = fields[14].toLongOrNull() ?: 0L
            val totalTicks = utime + stime
            val nowMs = System.currentTimeMillis()

            if (lastCpuTicks < 0) {
                lastCpuTicks = totalTicks
                lastUptimeMs = nowMs
                return 0f
            }

            val deltaTicks = totalTicks - lastCpuTicks
            val deltaMs = (nowMs - lastUptimeMs).coerceAtLeast(1)
            lastCpuTicks = totalTicks
            lastUptimeMs = nowMs

            // Clock ticks per second (typically 100 on Linux/Android)
            val ticksPerSec = 100L
            val cpuSeconds = deltaTicks.toFloat() / ticksPerSec
            val wallSeconds = deltaMs.toFloat() / 1000f
            return (cpuSeconds / wallSeconds * 100f).coerceIn(0f, 800f)
        } catch (_: Throwable) {
            return 0f
        }
    }

    /** App memory usage in MB (JVM heap + native heap). */
    fun getMemoryMB(): Float {
        val runtime = Runtime.getRuntime()
        val jvmUsed = runtime.totalMemory() - runtime.freeMemory()
        val nativeUsed = Debug.getNativeHeapAllocatedSize()
        return (jvmUsed + nativeUsed).toFloat() / (1024f * 1024f)
    }
}
