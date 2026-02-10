package com.voiceping.offlinetranscription.service

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * ASR engine backed by whisper.cpp via JNI.
 * Expects a single GGML model file (e.g. ggml-base.bin).
 *
 * All access to contextPtr is guarded by [lock] so that release()
 * cannot free the native context while transcribe() is in-flight.
 */
class WhisperCppEngine : AsrEngine {
    companion object {
        private const val TAG = "WhisperCppEngine"
    }

    private var contextPtr: Long = 0
    @Volatile
    private var loaded: Boolean = false
    private val lock = ReentrantLock()

    // Keep this lock-free so UI checks don't block behind long native inference calls.
    override val isLoaded: Boolean get() = loaded

    override suspend fun loadModel(modelPath: String): Boolean {
        return withContext(Dispatchers.IO) {
            lock.withLock {
                try {
                    if (contextPtr != 0L) {
                        WhisperLib.freeContext(contextPtr)
                        contextPtr = 0
                        loaded = false
                    }
                    val ptr = WhisperLib.initContext(modelPath)
                    contextPtr = ptr
                    loaded = ptr != 0L
                    ptr != 0L
                } catch (e: Throwable) {
                    Log.e(TAG, "Failed to load whisper.cpp model from $modelPath", e)
                    contextPtr = 0L
                    loaded = false
                    false
                }
            }
        }
    }

    override suspend fun transcribe(
        audioSamples: FloatArray,
        numThreads: Int,
        language: String
    ): List<TranscriptionSegment> {
        return withContext(Dispatchers.IO) {
            lock.withLock {
                if (contextPtr == 0L) return@withContext emptyList()

                try {
                    val result = WhisperLib.transcribe(contextPtr, audioSamples, numThreads, false, language)
                    if (result != 0) return@withContext emptyList()

                    val segmentCount = WhisperLib.getSegmentCount(contextPtr)

                    (0 until segmentCount).map { i ->
                        TranscriptionSegment(
                            text = WhisperLib.getSegmentText(contextPtr, i),
                            startMs = WhisperLib.getSegmentStartTime(contextPtr, i) * 10,
                            endMs = WhisperLib.getSegmentEndTime(contextPtr, i) * 10
                        )
                    }
                } catch (e: Throwable) {
                    Log.e(TAG, "whisper.cpp transcribe failed", e)
                    emptyList()
                }
            }
        }
    }

    override fun release() {
        loaded = false
        lock.withLock {
            if (contextPtr != 0L) {
                try {
                    WhisperLib.freeContext(contextPtr)
                } catch (e: Throwable) {
                    Log.w(TAG, "Failed to free whisper.cpp context", e)
                }
                contextPtr = 0
                loaded = false
            }
        }
    }
}
