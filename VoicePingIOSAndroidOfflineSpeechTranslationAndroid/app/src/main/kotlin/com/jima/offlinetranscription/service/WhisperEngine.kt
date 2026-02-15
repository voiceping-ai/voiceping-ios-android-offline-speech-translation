package com.voiceping.offlinetranscription.service

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.SystemClock
import android.util.Log
import com.voiceping.offlinetranscription.data.AppPreferences
import com.voiceping.offlinetranscription.model.AndroidSpeechMode
import com.voiceping.offlinetranscription.model.AudioInputMode
import com.voiceping.offlinetranscription.model.AppError
import com.voiceping.offlinetranscription.model.EngineType
import com.voiceping.offlinetranscription.model.ModelInfo
import com.voiceping.offlinetranscription.model.ModelState
import com.voiceping.offlinetranscription.model.TranslationProvider
import com.voiceping.offlinetranscription.util.TextNormalizationUtils
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.sqrt

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

    private val _audioInputMode = MutableStateFlow(AudioInputMode.MICROPHONE)
    val audioInputMode: StateFlow<AudioInputMode> = _audioInputMode.asStateFlow()

    private val _systemAudioCaptureReady = MutableStateFlow(false)
    val systemAudioCaptureReady: StateFlow<Boolean> = _systemAudioCaptureReady.asStateFlow()
    val isSystemAudioCaptureSupported: Boolean
        get() = audioRecorder.isSystemAudioCaptureSupported

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

    // Translation providers
    private val mlKitTranslator = MlKitTranslator()
    private val androidSystemTranslator = AndroidSystemTranslator(context)

    private val _translationProvider = MutableStateFlow(TranslationProvider.ML_KIT)
    val translationProvider: StateFlow<TranslationProvider> = _translationProvider.asStateFlow()

    @OptIn(ExperimentalCoroutinesApi::class)
    val translationModelReady: StateFlow<Boolean> by lazy {
        _translationProvider.flatMapLatest { provider ->
            when (provider) {
                TranslationProvider.ML_KIT -> mlKitTranslator.modelReady
                TranslationProvider.ANDROID_SYSTEM -> androidSystemTranslator.modelReady
            }
        }.stateIn(scope, SharingStarted.Eagerly, false)
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    val translationDownloadStatus: StateFlow<String?> by lazy {
        _translationProvider.flatMapLatest { provider ->
            when (provider) {
                TranslationProvider.ML_KIT -> mlKitTranslator.downloadStatus
                TranslationProvider.ANDROID_SYSTEM -> androidSystemTranslator.downloadStatus
            }
        }.stateIn(scope, SharingStarted.Eagerly, null)
    }

    val isAndroidSystemTranslationAvailable: Boolean
        get() = androidSystemTranslator.isAvailable

    // System resource metrics (always sampled)
    private val systemMetrics = SystemMetrics()
    private val _cpuPercent = MutableStateFlow(0f)
    val cpuPercent: StateFlow<Float> = _cpuPercent.asStateFlow()
    private val _memoryMB = MutableStateFlow(0f)
    val memoryMB: StateFlow<Float> = _memoryMB.asStateFlow()

    // E2E evidence collection (delegated to E2ETestOrchestrator)
    val e2eOrchestrator by lazy { E2ETestOrchestrator(context, this) }
    val e2eResult: StateFlow<E2ETestResult?> get() = e2eOrchestrator.e2eResult

    // E2E accessors for TTS/mic state (read by E2ETestOrchestrator)
    fun ttsEvidenceFilePath(): String? = ttsService.latestEvidenceFilePath()
    val ttsStartCountValue: Int get() = ttsStartCount
    val ttsMicGuardViolationCount: Int get() = ttsMicGuardViolations
    val isMicStoppedForTts: Boolean get() = micStoppedForTts

    // ASR engine abstraction
    private val setupMutex = Mutex()
    internal var currentEngine: AsrEngine? = null
        private set
    private var recordingJob: Job? = null
    private var energyJob: Job? = null
    private val recorderPrewarmMutex = Mutex()
    private val inferencePrewarmMutex = Mutex()
    internal var chunkManager: StreamingChunkManager = StreamingChunkManager(
        chunkSeconds = 5.0f,
        sampleRate = AudioRecorder.SAMPLE_RATE,
        minNewAudioSeconds = 0.7f
    )
        private set
    private var prewarmedModelId: String? = null
    private val sessionToken = AtomicLong(0)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val ttsService = AndroidTtsService(context)
    private var translationJob: Job? = null
    private var lastSpokenTranslatedConfirmed: String = ""
    private var lastTranslationInput: Pair<String, String>? = null
    private var ttsStartCount: Int = 0
    private var ttsMicGuardViolations: Int = 0
    private var micStoppedForTts: Boolean = false

    // Transcription coordination (extracted from this class)
    val transcriptionCoordinator = TranscriptionCoordinator(this)

    private fun nextSessionToken(): Long = sessionToken.incrementAndGet()

    private fun invalidateSession() {
        sessionToken.incrementAndGet()
    }

    internal fun isSessionActive(token: Long): Boolean {
        return sessionToken.get() == token && _sessionState.value == SessionState.Recording
    }

    companion object {
        private const val INFERENCE_PREWARM_AUDIO_SECONDS = 0.5f
        fun normalizeLanguageCode(raw: String?): String? =
            TextNormalizationUtils.normalizeLanguageCode(raw)
    }

    // Internal mutation methods for TranscriptionCoordinator
    internal fun updateConfirmedText(text: String) { _confirmedText.value = text }
    internal fun updateHypothesisText(text: String) { _hypothesisText.value = text }
    internal fun updateDetectedLanguage(lang: String) { _detectedLanguage.value = lang }
    internal fun updateTokensPerSecond(value: Double) { _tokensPerSecond.value = value }
    internal fun updateBufferEnergy(energy: List<Float>) { _bufferEnergy.value = energy }
    internal fun updateBufferSeconds(seconds: Double) { _bufferSeconds.value = seconds }

    internal fun onTranscriptionError(error: AppError) {
        _lastError.value = error
        transitionTo(SessionState.Error)
        audioRecorder.stopRecording()
        transcriptionCoordinator.cancelTranscriptionJob()
        cancelRecorderAndEnergyJobs()
    }

    internal fun onNoSignalDetected() {
        _lastError.value = AppError.NoMicrophoneSignal()
        transitionTo(SessionState.Error)
        audioRecorder.stopRecording()
        transcriptionCoordinator.cancelTranscriptionJob()
        cancelRecorderAndEnergyJobs()
    }

    val fullTranscriptionText: String
        get() = chunkManager.fullTranscriptionText()

    val recordingDurationSeconds: Double
        get() = audioRecorder.bufferSeconds

    init {
        ttsService.setPlaybackStateListener { speaking ->
            scope.launch {
                Log.e("InterpLoop", "TTS callback: speaking=$speaking micStoppedForTts=$micStoppedForTts session=${_sessionState.value} isRecording=${audioRecorder.isRecording}")
                if (speaking) {
                    if (audioRecorder.isRecording) {
                        ttsMicGuardViolations += 1
                        micStoppedForTts = true
                        stopRecordingAndWait()
                        Log.e("InterpLoop", "TTS callback: stopped mic for TTS guard")
                    }
                } else if (micStoppedForTts) {
                    Log.e("InterpLoop", "TTS callback: TTS done, calling resumeRecordingAfterTts")
                    resumeRecordingAfterTts()
                } else {
                    Log.e("InterpLoop", "TTS callback: TTS done but micStoppedForTts=false, no resume")
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
                if (code != _translationSourceLanguageCode.value) {
                    _translationSourceLanguageCode.value = code
                    lastTranslationInput = null
                    scheduleTranslationUpdate()
                }
            }
        }
        scope.launch {
            preferences.translationTargetLanguage.collect { code ->
                if (code != _translationTargetLanguageCode.value) {
                    _translationTargetLanguageCode.value = code
                    lastTranslationInput = null
                    scheduleTranslationUpdate()
                }
            }
        }
        scope.launch {
            preferences.ttsRate.collect { rate ->
                _ttsRate.value = rate
            }
        }
        scope.launch {
            preferences.translationProvider.collect { providerName ->
                val provider = try {
                    TranslationProvider.valueOf(providerName)
                } catch (_: IllegalArgumentException) {
                    TranslationProvider.ML_KIT
                }
                if (provider != _translationProvider.value) {
                    _translationProvider.value = provider
                    lastTranslationInput = null
                    scheduleTranslationUpdate()
                }
            }
        }
        scope.launch(Dispatchers.Default) {
            while (true) {
                _cpuPercent.value = systemMetrics.getCpuPercent()
                _memoryMB.value = systemMetrics.getMemoryMB()
                delay(1000)
            }
        }
    }

    /** Create the ASR engine for the given model. */
    private fun createEngine(model: ModelInfo): AsrEngine {
        return when (model.engineType) {
            EngineType.SHERPA_ONNX -> SherpaOnnxEngine(
                modelType = model.sherpaModelType
                    ?: throw IllegalArgumentException("sherpaModelType required for SHERPA_ONNX models")
            )
            EngineType.ANDROID_SPEECH -> AndroidSpeechEngine(
                context = context,
                mode = model.androidSpeechMode ?: AndroidSpeechMode.OFFLINE
            )
        }
    }

    private fun createChunkManagerForModel(model: ModelInfo): StreamingChunkManager {
        return transcriptionCoordinator.createChunkManagerForModel()
    }

    /** Resolve the path to pass to loadModel. */
    private fun resolveModelPath(model: ModelInfo): String {
        return downloader.modelDir(model).absolutePath
    }

    /** Ensure startup model selection reflects persisted user preference before loading. */
    suspend fun syncSelectedModelFromPreferences() {
        val savedId = preferences.selectedModelId.first() ?: return
        val savedModel = ModelInfo.availableModels.find { it.id == savedId } ?: return
        _selectedModel.value = savedModel
    }

    suspend fun loadModelIfAvailable() {
        val model = _selectedModel.value
        val noDownloadNeeded = model.files.isEmpty()
        if (!noDownloadNeeded && !downloader.isModelDownloaded(model)) return

        _modelState.value = ModelState.Loading
        _lastError.value = null

        try {
            val engine = createEngine(model)
            val modelPath = if (noDownloadNeeded) "" else resolveModelPath(model)
            val success = engine.loadModel(modelPath)
            if (!success) throw Exception("Failed to load model")
            currentEngine = engine
            prewarmedModelId = null
            _modelState.value = ModelState.Loaded
        } catch (e: Throwable) {
            _modelState.value = ModelState.Unloaded
        }
    }

    fun unloadModel() {
        resetTranscriptionState()
        currentEngine?.release()
        currentEngine = null
        prewarmedModelId = null
        _modelState.value = ModelState.Unloaded
    }

    fun isModelDownloaded(model: ModelInfo): Boolean =
        model.files.isEmpty() || downloader.isModelDownloaded(model)

    fun setSelectedModel(model: ModelInfo) {
        _selectedModel.value = model
        chunkManager = createChunkManagerForModel(model)
        resetTranscriptionState()
    }

    /** Launch setupModel on the engine's own scope so it survives ViewModel destruction. */
    fun launchSetup() {
        scope.launch { setupModel() }
    }

    suspend fun setupModel() = setupMutex.withLock {
        val model = _selectedModel.value
        _lastError.value = null
        val noDownloadNeeded = model.files.isEmpty()

        if (noDownloadNeeded) {
            // System-provided engine (e.g. Android SpeechRecognizer) — skip download phase
            _downloadProgress.value = 1f
        } else {
            _modelState.value = ModelState.Downloading
            _downloadProgress.value = 0f
        }

        try {
            if (!noDownloadNeeded && !downloader.isModelDownloaded(model)) {
                if (!hasValidatedInternetConnection()) {
                    Log.w("WhisperEngine", "No validated internet connection while downloading ${model.id}")
                    _modelState.value = ModelState.Unloaded
                    _lastError.value = AppError.NetworkUnavailable()
                    return@withLock
                }

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
            val modelPath = if (noDownloadNeeded) "" else resolveModelPath(model)
            val success = withContext(Dispatchers.Default) {
                engine.loadModel(modelPath)
            }
            if (!success) throw Exception("Failed to load model")

            val previousEngine = currentEngine
            currentEngine = engine
            prewarmedModelId = null
            _modelState.value = ModelState.Loaded
            preferences.setSelectedModelId(model.id)
            if (modelPath.isNotEmpty()) {
                preferences.setLastModelPath(modelPath)
            }
            if (previousEngine != null && previousEngine !== engine) {
                withContext(Dispatchers.Default) {
                    previousEngine.release()
                }
            }
        } catch (e: Throwable) {
            Log.e("WhisperEngine", "setupModel failed for model=${model.id}", e)
            val wasDownloading = _downloadProgress.value < 1f
            _modelState.value = ModelState.Unloaded
            _downloadProgress.value = 0f
            _lastError.value = if (wasDownloading) {
                mapDownloadError(e)
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
        chunkManager = createChunkManagerForModel(model)
        resetTranscriptionState()

        val previousEngine = currentEngine
        if (previousEngine != null) {
            withContext(Dispatchers.Default) {
                previousEngine.release()
            }
        }
        currentEngine = null
        prewarmedModelId = null
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
            prepareTranslationModel()
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
        val normalized = normalizeLanguageCode(languageCode) ?: return
        _translationSourceLanguageCode.value = normalized
        preferences.setTranslationSourceLanguage(normalized)
        lastTranslationInput = null
        lastSpokenTranslatedConfirmed = ""  // Clear TTS cache — language changed
        ttsService.stop()
        prepareTranslationModel()
        scheduleTranslationUpdate()
    }

    suspend fun setTranslationTargetLanguageCode(languageCode: String) {
        val normalized = normalizeLanguageCode(languageCode) ?: return
        _translationTargetLanguageCode.value = normalized
        preferences.setTranslationTargetLanguage(normalized)
        lastTranslationInput = null
        lastSpokenTranslatedConfirmed = ""  // Clear TTS cache — language changed
        ttsService.stop()
        prepareTranslationModel()
        scheduleTranslationUpdate()
    }

    suspend fun setTtsRate(rate: Float) {
        val normalized = rate.coerceIn(0.25f, 2.0f)
        _ttsRate.value = normalized
        preferences.setTtsRate(normalized)
    }

    suspend fun setTranslationProvider(provider: TranslationProvider) {
        _translationProvider.value = provider
        preferences.setTranslationProvider(provider.name)
        lastTranslationInput = null
        resetTranslationState(stopTts = true)
        prepareTranslationModel()
        scheduleTranslationUpdate()
    }

    /**
     * Proactively download the translation model for the current language pair.
     * Called when translation is enabled, language changes, or provider changes.
     */
    private suspend fun prepareTranslationModel() {
        if (!_translationEnabled.value) return
        val src = _translationSourceLanguageCode.value
        val tgt = _translationTargetLanguageCode.value
        if (src.isBlank() || tgt.isBlank() || src == tgt) return
        when (_translationProvider.value) {
            TranslationProvider.ML_KIT -> mlKitTranslator.prepareModel(src, tgt)
            TranslationProvider.ANDROID_SYSTEM -> { /* system translator has no pre-download */ }
        }
    }

    suspend fun prewarmRecordingPath() {
        if (_audioInputMode.value != AudioInputMode.MICROPHONE) return
        if (!audioRecorder.hasPermission()) return
        if (_sessionState.value != SessionState.Idle) return
        recorderPrewarmMutex.withLock {
            withContext(Dispatchers.IO) {
                audioRecorder.prewarm(_audioInputMode.value)
            }
        }
    }

    suspend fun prewarmInferencePath() {
        if (_sessionState.value != SessionState.Idle) return
        val engine = currentEngine ?: return
        if (!engine.isLoaded) return
        val currentModelId = _selectedModel.value.id
        if (prewarmedModelId == currentModelId) return

        inferencePrewarmMutex.withLock {
            if (_sessionState.value != SessionState.Idle) return
            val liveEngine = currentEngine ?: return
            if (!liveEngine.isLoaded) return
            val liveModelId = _selectedModel.value.id
            if (prewarmedModelId == liveModelId) return

            // sherpa-onnx warmup can burn CPU on some Android runtimes while idle.
            // Skip synthetic inference prewarm for sherpa engines.
            prewarmedModelId = liveModelId
            Log.i("WhisperEngine", "Skipping inference prewarm for sherpa-onnx (CPU-heavy at idle)")
        }
    }

    suspend fun prewarmRealtimePath() {
        Log.i(
            "WhisperEngine",
            "prewarmRealtimePath: state=${_sessionState.value}, inputMode=${_audioInputMode.value}, micPermission=${audioRecorder.hasPermission()}, modelLoaded=${currentEngine?.isLoaded == true}"
        )
        prewarmRecordingPath()
        prewarmInferencePath()
        prepareTranslationModel()
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

        if (_audioInputMode.value == AudioInputMode.SYSTEM_PLAYBACK) {
            if (!audioRecorder.isSystemAudioCaptureSupported) {
                _lastError.value = AppError.SystemAudioCaptureUnsupported()
                transitionTo(SessionState.Error)
                return
            }
            if (!audioRecorder.hasSystemAudioCapturePermission) {
                _lastError.value = AppError.SystemAudioCapturePermissionDenied()
                transitionTo(SessionState.Error)
                return
            }
            if (engine.isSelfRecording) {
                _lastError.value = AppError.TranscriptionFailed(
                    IllegalStateException("Selected ASR engine only supports microphone capture")
                )
                transitionTo(SessionState.Error)
                return
            }
        }

        if (!audioRecorder.hasPermission()) {
            Log.e("WhisperEngine", "startRecording: no mic permission")
            _lastError.value = AppError.MicrophonePermissionDenied()
            transitionTo(SessionState.Error)
            return
        }

        // Ensure the MediaProjection foreground service is running for system audio capture.
        // It may have been stopped after a previous recording session.
        if (_audioInputMode.value == AudioInputMode.SYSTEM_PLAYBACK) {
            try {
                context.startForegroundService(
                    Intent(context, MediaProjectionService::class.java)
                )
            } catch (e: Exception) {
                Log.w("WhisperEngine", "Failed to start MediaProjectionService: ${e.message}")
            }
        }

        resetTranscriptionState()
        ttsService.stop()
        transitionTo(SessionState.Recording)
        val activeSessionToken = nextSessionToken()
        cancelTranscriptionJob()
        cancelRecorderAndEnergyJobs()

        if (engine.isSelfRecording) {
            Log.i("WhisperEngine", "Starting self-recording engine (${_selectedModel.value.id})")
            engine.startListening()

            transcriptionCoordinator.startLoop(scope, activeSessionToken, engine)

            energyJob = scope.launch(Dispatchers.Default) {
                val startMs = SystemClock.elapsedRealtime()
                while (isSessionActive(activeSessionToken)) {
                    _bufferSeconds.value = (SystemClock.elapsedRealtime() - startMs) / 1000.0
                    delay(200)
                }
            }
        } else {
            Log.i("WhisperEngine", "Starting buffered recording (${_selectedModel.value.id})")

            recordingJob = scope.launch(Dispatchers.IO) {
                try {
                    if (!isSessionActive(activeSessionToken)) return@launch
                    audioRecorder.startRecording(_audioInputMode.value)
                } catch (e: Throwable) {
                    if (!isSessionActive(activeSessionToken)) return@launch
                    if (_audioInputMode.value == AudioInputMode.SYSTEM_PLAYBACK) {
                        audioRecorder.clearSystemAudioCapturePermission()
                        _systemAudioCaptureReady.value = false
                    }
                    withContext(Dispatchers.Main) {
                        _lastError.value = AppError.TranscriptionFailed(e)
                        transitionTo(SessionState.Error)
                    }
                }
            }

            transcriptionCoordinator.startLoop(scope, activeSessionToken, engine)

            energyJob = scope.launch(Dispatchers.Default) {
                while (isSessionActive(activeSessionToken)) {
                    _bufferEnergy.value = audioRecorder.relativeEnergy
                    _bufferSeconds.value = audioRecorder.bufferSeconds
                    delay(100)
                }
            }
        }
    }

    fun stopRecording() {
        if (_sessionState.value != SessionState.Recording) return
        transitionTo(SessionState.Stopping)

        val engine = currentEngine
        if (engine != null && engine.isSelfRecording) {
            finalizeSelfRecordingStop(engine)
        } else {
            finalizeBufferedRecordingStop()
        }

        cancelRecorderAndEnergyJobs()
        invalidateSession()
        cancelTranscriptionJob()

        // Stop the MediaProjection foreground service if it was running
        if (_audioInputMode.value == AudioInputMode.SYSTEM_PLAYBACK) {
            try {
                context.stopService(
                    android.content.Intent(context, MediaProjectionService::class.java)
                )
            } catch (e: Exception) {
                Log.w("WhisperEngine", "Failed to stop MediaProjectionService: ${e.message}")
            }
        }

        transitionTo(SessionState.Idle)
    }

    private suspend fun stopRecordingAndWait() {
        if (_sessionState.value != SessionState.Recording) return
        transitionTo(SessionState.Stopping)
        val engine = currentEngine
        if (engine != null && engine.isSelfRecording) {
            withContext(Dispatchers.Main) { engine.stopListening() }
        } else {
            audioRecorder.stopRecording()
        }
        cancelRecorderAndEnergyJobsAndWait()
        invalidateSession()
        cancelTranscriptionJobAndWait()
        // Stop MediaProjection foreground service if running
        if (_audioInputMode.value == AudioInputMode.SYSTEM_PLAYBACK) {
            try {
                context.stopService(
                    android.content.Intent(context, MediaProjectionService::class.java)
                )
            } catch (_: Exception) {}
        }
        transitionTo(SessionState.Idle)
    }

    /** Resume recording immediately after TTS finishes, without resetting transcription state. */
    private suspend fun resumeRecordingAfterTts() {
        if (!micStoppedForTts) {
            Log.e("InterpLoop", "resumeRecordingAfterTts: micStoppedForTts=false, returning")
            return
        }
        micStoppedForTts = false

        if (_sessionState.value != SessionState.Idle) {
            Log.e("InterpLoop", "resumeRecordingAfterTts: session not idle (${_sessionState.value}), skipping")
            return
        }
        val engine = currentEngine
        if (engine == null || !engine.isLoaded) {
            Log.e("InterpLoop", "resumeRecordingAfterTts: no engine or not loaded, skipping")
            return
        }

        Log.e("InterpLoop", "resumeRecordingAfterTts: draining old jobs, then restarting recording")

        // Wait for any lingering jobs to fully complete to avoid concurrent inference
        cancelTranscriptionJobAndWait()
        cancelRecorderAndEnergyJobsAndWait()

        // Re-check state after draining — user may have acted while we waited
        if (_sessionState.value != SessionState.Idle) {
            Log.i("WhisperEngine", "Skipping TTS resume — session changed during drain (state=${_sessionState.value})")
            return
        }

        transcriptionCoordinator.reset()
        chunkManager.reset()
        audioRecorder.reset()
        _confirmedText.value = ""
        _hypothesisText.value = ""
        _translatedConfirmedText.value = ""
        _translatedHypothesisText.value = ""
        lastTranslationInput = null
        lastSpokenTranslatedConfirmed = ""
        Log.e("InterpLoop", "resumeRecordingAfterTts: cleared text state for fresh segment")

        if (_audioInputMode.value == AudioInputMode.SYSTEM_PLAYBACK) {
            try {
                context.startForegroundService(
                    Intent(context, MediaProjectionService::class.java)
                )
            } catch (e: Exception) {
                Log.w("WhisperEngine", "Failed to start MediaProjectionService on TTS resume: ${e.message}")
            }
        }

        transitionTo(SessionState.Recording)

        val activeSessionToken = nextSessionToken()

        if (engine.isSelfRecording) {
            engine.startListening()
            transcriptionCoordinator.startLoop(scope, activeSessionToken, engine)
            energyJob = scope.launch(Dispatchers.Default) {
                val startMs = SystemClock.elapsedRealtime()
                while (isSessionActive(activeSessionToken)) {
                    _bufferSeconds.value = (SystemClock.elapsedRealtime() - startMs) / 1000.0
                    delay(200)
                }
            }
        } else {
            recordingJob = scope.launch(Dispatchers.IO) {
                try {
                    if (!isSessionActive(activeSessionToken)) return@launch
                    audioRecorder.startRecording(_audioInputMode.value)
                } catch (e: Throwable) {
                    if (!isSessionActive(activeSessionToken)) return@launch
                    withContext(Dispatchers.Main) {
                        _lastError.value = AppError.TranscriptionFailed(e)
                        transitionTo(SessionState.Error)
                    }
                }
            }
            transcriptionCoordinator.startLoop(scope, activeSessionToken, engine)
            energyJob = scope.launch(Dispatchers.Default) {
                while (isSessionActive(activeSessionToken)) {
                    _bufferEnergy.value = audioRecorder.relativeEnergy
                    _bufferSeconds.value = audioRecorder.bufferSeconds
                    delay(100)
                }
            }
        }
    }

    private fun finalizeSelfRecordingStop(engine: AsrEngine) {
        transcriptionCoordinator.finalizeSelfRecordingStop(engine)
    }

    private fun finalizeBufferedRecordingStop() {
        transcriptionCoordinator.finalizeBufferedRecordingStop()
    }

    private fun cancelRecorderAndEnergyJobs() {
        recordingJob?.cancel()
        energyJob?.cancel()
        recordingJob = null
        energyJob = null
    }

    private suspend fun cancelRecorderAndEnergyJobsAndWait() {
        recordingJob?.cancelAndJoin()
        energyJob?.cancelAndJoin()
        recordingJob = null
        energyJob = null
    }

    private fun cancelTranscriptionJob() {
        transcriptionCoordinator.cancelTranscriptionJob()
    }

    private suspend fun cancelTranscriptionJobAndWait() {
        transcriptionCoordinator.cancelTranscriptionJobAndWait()
    }

    fun setLastError(error: AppError) {
        _lastError.value = error
    }

    fun setAudioInputMode(mode: AudioInputMode) {
        _audioInputMode.value = mode
    }

    fun setSystemAudioCapturePermission(resultCode: Int, data: Intent?) {
        if (!audioRecorder.isSystemAudioCaptureSupported) {
            _systemAudioCaptureReady.value = false
            _lastError.value = AppError.SystemAudioCaptureUnsupported()
            return
        }
        if (resultCode != Activity.RESULT_OK || data == null) {
            _systemAudioCaptureReady.value = false
            _lastError.value = AppError.SystemAudioCapturePermissionDenied()
            return
        }
        val granted = audioRecorder.setSystemAudioCapturePermission(resultCode, data)
        _systemAudioCaptureReady.value = granted
        if (!granted) {
            _lastError.value = AppError.SystemAudioCapturePermissionDenied()
        } else if (_lastError.value is AppError.SystemAudioCapturePermissionDenied
            || _lastError.value is AppError.SystemAudioCaptureUnsupported
        ) {
            _lastError.value = null
            if (_sessionState.value == SessionState.Error) {
                transitionTo(SessionState.Idle)
            }
        }
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
            val engine = currentEngine
            if (engine != null && engine.isSelfRecording) {
                engine.stopListening()
            } else {
                audioRecorder.stopRecording()
            }
            cancelTranscriptionJob()
            cancelRecorderAndEnergyJobs()
        }
        resetTranscriptionState()
        transitionTo(SessionState.Idle)
    }

    internal fun transitionTo(newState: SessionState) {
        _sessionState.value = newState
        _isRecording.value = (newState == SessionState.Recording)
    }


    internal fun applyDetectedLanguageToTranslation(lang: String) {
        if (!_translationEnabled.value) return
        val currentSource = _translationSourceLanguageCode.value
        val currentTarget = _translationTargetLanguageCode.value

        if (lang == currentTarget && lang != currentSource) {
            Log.i("WhisperEngine", "Detected language '$lang' matches target — swapping translation direction ($currentSource→$currentTarget becomes $currentTarget→$currentSource)")
            _translationSourceLanguageCode.value = currentTarget
            _translationTargetLanguageCode.value = currentSource
            // Persist swapped direction so it survives app restart
            scope.launch {
                preferences.setTranslationSourceLanguage(currentTarget)
                preferences.setTranslationTargetLanguage(currentSource)
            }
            lastTranslationInput = null  // Force re-translation after swap
            resetTranslationState(stopTts = true)
            scheduleTranslationUpdate()
        } else if (lang != currentSource && lang != currentTarget) {
            Log.i("WhisperEngine", "Detected language '$lang' not in pair ($currentSource→$currentTarget) — ignoring")
        }
    }

    private fun resetTranscriptionState() {
        resetTranslationState(stopTts = false)
        transcriptionCoordinator.reset()
        chunkManager = createChunkManagerForModel(_selectedModel.value)
        _confirmedText.value = ""
        _hypothesisText.value = ""
        e2eOrchestrator.reset()
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

    /** Transcribe a 16kHz mono PCM WAV file. Used for testing and file import. */
    fun transcribeFile(filePath: String) {
        val engine = currentEngine
        if (engine == null || !engine.isLoaded) {
            Log.e("WhisperEngine", "transcribeFile: model not ready")
            _lastError.value = AppError.ModelNotReady()
            return
        }

        if (engine.isSelfRecording) {
            Log.w("WhisperEngine", "transcribeFile: not supported for self-recording engines (${_selectedModel.value.id})")
            _lastError.value = AppError.TranscriptionFailed(
                UnsupportedOperationException("File transcription is not supported for Android Speech engine. Use live recording instead.")
            )
            return
        }

        if (_sessionState.value == SessionState.Recording) {
            Log.w("WhisperEngine", "transcribeFile: already busy, ignoring")
            return
        }

        resetTranscriptionState()
        transitionTo(SessionState.Recording)
        _hypothesisText.value = "Transcribing file..."

        scope.launch(Dispatchers.Default) {
            try {
                Log.i("WhisperEngine", "transcribeFile: reading $filePath")
                val audioSamples = withContext(Dispatchers.IO) {
                    readWavFile(filePath)
                }
                val durationSec = audioSamples.size / AudioConstants.SAMPLE_RATE.toDouble()
                Log.i("WhisperEngine", "transcribeFile: ${audioSamples.size} samples (${durationSec}s)")
                _hypothesisText.value = "Transcribing ${"%.1f".format(durationSec)}s of audio..."

                audioRecorder.injectSamples(audioSamples)
                _bufferSeconds.value = durationSec
                _bufferEnergy.value = audioRecorder.relativeEnergy

                val startTime = System.nanoTime()
                val numThreads = Runtime.getRuntime().availableProcessors().coerceAtMost(4).coerceAtLeast(1)
                Log.i("WhisperEngine", "transcribeFile: starting transcription with $numThreads threads")
                val segments = engine.transcribe(audioSamples, numThreads, "auto")

                val elapsed = (System.nanoTime() - startTime) / 1_000_000_000.0
                val totalWords = segments.sumOf { it.text.split(" ").size }
                Log.i("WhisperEngine", "transcribeFile: ${segments.size} segments, $totalWords words in ${"%.2f".format(elapsed)}s")
                if (elapsed > 0 && totalWords > 0) {
                    _tokensPerSecond.value = totalWords / elapsed
                }
                // Apply detected language to translation direction
                val lang = normalizeLanguageCode(segments.firstOrNull()?.detectedLanguage)
                if (lang != null && lang != _detectedLanguage.value) {
                    _detectedLanguage.value = lang
                    applyDetectedLanguageToTranslation(lang)
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

                e2eOrchestrator.writeResult(
                    transcript = _confirmedText.value,
                    durationMs = elapsed * 1000,
                    error = null
                )
            } catch (e: CancellationException) {
                Log.i("WhisperEngine", "transcribeFile: cancelled")
            } catch (e: Throwable) {
                Log.e("WhisperEngine", "transcribeFile failed", e)
                _lastError.value = AppError.TranscriptionFailed(e)
                e2eOrchestrator.writeResult(transcript = "", durationMs = 0.0, error = e.message)
            } finally {
                transitionTo(SessionState.Idle)
            }
        }
    }

    fun writeE2EFailure(modelId: String = _selectedModel.value.id, error: String) {
        e2eOrchestrator.writeFailure(modelId = modelId, error = error)
    }

    private fun hasValidatedInternetConnection(): Boolean {
        val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return false
        val activeNetwork = connectivity.activeNetwork ?: return false
        val caps = connectivity.getNetworkCapabilities(activeNetwork) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    }

    private fun mapDownloadError(error: Throwable): AppError {
        val root = rootCause(error)
        return when {
            !hasValidatedInternetConnection() -> AppError.NetworkUnavailable()
            root is UnknownHostException -> AppError.NetworkUnavailable()
            root is SocketTimeoutException -> AppError.ModelDownloadFailed(
                Exception("Network timeout while downloading. Check connection and retry.")
            )
            else -> AppError.ModelDownloadFailed(error)
        }
    }

    private fun rootCause(error: Throwable): Throwable {
        var cause = error
        var next = cause.cause
        while (next != null && next !== cause) {
            cause = next
            next = cause.cause
        }
        return cause
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
        Log.e("InterpLoop", "enforceMicStoppedForTts: isRecording=${audioRecorder.isRecording} session=${_sessionState.value}")
        if (audioRecorder.isRecording) {
            micStoppedForTts = true
            stopRecordingAndWait()
            Log.e("InterpLoop", "enforceMicStoppedForTts: after stopRecordingAndWait, isRecording=${audioRecorder.isRecording}")
        }
        if (audioRecorder.isRecording) {
            ttsMicGuardViolations += 1
            Log.e("InterpLoop", "enforceMicStoppedForTts: force-stop fallback, violations=$ttsMicGuardViolations")
            transitionTo(SessionState.Idle)
            audioRecorder.stopRecording()
        }
        val result = !audioRecorder.isRecording
        Log.e("InterpLoop", "enforceMicStoppedForTts: returning $result")
        return result
    }

    internal fun scheduleTranslationUpdate() {
        // Don't cancel an in-flight TTS cycle — the translation job may be executing
        // enforceMicStoppedForTts() or ttsService.speak(). Interrupting it would break
        // the interpretation loop (mic-stop → TTS → resume-mic).
        if (!micStoppedForTts) {
            translationJob?.cancel()
        }

        if (!_translationEnabled.value) {
            resetTranslationState(stopTts = false)
            return
        }

        // Quick-check: skip scheduling if language codes are not configured
        val srcCheck = _translationSourceLanguageCode.value.trim()
        val tgtCheck = _translationTargetLanguageCode.value.trim()
        if (srcCheck.isEmpty() || tgtCheck.isEmpty()) return

        Log.e("InterpLoop", "scheduleTranslationUpdate: $srcCheck→$tgtCheck micStopped=$micStoppedForTts speakTTS=${_speakTranslatedAudio.value}")

        translationJob = scope.launch(Dispatchers.Default) {
            // Debounce: coalesce rapid updates (e.g. during fast speech)
            // so we don't cancel in-flight translations repeatedly.
            delay(150)

            // Re-read after debounce for latest values
            val confirmedSnapshot = _confirmedText.value.trim()
            val hypothesisSnapshot = _hypothesisText.value.trim()
            val sourceLanguageCode = _translationSourceLanguageCode.value.trim().lowercase()
            val targetLanguageCode = _translationTargetLanguageCode.value.trim().lowercase()

            if (sourceLanguageCode.isEmpty() || targetLanguageCode.isEmpty()) return@launch

            val currentInput = confirmedSnapshot to hypothesisSnapshot
            if (lastTranslationInput == currentInput) {
                Log.e("InterpLoop", "scheduleTranslationUpdate: text unchanged, skipping")
                return@launch
            }

            Log.e("InterpLoop", "translating: confirmed='${confirmedSnapshot.take(40)}' hyp='${hypothesisSnapshot.take(40)}' $sourceLanguageCode→$targetLanguageCode")

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
                        translateWithProvider(confirmedSnapshot, sourceLanguageCode, targetLanguageCode)
                    }

                    translatedHypothesis = if (hypothesisSnapshot.isBlank()) {
                        ""
                    } else {
                        translateWithProvider(hypothesisSnapshot, sourceLanguageCode, targetLanguageCode)
                    }
                    Log.e("InterpLoop", "translated: confirmed='${translatedConfirmed.take(40)}' hyp='${translatedHypothesis.take(40)}'")
                } catch (e: UnsupportedOperationException) {
                    translatedConfirmed = confirmedSnapshot
                    translatedHypothesis = hypothesisSnapshot
                    warningMessage = e.message ?: AppError.TranslationUnavailable().message
                    Log.e("InterpLoop", "translation unsupported: ${e.message}")
                } catch (e: Throwable) {
                    if (e is CancellationException) return@launch
                    translatedConfirmed = confirmedSnapshot
                    translatedHypothesis = hypothesisSnapshot
                    warningMessage = AppError.TranslationFailed(e).message
                    Log.e("InterpLoop", "translation failed: ${e.message}")
                }
            }

            _translatedConfirmedText.value = TextNormalizationUtils.normalizeText(translatedConfirmed)
            _translatedHypothesisText.value = TextNormalizationUtils.normalizeText(translatedHypothesis)
            _translationWarning.value = warningMessage
            lastTranslationInput = currentInput

            if (_speakTranslatedAudio.value) {
                Log.e("InterpLoop", "calling speakTranslatedDeltaIfNeeded, translatedConfirmed='${_translatedConfirmedText.value.take(40)}'")
                speakTranslatedDeltaIfNeeded(_translatedConfirmedText.value, targetLanguageCode)
            } else {
                Log.e("InterpLoop", "speakTranslatedAudio is OFF, skipping TTS")
            }
        }
    }

    /** Dispatch translation to the currently selected provider. */
    private suspend fun translateWithProvider(
        text: String,
        sourceLanguageCode: String,
        targetLanguageCode: String
    ): String {
        return when (_translationProvider.value) {
            TranslationProvider.ML_KIT -> mlKitTranslator.translate(text, sourceLanguageCode, targetLanguageCode)
            TranslationProvider.ANDROID_SYSTEM -> androidSystemTranslator.translate(text, sourceLanguageCode, targetLanguageCode)
        }
    }

    private suspend fun speakTranslatedDeltaIfNeeded(translatedConfirmed: String, languageCode: String) {
        val normalized = TextNormalizationUtils.normalizeText(translatedConfirmed)
        if (normalized.isBlank()) {
            Log.e("InterpLoop", "speakDelta: normalized is blank, skipping")
            return
        }

        var delta = normalized
        if (lastSpokenTranslatedConfirmed.isNotBlank() &&
            normalized.startsWith(lastSpokenTranslatedConfirmed)
        ) {
            delta = TextNormalizationUtils.normalizeText(
                normalized.removePrefix(lastSpokenTranslatedConfirmed)
            )
        }

        if (delta.isBlank()) {
            Log.e("InterpLoop", "speakDelta: delta is blank (already spoken), skipping")
            return
        }

        // Skip TTS for very short text (punctuation-only, single chars) to avoid
        // useless tiny utterances that interrupt the interpretation flow.
        val meaningfulChars = delta.count { it.isLetterOrDigit() }
        if (meaningfulChars < 2) {
            Log.e("InterpLoop", "speakDelta: delta too short (meaningfulChars=$meaningfulChars), skipping: '$delta'")
            return
        }

        Log.e("InterpLoop", "speakDelta: delta='${delta.take(40)}' lang=$languageCode, calling enforceMicStoppedForTts")

        if (!enforceMicStoppedForTts()) {
            Log.e("InterpLoop", "speakDelta: enforceMicStoppedForTts FAILED, mic still active")
            applyTranslationWarning(
                "Microphone is still active; skipped TTS playback to avoid feedback loop.",
                stopTts = true
            )
            return
        }

        Log.e("InterpLoop", "speakDelta: mic stopped OK, calling ttsService.speak()")

        try {
            ttsStartCount += 1
            ttsService.speak(
                text = delta,
                languageCode = languageCode,
                rate = _ttsRate.value
            )
            lastSpokenTranslatedConfirmed = normalized
            Log.e("InterpLoop", "speakDelta: ttsService.speak() called, ttsStartCount=$ttsStartCount")
        } catch (e: Throwable) {
            Log.e("InterpLoop", "speakDelta: TTS failed: ${e.message}")
            micStoppedForTts = false  // TTS failed; callback won't fire, so reset manually
            _lastError.value = AppError.TtsFailed(e)
        }
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

        var bitsPerSample = 16
        var channels = 1
        var sampleRate = AudioConstants.SAMPLE_RATE
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
            if (chunkSize % 2 != 0) pos++
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
            val engine = currentEngine
            if (engine != null && engine.isSelfRecording) {
                engine.stopListening()
            } else {
                audioRecorder.stopRecording()
            }
            cancelTranscriptionJob()
            cancelRecorderAndEnergyJobs()
        }
        audioRecorder.clearSystemAudioCapturePermission()
        _systemAudioCaptureReady.value = false
        translationJob?.cancel()
        scope.cancel()
        mlKitTranslator.close()
        androidSystemTranslator.close()
        ttsService.setPlaybackStateListener(null)
        ttsService.shutdown()
        currentEngine?.release()
        currentEngine = null
        prewarmedModelId = null
    }
}
