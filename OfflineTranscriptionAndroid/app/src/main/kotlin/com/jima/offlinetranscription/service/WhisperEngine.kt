package com.voiceping.offlinetranscription.service

import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.util.Log
import com.voiceping.offlinetranscription.data.AppPreferences
import com.voiceping.offlinetranscription.model.AppError
import com.voiceping.offlinetranscription.model.EngineType
import com.voiceping.offlinetranscription.model.ModelInfo
import com.voiceping.offlinetranscription.model.ModelState
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.util.concurrent.atomic.AtomicLong

data class TranscriptionSegment(
    val text: String,
    val startMs: Long,
    val endMs: Long,
    val detectedLanguage: String? = null
)

/** Strict session state machine for the transcription pipeline. */
enum class SessionState {
    Idle,       // No recording, ready to start
    Recording,  // Mic active, transcription loop running
    Stopping,   // Stop requested, waiting for jobs to complete
    Error       // Error occurred, needs clearTranscription() to reset
}

/** E2E test result for evidence collection. */
data class E2ETestResult(
    val modelId: String,
    val engine: String,
    val transcript: String,
    val translatedText: String,
    val ttsAudioPath: String?,
    val ttsStartCount: Int,
    val ttsMicGuardViolations: Int,
    val micStoppedForTts: Boolean,
    val pass: Boolean,
    val durationMs: Double,
    val timestamp: String,
    val error: String? = null
)

class WhisperEngine(
    private val context: Context,
    private val preferences: AppPreferences
) {
    private val modelsDir = File(context.filesDir, "models")
    private val downloader = ModelDownloader(modelsDir)
    val audioRecorder = AudioRecorder(context)

    // Model state
    private val _modelState = MutableStateFlow(ModelState.Unloaded)
    val modelState: StateFlow<ModelState> = _modelState.asStateFlow()

    private val _downloadProgress = MutableStateFlow(0f)
    val downloadProgress: StateFlow<Float> = _downloadProgress.asStateFlow()

    private val _selectedModel = MutableStateFlow(ModelInfo.defaultModel)
    val selectedModel: StateFlow<ModelInfo> = _selectedModel.asStateFlow()

    // Session state machine
    private val _sessionState = MutableStateFlow(SessionState.Idle)
    val sessionState: StateFlow<SessionState> = _sessionState.asStateFlow()

    // Derived isRecording for backward compat
    private val _isRecording = MutableStateFlow(false)
    val isRecording: StateFlow<Boolean> = _isRecording.asStateFlow()

    // Transcription output
    private val _confirmedText = MutableStateFlow("")
    val confirmedText: StateFlow<String> = _confirmedText.asStateFlow()

    private val _hypothesisText = MutableStateFlow("")
    val hypothesisText: StateFlow<String> = _hypothesisText.asStateFlow()

    private val _bufferEnergy = MutableStateFlow<List<Float>>(emptyList())
    val bufferEnergy: StateFlow<List<Float>> = _bufferEnergy.asStateFlow()

    private val _bufferSeconds = MutableStateFlow(0.0)
    val bufferSeconds: StateFlow<Double> = _bufferSeconds.asStateFlow()

    private val _tokensPerSecond = MutableStateFlow(0.0)
    val tokensPerSecond: StateFlow<Double> = _tokensPerSecond.asStateFlow()

    private val _lastError = MutableStateFlow<AppError?>(null)
    val lastError: StateFlow<AppError?> = _lastError.asStateFlow()

    private val _useVAD = MutableStateFlow(true)
    val useVAD: StateFlow<Boolean> = _useVAD.asStateFlow()

    private val _enableTimestamps = MutableStateFlow(true)
    val enableTimestamps: StateFlow<Boolean> = _enableTimestamps.asStateFlow()

    private val _translationEnabled = MutableStateFlow(true)
    val translationEnabled: StateFlow<Boolean> = _translationEnabled.asStateFlow()

    private val _speakTranslatedAudio = MutableStateFlow(true)
    val speakTranslatedAudio: StateFlow<Boolean> = _speakTranslatedAudio.asStateFlow()

    private val _translationSourceLanguageCode = MutableStateFlow("en")
    val translationSourceLanguageCode: StateFlow<String> = _translationSourceLanguageCode.asStateFlow()

    private val _translationTargetLanguageCode = MutableStateFlow("ja")
    val translationTargetLanguageCode: StateFlow<String> = _translationTargetLanguageCode.asStateFlow()

    private val _detectedLanguage = MutableStateFlow<String?>(null)
    val detectedLanguage: StateFlow<String?> = _detectedLanguage.asStateFlow()

    private val _ttsRate = MutableStateFlow(1.0f)
    val ttsRate: StateFlow<Float> = _ttsRate.asStateFlow()

    private val _translatedConfirmedText = MutableStateFlow("")
    val translatedConfirmedText: StateFlow<String> = _translatedConfirmedText.asStateFlow()

    private val _translatedHypothesisText = MutableStateFlow("")
    val translatedHypothesisText: StateFlow<String> = _translatedHypothesisText.asStateFlow()

    private val _translationWarning = MutableStateFlow<String?>(null)
    val translationWarning: StateFlow<String?> = _translationWarning.asStateFlow()

    // System resource metrics (always sampled)
    private val systemMetrics = SystemMetrics()
    private val _cpuPercent = MutableStateFlow(0f)
    val cpuPercent: StateFlow<Float> = _cpuPercent.asStateFlow()
    private val _memoryMB = MutableStateFlow(0f)
    val memoryMB: StateFlow<Float> = _memoryMB.asStateFlow()

    // E2E evidence result
    private val _e2eResult = MutableStateFlow<E2ETestResult?>(null)
    val e2eResult: StateFlow<E2ETestResult?> = _e2eResult.asStateFlow()

    // ASR engine abstraction
    private val setupMutex = Mutex()
    private var currentEngine: AsrEngine? = null
    private var transcriptionJob: Job? = null
    private var recordingJob: Job? = null
    private var energyJob: Job? = null
    private val chunkManager = StreamingChunkManager()
    private var lastBufferSize: Int = 0
    private val inferenceMutex = Mutex()
    private val sessionToken = AtomicLong(0)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val nativeTranslator: AndroidNativeTranslator? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            AndroidNativeTranslator(context)
        } else {
            null
        }
    private val ttsService = AndroidTtsService(context)
    private var translationJob: Job? = null
    private var lastSpokenTranslatedConfirmed: String = ""
    private var lastTranslationInput: Pair<String, String>? = null
    private var ttsStartCount: Int = 0
    private var ttsMicGuardViolations: Int = 0
    private var micStoppedForTts: Boolean = false

    private fun nextSessionToken(): Long = sessionToken.incrementAndGet()

    private fun invalidateSession() {
        sessionToken.incrementAndGet()
    }

    private fun isSessionActive(token: Long): Boolean {
        return sessionToken.get() == token && _sessionState.value == SessionState.Recording
    }

    companion object {
        private const val MAX_BUFFER_SAMPLES = 16000 * 300 // 5 minutes
        private const val MIN_NEW_AUDIO_SECONDS = 1.0f
        // Emulator host-mic levels are often lower than physical devices.
        private const val SILENCE_THRESHOLD = 0.0015f
        private const val FORCE_TRANSCRIBE_AFTER_SILENT_WINDOWS = 2
        private const val NO_SIGNAL_TIMEOUT_SECONDS = 8.0
        private const val SIGNAL_ENERGY_THRESHOLD = 0.005f
        private val WHITESPACE_REGEX = "\\s+".toRegex()
    }

    val fullTranscriptionText: String
        get() = chunkManager.fullTranscriptionText()

    val recordingDurationSeconds: Double
        get() = audioRecorder.bufferSeconds

    init {
        ttsService.setPlaybackStateListener { speaking ->
            scope.launch {
                if (speaking) {
                    // TTS started — stop mic to prevent feedback
                    if (audioRecorder.isRecording) {
                        ttsMicGuardViolations += 1
                        micStoppedForTts = true
                        stopRecordingAndWait()
                    }
                }
            }
        }
        scope.launch {
            preferences.selectedModelId.collect { savedId ->
                if (savedId != null) {
                    ModelInfo.availableModels.find { it.id == savedId }?.let {
                        _selectedModel.value = it
                    }
                }
            }
        }
        scope.launch {
            preferences.useVAD.collect { _useVAD.value = it }
        }
        scope.launch {
            preferences.enableTimestamps.collect { _enableTimestamps.value = it }
        }
        scope.launch {
            preferences.translationEnabled.collect { enabled ->
                _translationEnabled.value = enabled
                if (enabled) {
                    scheduleTranslationUpdate()
                } else {
                    resetTranslationState(stopTts = true)
                }
            }
        }
        scope.launch {
            preferences.speakTranslatedAudio.collect { enabled ->
                _speakTranslatedAudio.value = enabled
                if (!enabled) {
                    ttsService.stop()
                    lastSpokenTranslatedConfirmed = ""
                }
            }
        }
        scope.launch {
            preferences.translationSourceLanguage.collect { code ->
                _translationSourceLanguageCode.value = code
                scheduleTranslationUpdate()
            }
        }
        scope.launch {
            preferences.translationTargetLanguage.collect { code ->
                _translationTargetLanguageCode.value = code
                scheduleTranslationUpdate()
            }
        }
        scope.launch {
            preferences.ttsRate.collect { rate ->
                _ttsRate.value = rate
            }
        }
        // Always-running system metrics sampling
        scope.launch {
            while (true) {
                _cpuPercent.value = systemMetrics.getCpuPercent()
                _memoryMB.value = systemMetrics.getMemoryMB()
                delay(1000)
            }
        }
    }

    /** Create the appropriate ASR engine for the given model. */
    private fun createEngine(model: ModelInfo): AsrEngine {
        return when (model.engineType) {
            EngineType.WHISPER_CPP -> WhisperCppEngine()
            EngineType.SHERPA_ONNX -> SherpaOnnxEngine(
                modelType = model.sherpaModelType
                    ?: throw IllegalArgumentException("sherpaModelType required for SHERPA_ONNX models")
            )
            EngineType.SHERPA_ONNX_STREAMING -> SherpaOnnxStreamingEngine()
        }
    }

    /** Resolve the path to pass to loadModel based on engine type. */
    private fun resolveModelPath(model: ModelInfo): String {
        return when (model.engineType) {
            EngineType.WHISPER_CPP -> downloader.modelFilePath(model)
            EngineType.SHERPA_ONNX -> downloader.modelDir(model).absolutePath
            EngineType.SHERPA_ONNX_STREAMING -> downloader.modelDir(model).absolutePath
        }
    }

    suspend fun loadModelIfAvailable() {
        val model = _selectedModel.value
        if (!downloader.isModelDownloaded(model)) return

        _modelState.value = ModelState.Loading
        _lastError.value = null

        try {
            val engine = createEngine(model)
            val modelPath = resolveModelPath(model)
            val success = engine.loadModel(modelPath)
            if (!success) throw Exception("Failed to load model")
            currentEngine = engine
            _modelState.value = ModelState.Loaded
        } catch (e: Throwable) {
            _modelState.value = ModelState.Unloaded
        }
    }

    fun unloadModel() {
        currentEngine?.release()
        currentEngine = null
        _modelState.value = ModelState.Unloaded
    }

    fun isModelDownloaded(model: ModelInfo): Boolean = downloader.isModelDownloaded(model)

    fun setSelectedModel(model: ModelInfo) {
        _selectedModel.value = model
    }

    /** Launch setupModel on the engine's own scope so it survives ViewModel destruction. */
    fun launchSetup() {
        scope.launch { setupModel() }
    }

    suspend fun setupModel() = setupMutex.withLock {
        val model = _selectedModel.value
        _modelState.value = ModelState.Downloading
        _downloadProgress.value = 0f
        _lastError.value = null

        try {
            if (!downloader.isModelDownloaded(model)) {
                // Check available storage before attempting download
                // Use context.filesDir (always exists) since modelsDir may not exist yet
                val available = context.filesDir.usableSpace
                val needed = parseModelSize(model.sizeOnDisk)
                if (needed > 0 && available < (needed * 1.1).toLong()) {
                    _modelState.value = ModelState.Unloaded
                    _lastError.value = AppError.InsufficientStorage(
                        needed = model.sizeOnDisk,
                        available = formatBytes(available)
                    )
                    return@withLock
                }

                downloader.download(model).collect { progress ->
                    _downloadProgress.value = progress
                }
            }

            _modelState.value = ModelState.Loading
            _downloadProgress.value = 1f

            val engine = createEngine(model)
            val modelPath = resolveModelPath(model)
            val success = engine.loadModel(modelPath)
            if (!success) throw Exception("Failed to load model")

            currentEngine?.release()
            currentEngine = engine
            _modelState.value = ModelState.Loaded
            preferences.setSelectedModelId(model.id)
            preferences.setLastModelPath(modelPath)
        } catch (e: Throwable) {
            val wasDownloading = _downloadProgress.value < 1f
            _modelState.value = ModelState.Unloaded
            _downloadProgress.value = 0f
            _lastError.value = if (wasDownloading) {
                AppError.ModelDownloadFailed(e)
            } else {
                AppError.ModelLoadFailed(e)
            }
        }
    }

    suspend fun switchModel(model: ModelInfo) {
        if (_sessionState.value == SessionState.Recording) {
            stopRecordingAndWait()
        }
        _selectedModel.value = model

        currentEngine?.release()
        currentEngine = null
        _modelState.value = ModelState.Unloaded
        setupModel()
    }

    suspend fun setUseVAD(enabled: Boolean) {
        _useVAD.value = enabled
        preferences.setUseVAD(enabled)
    }

    suspend fun setEnableTimestamps(enabled: Boolean) {
        _enableTimestamps.value = enabled
        preferences.setEnableTimestamps(enabled)
    }

    suspend fun setTranslationEnabled(enabled: Boolean) {
        _translationEnabled.value = enabled
        preferences.setTranslationEnabled(enabled)
        if (!enabled) {
            resetTranslationState(stopTts = true)
        } else {
            scheduleTranslationUpdate()
        }
    }

    suspend fun setSpeakTranslatedAudio(enabled: Boolean) {
        _speakTranslatedAudio.value = enabled
        preferences.setSpeakTranslatedAudio(enabled)
        if (!enabled) {
            ttsService.stop()
            lastSpokenTranslatedConfirmed = ""
        }
    }

    suspend fun setTranslationSourceLanguageCode(languageCode: String) {
        val normalized = languageCode.trim().lowercase()
        if (normalized.isEmpty()) return
        _translationSourceLanguageCode.value = normalized
        preferences.setTranslationSourceLanguage(normalized)
        scheduleTranslationUpdate()
    }

    suspend fun setTranslationTargetLanguageCode(languageCode: String) {
        val normalized = languageCode.trim().lowercase()
        if (normalized.isEmpty()) return
        _translationTargetLanguageCode.value = normalized
        preferences.setTranslationTargetLanguage(normalized)
        scheduleTranslationUpdate()
    }

    suspend fun setTtsRate(rate: Float) {
        val normalized = rate.coerceIn(0.25f, 2.0f)
        _ttsRate.value = normalized
        preferences.setTtsRate(normalized)
    }

    fun startRecording() {
        Log.i("WhisperEngine", "startRecording: sessionState=${_sessionState.value}, engine=${currentEngine != null}, loaded=${currentEngine?.isLoaded}")
        if (_sessionState.value != SessionState.Idle) {
            Log.w("WhisperEngine", "startRecording: not idle (${_sessionState.value}), ignoring")
            return
        }

        val engine = currentEngine
        if (engine == null || !engine.isLoaded) {
            Log.e("WhisperEngine", "startRecording: model not ready")
            _lastError.value = AppError.ModelNotReady()
            transitionTo(SessionState.Error)
            return
        }
        if (!audioRecorder.hasPermission()) {
            Log.e("WhisperEngine", "startRecording: no mic permission")
            _lastError.value = AppError.MicrophonePermissionDenied()
            transitionTo(SessionState.Error)
            return
        }

        resetTranscriptionState()
        ttsService.stop()
        transitionTo(SessionState.Recording)
        val activeSessionToken = nextSessionToken()
        transcriptionJob?.cancel()
        recordingJob?.cancel()
        energyJob?.cancel()
        transcriptionJob = null
        recordingJob = null
        energyJob = null

        recordingJob = scope.launch(Dispatchers.IO) {
            try {
                if (!isSessionActive(activeSessionToken)) return@launch
                audioRecorder.startRecording()
            } catch (e: Throwable) {
                if (!isSessionActive(activeSessionToken)) return@launch
                withContext(Dispatchers.Main) {
                    _lastError.value = AppError.TranscriptionFailed(e)
                    transitionTo(SessionState.Error)
                }
            }
        }

        transcriptionJob = scope.launch {
            if (engine.isStreaming) {
                streamingLoop(activeSessionToken)
            } else {
                realtimeLoop(activeSessionToken)
            }
        }

        energyJob = scope.launch {
            while (isSessionActive(activeSessionToken)) {
                _bufferEnergy.value = audioRecorder.relativeEnergy
                _bufferSeconds.value = audioRecorder.bufferSeconds
                delay(100)
            }
        }
    }

    fun stopRecording() {
        if (_sessionState.value != SessionState.Recording) return
        invalidateSession()
        transitionTo(SessionState.Stopping)
        audioRecorder.stopRecording()
        transcriptionJob?.cancel()
        recordingJob?.cancel()
        energyJob?.cancel()
        transcriptionJob = null
        recordingJob = null
        energyJob = null
        transitionTo(SessionState.Idle)
    }

    private suspend fun stopRecordingAndWait() {
        if (_sessionState.value != SessionState.Recording) return
        invalidateSession()
        transitionTo(SessionState.Stopping)
        audioRecorder.stopRecording()
        transcriptionJob?.cancelAndJoin()
        recordingJob?.cancelAndJoin()
        energyJob?.cancelAndJoin()
        transcriptionJob = null
        recordingJob = null
        energyJob = null
        transitionTo(SessionState.Idle)
    }

    fun setLastError(error: AppError) {
        _lastError.value = error
    }

    fun clearError() {
        _lastError.value = null
        if (_sessionState.value == SessionState.Error) {
            transitionTo(SessionState.Idle)
        }
    }

    fun clearTranscription() {
        if (_sessionState.value == SessionState.Recording) {
            invalidateSession()
            audioRecorder.stopRecording()
            transcriptionJob?.cancel()
            recordingJob?.cancel()
            energyJob?.cancel()
            transcriptionJob = null
            recordingJob = null
            energyJob = null
        }
        resetTranscriptionState()
        transitionTo(SessionState.Idle)
    }

    private fun transitionTo(newState: SessionState) {
        _sessionState.value = newState
        _isRecording.value = (newState == SessionState.Recording)
    }

    private suspend fun realtimeLoop(sessionToken: Long) {
        try {
            while (isSessionActive(sessionToken)) {
                try {
                    transcribeCurrentBuffer(sessionToken)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Throwable) {
                    if (!isSessionActive(sessionToken)) return
                    _lastError.value = AppError.TranscriptionFailed(e)
                    transitionTo(SessionState.Error)
                    audioRecorder.stopRecording()
                    return
                }
            }
        } finally {
            // Do not run NonCancellable final inference during teardown.
            // Previous implementation could keep old sessions alive after stop(),
            // causing stacked background inference and progressive latency.
            transcriptionJob = null
            if (isSessionActive(sessionToken)) {
                audioRecorder.stopRecording()
                transitionTo(SessionState.Idle)
            }
        }
    }

    /** Streaming transcription loop — feeds audio incrementally and polls for results. */
    private suspend fun streamingLoop(sessionToken: Long) {
        val engine = currentEngine ?: return
        try {
            while (isSessionActive(sessionToken)) {
                try {
                    // Feed new audio to the streaming engine
                    val currentCount = audioRecorder.sampleCount
                    if (currentCount > lastBufferSize) {
                        val newSamples = audioRecorder.samplesRange(lastBufferSize, currentCount)
                        if (newSamples.isNotEmpty()) {
                            engine.feedAudio(newSamples)
                            lastBufferSize = currentCount
                        }
                    }

                    // Poll streaming result
                    val result = engine.getStreamingResult()
                    if (result != null) {
                        _hypothesisText.value = normalizeDisplayText(result.text)
                        scheduleTranslationUpdate()
                    }

                    // Endpoint detected → finalize this utterance
                    if (engine.isEndpointDetected()) {
                        val finalResult = engine.getStreamingResult()
                        if (finalResult != null && finalResult.text.isNotBlank()) {
                            chunkManager.confirmedSegments.add(finalResult)
                            _confirmedText.value = chunkManager.renderSegmentsText(chunkManager.confirmedSegments)
                        }
                        _hypothesisText.value = ""
                        scheduleTranslationUpdate()
                        engine.resetStreamingState()
                    }

                    val streamingSafeTrimSample = (lastBufferSize - AudioRecorder.SAMPLE_RATE * 30)
                        .coerceAtLeast(0)
                    trimRecorderBufferIfNeeded(streamingSafeTrimSample)

                    delay(100) // 100ms polling interval (matches iOS)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Throwable) {
                    if (!isSessionActive(sessionToken)) return
                    _lastError.value = AppError.TranscriptionFailed(e)
                    transitionTo(SessionState.Error)
                    audioRecorder.stopRecording()
                    return
                }
            }
        } finally {
            // Only finalize trailing text if this session is still active.
            if (currentCoroutineContext().isActive && isSessionActive(sessionToken)) {
                val finalResult = engine.getStreamingResult()
                if (finalResult != null && finalResult.text.isNotBlank()) {
                    chunkManager.confirmedSegments.add(finalResult)
                    _confirmedText.value = chunkManager.renderSegmentsText(chunkManager.confirmedSegments)
                    _hypothesisText.value = ""
                    scheduleTranslationUpdate()
                }
            }
            transcriptionJob = null
            if (isSessionActive(sessionToken)) {
                audioRecorder.stopRecording()
                transitionTo(SessionState.Idle)
            }
        }
    }

    private suspend fun transcribeCurrentBuffer(sessionToken: Long) {
        val engine = currentEngine ?: return
        if (!isSessionActive(sessionToken)) return

        // No-signal detection
        if (audioRecorder.bufferSeconds >= NO_SIGNAL_TIMEOUT_SECONDS &&
            audioRecorder.maxRecentEnergy < SIGNAL_ENERGY_THRESHOLD &&
            _confirmedText.value.isBlank() &&
            _hypothesisText.value.isBlank()
        ) {
            _lastError.value = AppError.NoMicrophoneSignal()
            transitionTo(SessionState.Error)
            audioRecorder.stopRecording()
            transcriptionJob?.cancel()
            recordingJob?.cancel()
            energyJob?.cancel()
            transcriptionJob = null
            recordingJob = null
            energyJob = null
            return
        }

        val currentBufferSize = audioRecorder.sampleCount
        val nextBufferSize = currentBufferSize - lastBufferSize
        val nextBufferSeconds = nextBufferSize.toFloat() / AudioRecorder.SAMPLE_RATE

        // Adaptive delay: wait longer during silence to save CPU
        val effectiveDelay = chunkManager.adaptiveDelay()
        if (nextBufferSeconds < effectiveDelay) {
            delay(100)
            return
        }

        // VAD check
        if (_useVAD.value) {
            val energy = audioRecorder.relativeEnergy
            if (energy.isNotEmpty()) {
                val recentEnergy = energy.takeLast(10)
                val avgEnergy = recentEnergy.sum() / recentEnergy.size
                val peakEnergy = recentEnergy.maxOrNull() ?: 0f
                val hasVoice = peakEnergy >= SILENCE_THRESHOLD ||
                    avgEnergy >= SILENCE_THRESHOLD * 0.5f

                if (!hasVoice) {
                    chunkManager.consecutiveSilentWindows += 1
                    val shouldForceDecode =
                        chunkManager.consecutiveSilentWindows >= FORCE_TRANSCRIBE_AFTER_SILENT_WINDOWS
                    if (!shouldForceDecode) {
                        lastBufferSize = currentBufferSize
                        return
                    }
                } else {
                    chunkManager.consecutiveSilentWindows = 0
                }
            } else {
                chunkManager.consecutiveSilentWindows += 1
                if (chunkManager.consecutiveSilentWindows < FORCE_TRANSCRIBE_AFTER_SILENT_WINDOWS) {
                    lastBufferSize = currentBufferSize
                    return
                }
            }
        }

        lastBufferSize = currentBufferSize

        // Update energy visualization
        _bufferEnergy.value = audioRecorder.relativeEnergy
        _bufferSeconds.value = audioRecorder.bufferSeconds

        // Chunk-based windowing via StreamingChunkManager
        val slice = chunkManager.computeSlice(currentBufferSize) ?: return

        val audioSamples = audioRecorder.samplesRange(slice.startSample, slice.endSample)
        if (audioSamples.isEmpty()) return

        val startTime = System.nanoTime()
        val numThreads = computeInferenceThreads()
        // Keep at most one native transcribe call in-flight.
        // If an older session is still finishing, skip this cycle instead of queueing,
        // which prevents start/stop latency from compounding across sessions.
        if (!inferenceMutex.tryLock()) {
            return
        }
        val newSegments = try {
            engine.transcribe(audioSamples, numThreads, "auto")
        } finally {
            inferenceMutex.unlock()
        }
        if (!isSessionActive(sessionToken)) return

        val elapsed = (System.nanoTime() - startTime) / 1_000_000_000.0
        val sliceDurationSec = audioSamples.size.toFloat() / AudioRecorder.SAMPLE_RATE
        val totalWords = newSegments.sumOf { it.text.split(" ").size }
        if (elapsed > 0 && totalWords > 0) {
            _tokensPerSecond.value = totalWords / elapsed
        }
        Log.i("WhisperEngine", "chunk inference: %.1fs audio in %.2fs (ratio %.1fx, %d words)"
            .format(sliceDurationSec, elapsed, sliceDurationSec / elapsed, totalWords))

        if (newSegments.isNotEmpty()) {
            chunkManager.consecutiveSilentWindows = 0
            // Extract detected language from engine (SenseVoice provides this)
            val lang = newSegments.firstOrNull()?.detectedLanguage
            if (lang != null && lang != _detectedLanguage.value) {
                _detectedLanguage.value = lang
                applyDetectedLanguageToTranslation(lang)
            }
        }
        chunkManager.processTranscriptionResult(newSegments, slice.sliceOffsetMs)
        _confirmedText.value = chunkManager.confirmedText
        _hypothesisText.value = chunkManager.hypothesisText
        scheduleTranslationUpdate()

        val safeTrimSample = ((chunkManager.lastConfirmedSegmentEndMs * AudioRecorder.SAMPLE_RATE) / 1000)
            .toInt()
        trimRecorderBufferIfNeeded(safeTrimSample)
    }


    private fun trimRecorderBufferIfNeeded(safeTrimBeforeAbsoluteSample: Int) {
        val currentAbsoluteSamples = audioRecorder.sampleCount
        if (currentAbsoluteSamples <= MAX_BUFFER_SAMPLES) return

        val targetKeepSamples = MAX_BUFFER_SAMPLES / 2
        val desiredDropBefore = currentAbsoluteSamples - targetKeepSamples
        val dropBefore = minOf(
            desiredDropBefore,
            safeTrimBeforeAbsoluteSample.coerceAtLeast(0)
        )
        if (dropBefore <= 0) return

        val dropped = audioRecorder.discardSamples(beforeAbsoluteIndex = dropBefore)
        if (dropped > 0) {
            Log.i(
                "WhisperEngine",
                "Trimmed $dropped old mic samples (safeBefore=$safeTrimBeforeAbsoluteSample, current=$currentAbsoluteSamples)"
            )
        }
    }

    /**
     * When the ASR engine detects a language (e.g., SenseVoice returns "en" or "ja"),
     * auto-swap translation direction so that detected speech is the source and
     * the other configured language becomes the target.
     */
    private fun applyDetectedLanguageToTranslation(lang: String) {
        if (!_translationEnabled.value) return
        val currentSource = _translationSourceLanguageCode.value
        val currentTarget = _translationTargetLanguageCode.value

        // If detected language matches target but not source, swap them
        if (lang == currentTarget && lang != currentSource) {
            Log.i("WhisperEngine", "Detected language '$lang' matches target — swapping translation direction")
            _translationSourceLanguageCode.value = currentTarget
            _translationTargetLanguageCode.value = currentSource
            resetTranslationState(stopTts = true)
        } else if (lang != currentSource && lang != currentTarget) {
            // Detected a language that doesn't match either — use it as source
            Log.i("WhisperEngine", "Detected language '$lang' — setting as translation source")
            _translationSourceLanguageCode.value = lang
            resetTranslationState(stopTts = true)
        }
        // If lang == currentSource, no change needed
    }

    private fun resetTranscriptionState() {
        resetTranslationState(stopTts = false)
        lastBufferSize = 0
        chunkManager.reset()
        _confirmedText.value = ""
        _hypothesisText.value = ""
        _detectedLanguage.value = null
        ttsStartCount = 0
        ttsMicGuardViolations = 0
        micStoppedForTts = false
        _bufferEnergy.value = emptyList()
        _bufferSeconds.value = 0.0
        _tokensPerSecond.value = 0.0
        _lastError.value = null
        audioRecorder.reset()
    }

    /** Clear translation-related state without affecting transcription or audio. */
    private fun resetTranslationState(stopTts: Boolean) {
        translationJob?.cancel()
        translationJob = null
        _translatedConfirmedText.value = ""
        _translatedHypothesisText.value = ""
        _translationWarning.value = null
        lastSpokenTranslatedConfirmed = ""
        lastTranslationInput = null
        if (stopTts) {
            ttsService.stop()
        }
    }

    /** Transcribe a 16kHz mono PCM WAV file. Used for testing on emulator. */
    fun transcribeFile(filePath: String) {
        val engine = currentEngine
        if (engine == null || !engine.isLoaded) {
            Log.e("WhisperEngine", "transcribeFile: model not ready")
            _lastError.value = AppError.ModelNotReady()
            return
        }

        // Guard: ignore if already busy transcribing
        if (_sessionState.value == SessionState.Recording) {
            Log.w("WhisperEngine", "transcribeFile: already busy, ignoring")
            return
        }

        resetTranscriptionState()
        transitionTo(SessionState.Recording)
        _hypothesisText.value = "Transcribing file..."

        transcriptionJob = scope.launch {
            try {
                Log.i("WhisperEngine", "transcribeFile: reading $filePath")
                var audioSamples = withContext(Dispatchers.IO) {
                    readWavFile(filePath)
                }
                audioSamples = capAudioForStability(audioSamples)
                val durationSec = audioSamples.size / 16000.0
                Log.i("WhisperEngine", "transcribeFile: ${audioSamples.size} samples (${durationSec}s)")
                _hypothesisText.value = "Transcribing ${"%.1f".format(durationSec)}s of audio..."

                audioRecorder.injectSamples(audioSamples)
                _bufferSeconds.value = durationSec
                _bufferEnergy.value = audioRecorder.relativeEnergy

                val startTime = System.nanoTime()
                val numThreads = computeInferenceThreads()
                Log.i("WhisperEngine", "transcribeFile: starting transcription with $numThreads threads")
                val segments = engine.transcribe(audioSamples, numThreads, "auto")

                val elapsed = (System.nanoTime() - startTime) / 1_000_000_000.0
                val totalWords = segments.sumOf { it.text.split(" ").size }
                Log.i("WhisperEngine", "transcribeFile: ${segments.size} segments, $totalWords words in ${"%.2f".format(elapsed)}s")
                if (elapsed > 0 && totalWords > 0) {
                    _tokensPerSecond.value = totalWords / elapsed
                }
                chunkManager.confirmedSegments.addAll(segments)
                val renderedText = chunkManager.renderSegmentsText(segments)
                chunkManager.confirmedText = renderedText
                _confirmedText.value = renderedText
                _hypothesisText.value = ""
                scheduleTranslationUpdate()
                val waitUntil = SystemClock.elapsedRealtime() + 12_000L
                while (SystemClock.elapsedRealtime() < waitUntil) {
                    val translatedReady = !_translationEnabled.value ||
                        _confirmedText.value.isBlank() ||
                        _translatedConfirmedText.value.isNotBlank()
                    val ttsReady = !_speakTranslatedAudio.value ||
                        _translatedConfirmedText.value.isBlank() ||
                        ttsService.latestEvidenceFilePath() != null
                    if (translatedReady && ttsReady) break
                    delay(250)
                }

                // Write E2E evidence result
                writeE2EResult(
                    transcript = _confirmedText.value,
                    durationMs = elapsed * 1000,
                    error = null
                )
            } catch (e: CancellationException) {
                Log.i("WhisperEngine", "transcribeFile: cancelled")
            } catch (e: Throwable) {
                Log.e("WhisperEngine", "transcribeFile failed", e)
                _lastError.value = AppError.TranscriptionFailed(e)
                writeE2EResult(transcript = "", durationMs = 0.0, error = e.message)
            } finally {
                transitionTo(SessionState.Idle)
            }
        }
    }

    private fun writeE2EResult(transcript: String, durationMs: Double, error: String?) {
        val model = _selectedModel.value
        val keywords = listOf("country", "ask", "do for")
        val lowerTranscript = transcript.lowercase()
        val translatedText = _translatedConfirmedText.value
        val ttsAudioPath = ttsService.latestEvidenceFilePath()
        val sourceCode = _translationSourceLanguageCode.value.trim().lowercase()
        val targetCode = _translationTargetLanguageCode.value.trim().lowercase()
        val expectsTranslation = _translationEnabled.value &&
            transcript.isNotBlank() &&
            sourceCode.isNotBlank() &&
            targetCode.isNotBlank() &&
            sourceCode != targetCode
        val translationReady = !expectsTranslation || translatedText.isNotBlank()
        val expectsTtsEvidence = _speakTranslatedAudio.value && expectsTranslation
        val ttsReady = !expectsTtsEvidence || !ttsAudioPath.isNullOrBlank()

        // pass = core transcription quality only; translation/TTS tracked separately
        val pass = error == null &&
            transcript.isNotEmpty() &&
            keywords.any { lowerTranscript.contains(it) } &&
            ttsMicGuardViolations == 0

        val result = E2ETestResult(
            modelId = model.id,
            engine = model.inferenceMethod,
            transcript = transcript,
            translatedText = translatedText,
            ttsAudioPath = ttsAudioPath,
            ttsStartCount = ttsStartCount,
            ttsMicGuardViolations = ttsMicGuardViolations,
            micStoppedForTts = micStoppedForTts,
            pass = pass,
            durationMs = durationMs,
            timestamp = java.time.Instant.now().toString(),
            error = error
        )
        _e2eResult.value = result

        // Write JSON to app's external files dir for collection by test harness
        try {
            val json = buildString {
                append("{\n")
                append("  \"model_id\": \"${jsonEscape(result.modelId)}\",\n")
                append("  \"engine\": \"${jsonEscape(result.engine)}\",\n")
                append("  \"transcript\": \"${jsonEscape(result.transcript)}\",\n")
                append("  \"translated_text\": \"${jsonEscape(result.translatedText)}\",\n")
                append("  \"translation_warning\": ")
                append(
                    _translationWarning.value?.let { "\"${jsonEscape(it)}\"" } ?: "null"
                )
                append(",\n")
                append("  \"expects_translation\": $expectsTranslation,\n")
                append("  \"translation_ready\": $translationReady,\n")
                append("  \"tts_audio_path\": ")
                append(
                    if (result.ttsAudioPath != null) {
                        "\"${jsonEscape(result.ttsAudioPath)}\""
                    } else {
                        "null"
                    }
                )
                append(",\n")
                append("  \"expects_tts_evidence\": $expectsTtsEvidence,\n")
                append("  \"tts_ready\": $ttsReady,\n")
                append("  \"tts_start_count\": ${result.ttsStartCount},\n")
                append("  \"tts_mic_guard_violations\": ${result.ttsMicGuardViolations},\n")
                append("  \"mic_stopped_for_tts\": ${result.micStoppedForTts},\n")
                append("  \"pass\": ${result.pass},\n")
                append("  \"duration_ms\": ${result.durationMs},\n")
                append("  \"timestamp\": \"${jsonEscape(result.timestamp)}\",\n")
                append("  \"error\": ")
                append(
                    if (result.error != null) {
                        "\"${jsonEscape(result.error)}\""
                    } else {
                        "null"
                    }
                )
                append("\n")
                append("}")
            }
            val extDir = context.getExternalFilesDir(null)
            val file = File(extDir, "e2e_result_${model.id}.json")
            file.writeText(json)
            Log.i("E2E", "Result written to ${file.absolutePath}")
        } catch (e: Throwable) {
            Log.w("E2E", "Could not write result JSON (expected in non-test environments)", e)
        }
    }

    private fun parseModelSize(sizeStr: String): Long {
        val cleaned = sizeStr.replace("~", "").trim()
        val parts = cleaned.split(" ")
        if (parts.size != 2) return 0L
        val value = parts[0].toDoubleOrNull() ?: return 0L
        return when (parts[1].uppercase()) {
            "GB" -> (value * 1024 * 1024 * 1024).toLong()
            "MB" -> (value * 1024 * 1024).toLong()
            "KB" -> (value * 1024).toLong()
            else -> 0L
        }
    }

    private fun formatBytes(bytes: Long): String {
        return when {
            bytes >= 1024L * 1024 * 1024 -> String.format("%.1f GB", bytes / (1024.0 * 1024 * 1024))
            bytes >= 1024L * 1024 -> String.format("%.0f MB", bytes / (1024.0 * 1024))
            else -> String.format("%.0f KB", bytes / 1024.0)
        }
    }

    private fun jsonEscape(value: String): String {
        return value
            .replace("\\", "\\\\")
            .replace("\"", "\\\"")
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\t", "\\t")
    }

    private fun applyTranslationWarning(
        warning: String,
        stopTts: Boolean = false,
        resetSpokenCache: Boolean = false
    ) {
        _translationWarning.value = warning
        if (resetSpokenCache) {
            lastSpokenTranslatedConfirmed = ""
        }
        if (stopTts) {
            ttsService.stop()
        }
    }

    private suspend fun enforceMicStoppedForTts(): Boolean {
        if (audioRecorder.isRecording) {
            micStoppedForTts = true
            stopRecordingAndWait()
        }
        if (audioRecorder.isRecording) {
            ttsMicGuardViolations += 1
            transitionTo(SessionState.Idle)
            audioRecorder.stopRecording()
        }
        return !audioRecorder.isRecording
    }

    private fun scheduleTranslationUpdate() {
        translationJob?.cancel()

        if (!_translationEnabled.value) {
            resetTranslationState(stopTts = false)
            return
        }

        val confirmedSnapshot = _confirmedText.value.trim()
        val hypothesisSnapshot = _hypothesisText.value.trim()
        val sourceLanguageCode = _translationSourceLanguageCode.value.trim().lowercase()
        val targetLanguageCode = _translationTargetLanguageCode.value.trim().lowercase()

        if (sourceLanguageCode.isEmpty() || targetLanguageCode.isEmpty()) return

        val currentInput = confirmedSnapshot to hypothesisSnapshot
        if (lastTranslationInput == currentInput) return

        translationJob = scope.launch {
            var warningMessage: String? = null

            var translatedConfirmed: String
            var translatedHypothesis: String

            if (sourceLanguageCode == targetLanguageCode) {
                translatedConfirmed = confirmedSnapshot
                translatedHypothesis = hypothesisSnapshot
            } else {
                try {
                    translatedConfirmed = if (confirmedSnapshot.isBlank()) {
                        ""
                    } else {
                        val translator = nativeTranslator
                            ?: throw UnsupportedOperationException("Native translation requires Android 12+.")
                        translator.translate(
                            text = confirmedSnapshot,
                            sourceLanguageCode = sourceLanguageCode,
                            targetLanguageCode = targetLanguageCode
                        )
                    }

                    translatedHypothesis = if (hypothesisSnapshot.isBlank()) {
                        ""
                    } else {
                        val translator = nativeTranslator
                            ?: throw UnsupportedOperationException("Native translation requires Android 12+.")
                        translator.translate(
                            text = hypothesisSnapshot,
                            sourceLanguageCode = sourceLanguageCode,
                            targetLanguageCode = targetLanguageCode
                        )
                    }
                } catch (e: UnsupportedOperationException) {
                    translatedConfirmed = confirmedSnapshot
                    translatedHypothesis = hypothesisSnapshot
                    warningMessage = AppError.TranslationUnavailable().message
                } catch (e: Throwable) {
                    if (e is CancellationException) return@launch
                    translatedConfirmed = confirmedSnapshot
                    translatedHypothesis = hypothesisSnapshot
                    warningMessage = AppError.TranslationFailed(e).message
                }
            }

            _translatedConfirmedText.value = normalizeDisplayText(translatedConfirmed)
            _translatedHypothesisText.value = normalizeDisplayText(translatedHypothesis)
            _translationWarning.value = warningMessage
            lastTranslationInput = currentInput

            if (_speakTranslatedAudio.value) {
                speakTranslatedDeltaIfNeeded(_translatedConfirmedText.value, targetLanguageCode)
            }
        }
    }

    private suspend fun speakTranslatedDeltaIfNeeded(translatedConfirmed: String, languageCode: String) {
        val normalized = normalizeDisplayText(translatedConfirmed)
        if (normalized.isBlank()) return

        var delta = normalized
        if (lastSpokenTranslatedConfirmed.isNotBlank() &&
            normalized.startsWith(lastSpokenTranslatedConfirmed)
        ) {
            delta = normalizeDisplayText(
                normalized.removePrefix(lastSpokenTranslatedConfirmed)
            )
        }

        if (delta.isBlank()) return

        if (!enforceMicStoppedForTts()) {
            applyTranslationWarning(
                "Microphone is still active; skipped TTS playback to avoid feedback loop.",
                stopTts = true
            )
            return
        }

        try {
            ttsStartCount += 1
            ttsService.speak(
                text = delta,
                languageCode = languageCode,
                rate = _ttsRate.value
            )
            lastSpokenTranslatedConfirmed = normalized
        } catch (e: Throwable) {
            _lastError.value = AppError.TtsFailed(e)
        }
    }

    private fun normalizeDisplayText(text: String): String {
        return text.replace(WHITESPACE_REGEX, " ").trim()
    }

    private fun computeInferenceThreads(): Int {
        val cpuThreads = Runtime.getRuntime().availableProcessors().coerceAtMost(4).coerceAtLeast(1)
        val model = _selectedModel.value
        if (model.engineType != EngineType.WHISPER_CPP) {
            return cpuThreads
        }

        val heavyWhisperModel = isHeavyWhisperModel(model)
        return when {
            isLikelyEmulator() && heavyWhisperModel -> 1
            isLikelyEmulator() -> cpuThreads.coerceAtMost(2)
            heavyWhisperModel -> cpuThreads.coerceAtMost(2)
            else -> cpuThreads
        }
    }

    /**
     * Emulator stability guard: very large whisper.cpp models can trigger native ggml crashes
     * on long test clips. Trim only debug/E2E file transcription input on emulators.
     */
    private fun capAudioForStability(samples: FloatArray): FloatArray {
        val model = _selectedModel.value
        if (model.engineType != EngineType.WHISPER_CPP || !isLikelyEmulator()) {
            return samples
        }
        if (!isHeavyWhisperModel(model)) {
            return samples
        }

        val maxSeconds = if (model.id.contains("large", ignoreCase = true)) 4 else 6
        val maxSamples = AudioRecorder.SAMPLE_RATE * maxSeconds
        if (samples.size <= maxSamples) {
            return samples
        }

        Log.w(
            "WhisperEngine",
            "Trimming ${model.id} test audio from ${samples.size} to $maxSamples samples for emulator stability"
        )
        return samples.copyOf(maxSamples)
    }

    private fun isHeavyWhisperModel(model: ModelInfo): Boolean {
        val id = model.id.lowercase()
        return id.contains("small") || id.contains("large")
    }

    private fun isLikelyEmulator(): Boolean {
        val fingerprint = Build.FINGERPRINT.lowercase()
        val model = Build.MODEL.lowercase()
        val brand = Build.BRAND.lowercase()
        val device = Build.DEVICE.lowercase()
        val product = Build.PRODUCT.lowercase()
        return fingerprint.contains("generic") ||
            fingerprint.contains("emulator") ||
            model.contains("emulator") ||
            model.contains("sdk") ||
            product.contains("sdk") ||
            brand.contains("generic") ||
            device.contains("generic")
    }

    private fun readWavFile(filePath: String): FloatArray {
        val file = File(filePath)
        if (!file.exists()) throw Exception("File not found: $filePath")
        val bytes = file.readBytes()
        if (bytes.size < 12) throw Exception("File too small to be a valid WAV")

        val riff = String(bytes, 0, 4, Charsets.US_ASCII)
        if (riff != "RIFF") throw Exception("Not a RIFF file")
        val wave = String(bytes, 8, 4, Charsets.US_ASCII)
        if (wave != "WAVE") throw Exception("Not a WAVE file")

        // Parse chunks to find fmt and data
        var bitsPerSample = 16
        var channels = 1
        var sampleRate = 16000
        var dataOffset = -1
        var dataSize = -1

        var pos = 12
        while (pos + 8 <= bytes.size) {
            val chunkId = String(bytes, pos, 4, Charsets.US_ASCII)
            val chunkSize = java.nio.ByteBuffer.wrap(bytes, pos + 4, 4)
                .order(java.nio.ByteOrder.LITTLE_ENDIAN).int
            if (chunkId == "fmt " && pos + 8 + chunkSize <= bytes.size) {
                val buf = java.nio.ByteBuffer.wrap(bytes, pos + 8, chunkSize)
                    .order(java.nio.ByteOrder.LITTLE_ENDIAN)
                buf.short // audioFormat
                channels = buf.short.toInt()
                sampleRate = buf.int
                buf.int // byteRate
                buf.short // blockAlign
                bitsPerSample = buf.short.toInt()
            } else if (chunkId == "data") {
                dataOffset = pos + 8
                dataSize = chunkSize.coerceAtMost(bytes.size - dataOffset)
                break
            }
            pos += 8 + chunkSize
            if (chunkSize % 2 != 0) pos++ // RIFF chunks are word-aligned
        }

        if (dataOffset < 0 || dataSize <= 0) throw Exception("No data chunk found in WAV")
        Log.i("WhisperEngine", "WAV: ${sampleRate}Hz ${channels}ch ${bitsPerSample}bit data=${dataSize}B")

        return if (bitsPerSample == 16) {
            val sampleCount = dataSize / (2 * channels)
            FloatArray(sampleCount) { i ->
                val off = dataOffset + i * 2 * channels
                val low = bytes[off].toInt() and 0xFF
                val high = bytes[off + 1].toInt()
                (high shl 8 or low).toFloat() / 32768f
            }
        } else if (bitsPerSample == 32) {
            val sampleCount = dataSize / (4 * channels)
            FloatArray(sampleCount) { i ->
                val off = dataOffset + i * 4 * channels
                java.nio.ByteBuffer.wrap(bytes, off, 4)
                    .order(java.nio.ByteOrder.LITTLE_ENDIAN).float
            }
        } else {
            throw Exception("Unsupported bits per sample: $bitsPerSample")
        }
    }

    fun destroy() {
        if (_sessionState.value == SessionState.Recording) {
            audioRecorder.stopRecording()
            transcriptionJob?.cancel()
            recordingJob?.cancel()
            energyJob?.cancel()
        }
        translationJob?.cancel()
        scope.cancel()
        nativeTranslator?.close()
        ttsService.setPlaybackStateListener(null)
        ttsService.shutdown()
        currentEngine?.release()
        currentEngine = null
    }
}
