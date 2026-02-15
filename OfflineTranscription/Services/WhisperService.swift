import Foundation
import Observation
import AVFoundation

/// Session lifecycle states for the recording/transcription pipeline.
enum SessionState: String, Equatable, Sendable {
    case idle          // No active session
    case starting      // Setting up audio, requesting permission
    case recording     // Actively recording and transcribing
    case stopping      // Cleaning up
    case interrupted   // Audio session interrupted (phone call, etc.)
}

/// Download / readiness state for on-device translation models.
enum TranslationModelStatus: Equatable, Sendable {
    case unknown             // Not yet checked
    case checking            // Querying LanguageAvailability
    case downloading         // prepareTranslation() in progress
    case ready               // Models installed, translation available
    case unsupported         // Language pair not supported
    case failed(String)      // Download or preparation error
}

@MainActor
@Observable
final class WhisperService {
    // MARK: - State

    private(set) var modelState: ASRModelState = .unloaded
    private(set) var downloadProgress: Double = 0.0
    private(set) var currentModelVariant: String?
    private(set) var lastError: AppError?
    private(set) var loadingStatusMessage: String = ""

    // Session & transcription state
    private(set) var sessionState: SessionState = .idle
    private(set) var isRecording: Bool = false
    private(set) var isTranscribing: Bool = false
    private(set) var confirmedText: String = ""
    private(set) var hypothesisText: String = ""
    private(set) var confirmedSegments: [ASRSegment] = []
    private(set) var unconfirmedSegments: [ASRSegment] = []
    private(set) var bufferEnergy: [Float] = []
    private(set) var bufferSeconds: Double = 0.0
    private(set) var tokensPerSecond: Double = 0.0
    private(set) var cpuPercent: Double = 0.0
    private(set) var memoryMB: Double = 0.0
    private(set) var translatedConfirmedText: String = ""
    private(set) var translatedHypothesisText: String = ""
    private(set) var translationWarning: String?
    private(set) var translationModelStatus: TranslationModelStatus = .unknown
    private(set) var isSpeakingTTS: Bool = false
    private(set) var ttsStartCount: Int = 0
    private(set) var ttsMicGuardViolations: Int = 0
    private(set) var micStoppedForTTS: Bool = false
    private(set) var detectedLanguage: String?

    // Configuration
    var selectedModel: ModelInfo = ModelInfo.defaultModel
    var useVAD: Bool = true
    var silenceThreshold: Float = 0.0015
    var realtimeDelayInterval: Double = 1.0
    var enableTimestamps: Bool = true
    var enableEagerMode: Bool = true
    var translationEnabled: Bool = true {
        didSet {
            if translationEnabled {
                scheduleTranslationUpdate()
            } else {
                resetTranslationState(stopTTS: true)
            }
        }
    }
    var speakTranslatedAudio: Bool = true {
        didSet {
            if !speakTranslatedAudio {
                ttsService.stop()
                lastSpokenTranslatedConfirmed = ""
            } else {
                speakTranslatedDeltaIfNeeded(from: translatedConfirmedText)
            }
        }
    }
    var translationSourceLanguageCode: String = "en" {
        didSet {
            lastTranslationInput = nil
            scheduleTranslationUpdate()
        }
    }
    var translationTargetLanguageCode: String = "ja" {
        didSet {
            lastTranslationInput = nil
            scheduleTranslationUpdate()
        }
    }
    var ttsRate: Float = AVSpeechUtteranceDefaultSpeechRate
    var ttsVoiceIdentifier: String?

    // Audio capture mode
    var audioCaptureMode: AudioCaptureMode = .microphone

    // Engine delegation
    private(set) var activeEngine: ASREngine?

    /// Coordinates real-time transcription loops, VAD, and chunking.
    private(set) var transcriptionCoordinator: TranscriptionCoordinator!

    /// System audio source for broadcast mode (receives audio from Broadcast Extension).
    private var systemAudioSource: SystemAudioSource?

    /// Whether a ReplayKit broadcast is currently active.
    private(set) var isBroadcastActive = false

    /// The current session's audio samples (for saving to disk).
    var currentAudioSamples: [Float] {
        if audioCaptureMode == .systemBroadcast, let source = systemAudioSource {
            return source.audioSamples
        }
        return activeEngine?.audioSamples ?? []
    }

    /// Audio samples for transcription — uses SystemAudioSource in broadcast mode.
    var effectiveAudioSamples: [Float] {
        if audioCaptureMode == .systemBroadcast, let source = systemAudioSource {
            return source.audioSamples
        }
        return activeEngine?.audioSamples ?? []
    }

    /// Energy levels for VAD / visualization — uses SystemAudioSource in broadcast mode.
    var effectiveRelativeEnergy: [Float] {
        if audioCaptureMode == .systemBroadcast, let source = systemAudioSource {
            return source.relativeEnergy
        }
        return activeEngine?.relativeEnergy ?? []
    }

    // Private
    private var translationTask: Task<Void, Never>?
    #if DEBUG
    private var e2eTask: Task<Void, Never>?
    #endif
    private var lastSpokenTranslatedConfirmed: String = ""
    /// Cache: last input text pair sent for translation (to skip redundant calls).
    private var lastTranslationInput: (confirmed: String, hypothesis: String)?
    private let translationService = AppleTranslationService()
    private let ttsService = NativeTTSService()

    /// Called from TranslationBridgeView when a TranslationSession becomes available/unavailable.
    func setTranslationSession(_ session: Any?) {
        translationService.setSession(session)
        if session == nil {
            translationModelStatus = .unknown
        }
    }

    /// Called from TranslationBridgeView after model availability is confirmed.
    func setTranslationModelStatus(_ status: TranslationModelStatus) {
        translationModelStatus = status
        if status == .ready {
            scheduleTranslationUpdate()
        }
    }

    private let systemMetrics = SystemMetrics()
    private var metricsTask: Task<Void, Never>?
    private let selectedModelKey = "selectedModelVariant"
    private static let sampleRate: Float = AudioConstants.sampleRateFloat
    private static let e2eTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init() {
        self.transcriptionCoordinator = TranscriptionCoordinator(service: self)
        if let saved = UserDefaults.standard.string(forKey: selectedModelKey),
           let model = ModelInfo.availableModels.first(where: { $0.variant == saved })
                    ?? ModelInfo.availableModels.first(where: { $0.id == saved })
                    ?? ModelInfo.findByLegacyId(saved) {
            self.selectedModel = model
        }
        ttsService.onPlaybackStateChanged = { [weak self] speaking in
            guard let self else { return }
            NSLog("[WhisperService] TTS playback state changed: speaking=%@, micStoppedForTTS=%@, sessionState=%@",
                  "\(speaking)", "\(self.micStoppedForTTS)", "\(self.sessionState)")
            self.isSpeakingTTS = speaking
            if speaking {
                if self.isRecording || self.sessionState == .recording {
                    self.ttsMicGuardViolations += 1
                    self.stopRecordingForTTSIfNeeded()
                }
            } else if self.micStoppedForTTS {
                Task { [weak self] in
                    await self?.resumeRecordingAfterTTS()
                }
            }
        }
        setupAudioObservers()
        registerBroadcastNotifications()
        startMetricsSampling()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Broadcast Notifications (ReplayKit IPC)

    private func registerBroadcastNotifications() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()

        let broadcastStartedName = DarwinNotifications.broadcastStarted
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let service = Unmanaged<WhisperService>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in
                    service.handleBroadcastStarted()
                }
            },
            broadcastStartedName,
            nil,
            .deliverImmediately
        )

        let broadcastStoppedName = DarwinNotifications.broadcastStopped
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let service = Unmanaged<WhisperService>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in
                    service.handleBroadcastStopped()
                }
            },
            broadcastStoppedName,
            nil,
            .deliverImmediately
        )
    }

    private func handleBroadcastStarted() {
        NSLog("[WhisperService] Broadcast started notification received (mode=%d, recording=%d, state=%@)",
              audioCaptureMode == .systemBroadcast ? 1 : 0, isRecording ? 1 : 0, sessionState.rawValue)

        isBroadcastActive = true

        guard audioCaptureMode == .systemBroadcast else { return }
        guard !isRecording, sessionState == .idle else { return }
        guard let engine = activeEngine, engine.modelState == .loaded else {
            NSLog("[WhisperService] Broadcast started but engine not ready — skipping auto-record")
            return
        }

        NSLog("[WhisperService] Auto-starting recording for system broadcast")
        Task {
            do {
                try await startRecording()
            } catch {
                NSLog("[WhisperService] Failed to auto-start recording for broadcast: \(error)")
            }
        }
    }

    private func handleBroadcastStopped() {
        NSLog("[WhisperService] Broadcast stopped notification received (recording=%d)", isRecording ? 1 : 0)

        isBroadcastActive = false

        guard audioCaptureMode == .systemBroadcast, isRecording else { return }
        NSLog("[WhisperService] Auto-stopping recording because broadcast ended")
        stopRecording()
    }

    private func startMetricsSampling() {
        metricsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.cpuPercent = self.systemMetrics.cpuPercent()
                self.memoryMB = self.systemMetrics.memoryMB()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - Audio Session Observers

    private func setupAudioObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruptionNotification(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChangeNotification(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    @objc nonisolated private func handleInterruptionNotification(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.handleInterruption(notification)
        }
    }

    @objc nonisolated private func handleRouteChangeNotification(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.handleRouteChange(notification)
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            if isRecording {
                transcriptionCoordinator.cancelAndTrackTranscriptionTask()
                isTranscribing = false
                sessionState = .interrupted
            }
        case .ended:
            if sessionState == .interrupted {
                let options = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options)
                    .contains(.shouldResume)

                if shouldResume, let engine = activeEngine {
                    Task {
                        do {
                            await self.transcriptionCoordinator.drainLingeringTranscriptionTask()
                            if self.audioCaptureMode == .systemBroadcast {
                                let source = SystemAudioSource()
                                self.systemAudioSource = source
                                source.start()
                            } else {
                                try await engine.startRecording(captureMode: self.audioCaptureMode)
                            }
                            isTranscribing = true
                            sessionState = .recording
                            transcriptionCoordinator.startLoop()
                        } catch {
                            NSLog("[WhisperService] Failed to resume recording after interruption: \(error)")
                            stopRecording()
                        }
                    }
                } else {
                    stopRecording()
                }
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }

        switch reason {
        case .oldDeviceUnavailable:
            if isRecording {
                stopRecording()
            }
        default:
            break
        }
    }

    // MARK: - Model Management

    func loadModelIfAvailable() async {
        // Don't overwrite an already-loaded or in-progress engine
        guard activeEngine == nil, modelState == .unloaded else { return }

        let engine = EngineFactory.makeEngine(for: selectedModel)

        guard engine.isModelDownloaded(selectedModel) else { return }

        activeEngine = engine
        modelState = .loading
        lastError = nil

        do {
            try await engine.loadModel(selectedModel)
            // Verify this engine is still the active one (not replaced by switchModel)
            guard activeEngine === engine else { return }
            modelState = engine.modelState
            if let variant = selectedModel.variant {
                currentModelVariant = variant
            }
        } catch {
            guard activeEngine === engine else { return }
            activeEngine = nil
            modelState = .unloaded
        }
    }

    func setupModel() async {
        let engine = EngineFactory.makeEngine(for: selectedModel)
        activeEngine = engine

        modelState = .downloading
        downloadProgress = 0.0
        lastError = nil

        // Sync download progress and status from engine in background
        let progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.activeEngine === engine else { break }
                self.downloadProgress = engine.downloadProgress
                self.loadingStatusMessage = engine.loadingStatusMessage
                let engineState = engine.modelState
                if engineState == .downloaded || engineState == .loading {
                    self.modelState = engineState
                }
            }
        }

        do {
            try await engine.setupModel(selectedModel)
            progressTask.cancel()
            // Verify this engine is still active (not replaced by a concurrent switch)
            guard activeEngine === engine else { return }
            modelState = engine.modelState
            downloadProgress = engine.downloadProgress
            loadingStatusMessage = ""

            // Persist selection
            if let variant = selectedModel.variant {
                currentModelVariant = variant
                UserDefaults.standard.set(variant, forKey: selectedModelKey)
            } else {
                UserDefaults.standard.set(selectedModel.id, forKey: selectedModelKey)
            }
        } catch {
            progressTask.cancel()
            guard activeEngine === engine else { return }
            activeEngine = nil
            modelState = .unloaded
            downloadProgress = 0.0
            loadingStatusMessage = ""
            if let appError = error as? AppError {
                lastError = appError
            } else {
                lastError = .modelLoadFailed(underlying: error)
            }
        }
    }

    func isModelDownloaded(_ model: ModelInfo) -> Bool {
        // Built-in engines (Apple Speech) are always available — no download needed
        if model.engineType == .appleSpeech {
            return true
        }
        guard let config = model.sherpaModelConfig else { return false }
        let modelDir = ModelDownloader.modelsDirectory.appendingPathComponent(config.repoName)
        let tokensPath = modelDir.appendingPathComponent(config.tokens)
        return FileManager.default.fileExists(atPath: tokensPath.path)
    }

    func switchModel(to model: ModelInfo) async {
        if isRecording {
            stopRecording()
        }

        await transcriptionCoordinator.drainLingeringTranscriptionTask()

        isRecording = false
        isTranscribing = false
        sessionState = .idle
        transcriptionCoordinator.cancelAndTrackTranscriptionTask()
        translationTask?.cancel()
        translationTask = nil

        // Unload current engine
        if let engine = activeEngine {
            await engine.unloadModel()
        }
        activeEngine = nil
        modelState = .unloaded
        selectedModel = model
        await setupModel()
    }

    // MARK: - Recording & Transcription

    func startRecording() async throws {
        guard sessionState == .idle else { return }

        sessionState = .starting
        await transcriptionCoordinator.drainLingeringTranscriptionTask()

        guard let engine = activeEngine, engine.modelState == .loaded else {
            sessionState = .idle
            throw AppError.modelNotReady
        }

        resetTranscriptionState()
        ttsService.stop()

        if audioCaptureMode == .systemBroadcast {
            // Use SystemAudioSource instead of engine's AudioRecorder
            let source = SystemAudioSource()
            systemAudioSource = source
            source.start()
        } else {
            systemAudioSource = nil
            do {
                try await engine.startRecording(captureMode: audioCaptureMode)
            } catch {
                isRecording = false
                isTranscribing = false
                sessionState = .idle
                if let appError = error as? AppError {
                    lastError = appError
                } else {
                    lastError = .audioSessionSetupFailed(underlying: error)
                }
                throw error
            }
        }

        isRecording = true
        isTranscribing = true
        sessionState = .recording

        transcriptionCoordinator.startLoop()
    }

    func stopRecording() {
        guard sessionState == .recording || sessionState == .interrupted
            || sessionState == .starting else { return }

        sessionState = .stopping
        transcriptionCoordinator.cancelAndTrackTranscriptionTask()
        translationTask?.cancel()
        translationTask = nil

        // Signal broadcast extension to stop BEFORE releasing the ring buffer.
        // Uses shared memory flag (checked every 200ms via timer in SampleHandler)
        // plus Darwin notification as backup.
        if audioCaptureMode == .systemBroadcast && isBroadcastActive {
            if let ringBuf = SharedAudioRingBuffer(isProducer: false) {
                ringBuf.setRequestStop(true)
                NSLog("[WhisperService] Set requestStop flag in shared ring buffer")
            }
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            CFNotificationCenterPostNotification(
                center,
                DarwinNotifications.stopBroadcast,
                nil, nil, true
            )
        }

        systemAudioSource?.stop()
        systemAudioSource = nil
        activeEngine?.stopRecording()
        ttsService.stop()

        // Finalize any remaining hypothesis text as confirmed so it is
        // included when the user saves the session.
        transcriptionCoordinator.finalizeCurrentChunk()
        NSLog("[WhisperService] stopRecording: finalized text='\(confirmedText.prefix(80))' audio=\(currentAudioSamples.count) samples")

        isRecording = false
        isTranscribing = false
        sessionState = .idle
    }

    private func stopRecordingForTTSIfNeeded() {
        guard sessionState == .recording
            || sessionState == .interrupted
            || sessionState == .starting
            || isRecording
            || isTranscribing else { return }

        sessionState = .stopping
        transcriptionCoordinator.cancelAndTrackTranscriptionTask()
        systemAudioSource?.stop()
        systemAudioSource = nil
        activeEngine?.stopRecording()
        isRecording = false
        isTranscribing = false
        sessionState = .idle
        micStoppedForTTS = true
    }

    /// Resume recording immediately after TTS finishes, without resetting transcription state.
    private func resumeRecordingAfterTTS() async {
        guard micStoppedForTTS else { return }
        micStoppedForTTS = false

        guard sessionState == .idle else {
            NSLog("[WhisperService] Skipping TTS resume — session not idle (state=%@)", "\(sessionState)")
            return
        }
        guard let engine = activeEngine, engine.modelState == .loaded else { return }

        NSLog("[WhisperService] Resuming recording after TTS playback")

        // Drain any lingering transcription task to avoid concurrent inference
        await transcriptionCoordinator.drainLingeringTranscriptionTask()

        // Re-check state after awaiting — user may have acted while we drained
        guard sessionState == .idle else {
            NSLog("[WhisperService] Skipping TTS resume — session changed during drain (state=%@)", "\(sessionState)")
            return
        }

        // Reset audio buffer tracking for fresh engine buffer
        transcriptionCoordinator.resetBufferTracking()

        // Clear transcription + translation text for fresh interpretation segment.
        transcriptionCoordinator.clearCompletedChunks()
        confirmedSegments = []
        unconfirmedSegments = []
        confirmedText = ""
        hypothesisText = ""
        translatedConfirmedText = ""
        translatedHypothesisText = ""
        lastTranslationInput = nil
        lastSpokenTranslatedConfirmed = ""
        NSLog("[WhisperService] Cleared text state for fresh interpretation segment")

        do {
            if audioCaptureMode == .systemBroadcast {
                let source = SystemAudioSource()
                systemAudioSource = source
                source.start()
            } else {
                try await engine.startRecording(captureMode: audioCaptureMode)
            }
        } catch {
            NSLog("[WhisperService] Failed to resume recording after TTS: \(error)")
            lastError = .audioSessionSetupFailed(underlying: error)
            return
        }

        isRecording = true
        isTranscribing = true
        sessionState = .recording

        transcriptionCoordinator.startLoop()
    }

    func clearTranscription() {
        stopRecording()
        resetTranscriptionState()
    }

    func clearLastError() {
        lastError = nil
    }

    #if DEBUG
    /// Transcribe a WAV file from the given path (for testing / E2E validation).
    func transcribeTestFile(_ path: String) {
        NSLog("[E2E] transcribeTestFile called, path=\(path)")
        NSLog("[E2E] activeEngine=\(String(describing: activeEngine)), modelState=\(String(describing: activeEngine?.modelState))")
        guard let engine = activeEngine, engine.modelState == .loaded else {
            NSLog("[E2E] ERROR: model not ready, activeEngine=\(String(describing: activeEngine))")
            lastError = .modelNotReady
            return
        }

        resetTranscriptionState()

        transcriptionCoordinator.cancelAndTrackTranscriptionTask()
        e2eTask = Task {
            do {
                NSLog("[E2E] Loading WAV file...")
                let samples = try Self.loadWavFile(path: path)
                let audioDuration = Double(samples.count) / Double(Self.sampleRate)
                NSLog("[E2E] WAV loaded: \(samples.count) samples (\(audioDuration)s)")
                self.bufferSeconds = audioDuration
                let options = ASRTranscriptionOptions(
                    language: "en",
                    withTimestamps: enableTimestamps
                )
                NSLog("[E2E] Starting transcription with engine \(type(of: engine))...")
                let startTime = CFAbsoluteTimeGetCurrent()
                let result = try await engine.transcribe(audioArray: samples, options: options)
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                guard !Task.isCancelled else { return }
                NSLog("[E2E] Transcription complete: text='\(result.text)', segments=\(result.segments.count), language=\(result.language ?? "nil")")
                if let lang = result.language, !lang.isEmpty, lang != detectedLanguage {
                    detectedLanguage = lang
                    applyDetectedLanguageToTranslation(lang)
                }
                confirmedSegments = result.segments
                confirmedText = result.segments.map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                NSLog("[E2E] confirmedText set to: '\(confirmedText)'")
                scheduleTranslationUpdate()
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline {
                    let translatedReady = !translationEnabled
                        || confirmedText.isEmpty
                        || !translatedConfirmedText.isEmpty
                    let ttsReady = !speakTranslatedAudio
                        || translatedConfirmedText.isEmpty
                        || ttsService.latestEvidenceFilePath() != nil
                    if translatedReady && ttsReady { break }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                writeE2EResult(
                    transcript: confirmedText,
                    translatedText: translatedConfirmedText,
                    durationMs: elapsedMs,
                    error: nil
                )
            } catch {
                guard !Task.isCancelled else { return }
                NSLog("[E2E] ERROR: transcription failed: \(error)")
                lastError = .transcriptionFailed(underlying: error)
                writeE2EResult(
                    transcript: "",
                    translatedText: "",
                    durationMs: 0,
                    error: error.localizedDescription
                )
            }
        }
    }

    private func writeE2EResult(
        transcript: String,
        translatedText: String,
        durationMs: Double,
        error: String?
    ) {
        let keywords = ["country", "ask", "do for"]
        let lower = transcript.lowercased()
        let normalizedSource = translationSourceLanguageCode.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedTarget = translationTargetLanguageCode.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let expectsTranslation = translationEnabled
            && !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !normalizedSource.isEmpty
            && !normalizedTarget.isEmpty
            && normalizedSource != normalizedTarget
        let translationReady = !expectsTranslation
            || !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let expectsTTSEvidence = speakTranslatedAudio && expectsTranslation
        let ttsAudioPath = ttsService.latestEvidenceFilePath()
        let ttsReady = !expectsTTSEvidence || (ttsAudioPath != nil)

        // pass = core transcription quality only; translation/TTS tracked separately
        let pass = error == nil
            && !transcript.isEmpty
            && keywords.contains { lower.contains($0) }
            && ttsMicGuardViolations == 0
        let payload: [String: Any?] = [
            "model_id": selectedModel.id,
            "engine": selectedModel.inferenceMethodLabel,
            "transcript": transcript,
            "translated_text": translatedText,
            "translation_warning": translationWarning,
            "expects_translation": expectsTranslation,
            "translation_ready": translationReady,
            "tts_audio_path": ttsAudioPath,
            "expects_tts_evidence": expectsTTSEvidence,
            "tts_ready": ttsReady,
            "tts_start_count": ttsStartCount,
            "tts_mic_guard_violations": ttsMicGuardViolations,
            "mic_stopped_for_tts": micStoppedForTTS,
            "pass": pass,
            "duration_ms": durationMs,
            "timestamp": Self.e2eTimestampFormatter.string(from: Date()),
            "error": error
        ]

        do {
            let data = try JSONSerialization.data(
                withJSONObject: payload.compactMapValues { $0 },
                options: [.prettyPrinted]
            )
            let modelId = selectedModel.id
            let fileURL = URL(fileURLWithPath: "/tmp/e2e_result_\(modelId).json")
            try data.write(to: fileURL, options: .atomic)
            NSLog("[E2E] Result written to \(fileURL.path)")
        } catch {
            NSLog("[E2E] Failed to write result file: \(error)")
        }
    }

    /// Load a 16kHz mono WAV file and return normalized Float samples in [-1, 1].
    private static func loadWavFile(path: String) throws -> [Float] {
        let url = URL(fileURLWithPath: path)
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioConstants.sampleRate, channels: 1, interleaved: false)!
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "WhisperService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer"])
        }
        try file.read(into: buffer)
        guard let floatData = buffer.floatChannelData else {
            throw NSError(domain: "WhisperService", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "No float channel data"])
        }
        return Array(UnsafeBufferPointer(start: floatData[0], count: Int(buffer.frameLength)))
    }
    #endif

    var fullTranscriptionText: String {
        transcriptionCoordinator.assembleFullText(
            confirmedSegments: confirmedSegments,
            unconfirmedSegments: unconfirmedSegments
        )
    }

    // MARK: - Internal API (for TranscriptionCoordinator)

    func updateTranscriptionText(confirmed: String, hypothesis: String) {
        if confirmedText != confirmed { confirmedText = confirmed }
        if hypothesisText != hypothesis { hypothesisText = hypothesis }
    }

    func updateSegments(confirmed: [ASRSegment], unconfirmed: [ASRSegment]) {
        confirmedSegments = confirmed
        unconfirmedSegments = unconfirmed
    }

    func updateUnconfirmedSegments(_ segments: [ASRSegment]) {
        unconfirmedSegments = segments
    }

    func updateMeters(energy: [Float], bufferSeconds seconds: Double) {
        if bufferEnergy != energy { bufferEnergy = energy }
        if bufferSeconds != seconds { bufferSeconds = seconds }
    }

    func updateTokensPerSecond(_ value: Double) {
        tokensPerSecond = value
    }

    func updateDetectedLanguage(_ lang: String) {
        detectedLanguage = lang
    }

    func updateLastError(_ error: AppError) {
        lastError = error
    }

    /// Called by TranscriptionCoordinator when the inference loop exits naturally.
    func endTranscriptionLoop() {
        isRecording = false
        isTranscribing = false
        sessionState = .idle
        systemAudioSource?.stop()
        systemAudioSource = nil
        activeEngine?.stopRecording()
    }

    // MARK: - Detected Language → Translation Direction

    /// When the ASR engine detects a language, automatically adjust translation direction.
    /// If detected == current target, swap source↔target (e.g. detected "ja" when target is "ja" → flip).
    /// If detected is outside the configured pair, ignore it to preserve the pair.
    func applyDetectedLanguageToTranslation(_ lang: String) {
        guard translationEnabled else { return }
        let currentSource = translationSourceLanguageCode
        let currentTarget = translationTargetLanguageCode

        if lang == currentTarget && lang != currentSource {
            NSLog("[WhisperService] Detected language '%@' matches target — swapping translation direction", lang)
            translationSourceLanguageCode = currentTarget
            translationTargetLanguageCode = currentSource
            resetTranslationState(stopTTS: true)
            scheduleTranslationUpdate()
        } else if lang != currentSource && lang != currentTarget {
            NSLog("[WhisperService] Detected language '%@' not in pair (%@→%@) — ignoring", lang, currentSource, currentTarget)
        }
    }

    // MARK: - Native Translation / TTS

    private func resetTranslationState(stopTTS: Bool = false) {
        translationTask?.cancel()
        translationTask = nil
        translatedConfirmedText = ""
        translatedHypothesisText = ""
        translationWarning = nil
        lastSpokenTranslatedConfirmed = ""
        lastTranslationInput = nil
        if stopTTS {
            ttsService.stop()
        }
    }

    private func applyTranslationWarning(
        _ warning: String,
        stopTTS: Bool = false,
        resetSpokenCache: Bool = false
    ) {
        translationWarning = warning
        if resetSpokenCache {
            lastSpokenTranslatedConfirmed = ""
        }
        if stopTTS {
            ttsService.stop()
        }
    }

    @discardableResult
    private func enforceMicStoppedForTTS() -> Bool {
        stopRecordingForTTSIfNeeded()

        if isRecording || isTranscribing || sessionState == .recording || sessionState == .starting
            || sessionState == .interrupted
        {
            ttsMicGuardViolations += 1
            activeEngine?.stopRecording()
            isRecording = false
            isTranscribing = false
            sessionState = .idle
            micStoppedForTTS = true
        }

        return !(isRecording || isTranscribing || sessionState == .recording
            || sessionState == .starting || sessionState == .interrupted)
    }

    func scheduleTranslationUpdate() {
        translationTask?.cancel()

        guard translationEnabled else {
            resetTranslationState(stopTTS: false)
            return
        }

        let sourceCode = translationSourceLanguageCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetCode = translationTargetLanguageCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceCode.isEmpty, !targetCode.isEmpty else { return }

        let confirmedSnapshot = confirmedText
        let hypothesisSnapshot = hypothesisText

        // Skip if text AND language pair haven't changed since last translation request.
        if let last = lastTranslationInput,
           last.confirmed == confirmedSnapshot,
           last.hypothesis == hypothesisSnapshot {
            return
        }

        NSLog("[WhisperService] scheduleTranslationUpdate: %@→%@ hasSession=%@ modelStatus=%@ textLen=%d",
              sourceCode, targetCode,
              translationService.hasSession ? "YES" : "NO",
              String(describing: translationModelStatus),
              confirmedSnapshot.count + hypothesisSnapshot.count)

        #if targetEnvironment(simulator)
        // iOS Simulator cannot run the native Translation framework pipeline.
        // Keep translation/TTS flows testable by using source text fallback inline.
        let simulatorConfirmed = transcriptionCoordinator.normalizeDisplayText(confirmedSnapshot)
        let simulatorHypothesis = transcriptionCoordinator.normalizeDisplayText(hypothesisSnapshot)
        applyTranslationFallback(
            confirmed: simulatorConfirmed,
            hypothesis: simulatorHypothesis,
            warning: sourceCode.caseInsensitiveCompare(targetCode) == .orderedSame
                ? nil
                : "On-device Translation API is unavailable on iOS Simulator. Using source text fallback."
        )
        lastTranslationInput = (confirmedSnapshot, hypothesisSnapshot)
        speakTranslatedDeltaIfNeeded(from: simulatorConfirmed)
        #else
        if sourceCode.caseInsensitiveCompare(targetCode) == .orderedSame {
            applyTranslationFallback(
                confirmed: transcriptionCoordinator.normalizeDisplayText(confirmedSnapshot),
                hypothesis: transcriptionCoordinator.normalizeDisplayText(hypothesisSnapshot),
                warning: nil
            )
            lastTranslationInput = (confirmedSnapshot, hypothesisSnapshot)
            speakTranslatedDeltaIfNeeded(from: translatedConfirmedText)
            return
        }

        translationTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }

            var warningMessage: String?

            do {
                async let confirmedTranslated = self.translationService.translate(
                    text: confirmedSnapshot,
                    sourceLanguageCode: sourceCode,
                    targetLanguageCode: targetCode
                )
                async let hypothesisTranslated = self.translationService.translate(
                    text: hypothesisSnapshot,
                    sourceLanguageCode: sourceCode,
                    targetLanguageCode: targetCode
                )

                let translatedConfirmed = try await confirmedTranslated
                let translatedHypothesis = try await hypothesisTranslated
                guard !Task.isCancelled else { return }

                self.translatedConfirmedText = translatedConfirmed
                self.translatedHypothesisText = translatedHypothesis
            } catch let appError as AppError {
                guard !Task.isCancelled else { return }
                NSLog("[WhisperService] Translation failed (AppError): %@", appError.localizedDescription)
                warningMessage = appError.localizedDescription
                self.applyTranslationFallback(
                    confirmed: self.transcriptionCoordinator.normalizeDisplayText(confirmedSnapshot),
                    hypothesis: self.transcriptionCoordinator.normalizeDisplayText(hypothesisSnapshot),
                    warning: warningMessage
                )
            } catch {
                guard !Task.isCancelled else { return }
                NSLog("[WhisperService] Translation failed: %@", error.localizedDescription)
                warningMessage = AppError.translationFailed(underlying: error).localizedDescription
                self.applyTranslationFallback(
                    confirmed: self.transcriptionCoordinator.normalizeDisplayText(confirmedSnapshot),
                    hypothesis: self.transcriptionCoordinator.normalizeDisplayText(hypothesisSnapshot),
                    warning: warningMessage
                )
            }

            self.translationWarning = warningMessage
            self.lastTranslationInput = (confirmedSnapshot, hypothesisSnapshot)
            self.speakTranslatedDeltaIfNeeded(from: self.translatedConfirmedText)
        }
        #endif
    }

    private func applyTranslationFallback(confirmed: String, hypothesis: String, warning: String?) {
        translatedConfirmedText = confirmed
        translatedHypothesisText = hypothesis
        translationWarning = warning
    }

    private func speakTranslatedDeltaIfNeeded(from translatedConfirmed: String) {
        guard speakTranslatedAudio else { return }

        let normalized = transcriptionCoordinator.normalizeDisplayText(translatedConfirmed)
        guard !normalized.isEmpty else { return }

        var delta = normalized
        if !lastSpokenTranslatedConfirmed.isEmpty,
           normalized.hasPrefix(lastSpokenTranslatedConfirmed) {
            delta = transcriptionCoordinator.normalizeDisplayText(
                String(normalized.dropFirst(lastSpokenTranslatedConfirmed.count))
            )
        }

        guard !delta.isEmpty else { return }

        guard enforceMicStoppedForTTS() else {
            applyTranslationWarning(
                "Microphone is still active; skipped TTS playback to avoid feedback loop.",
                stopTTS: true
            )
            return
        }

        ttsStartCount += 1
        ttsService.speak(
            text: delta,
            languageCode: translationTargetLanguageCode,
            rate: ttsRate,
            voiceIdentifier: ttsVoiceIdentifier
        )
        lastSpokenTranslatedConfirmed = normalized
    }

    private func resetTranscriptionState() {
        transcriptionCoordinator.reset()
        resetTranslationState(stopTTS: false)
        confirmedSegments = []
        unconfirmedSegments = []
        confirmedText = ""
        hypothesisText = ""
        isSpeakingTTS = false
        ttsStartCount = 0
        ttsMicGuardViolations = 0
        micStoppedForTTS = false
        detectedLanguage = nil
        bufferEnergy = []
        bufferSeconds = 0
        tokensPerSecond = 0
        lastError = nil
    }

    // MARK: - Testing Support

    #if DEBUG
    func testFeedResult(_ result: ASRResult) {
        transcriptionCoordinator.processTranscriptionResult(result)
    }

    func testSetState(
        confirmedText: String = "",
        hypothesisText: String = "",
        confirmedSegments: [ASRSegment] = [],
        unconfirmedSegments: [ASRSegment] = []
    ) {
        self.confirmedText = confirmedText
        self.hypothesisText = hypothesisText
        self.confirmedSegments = confirmedSegments
        self.unconfirmedSegments = unconfirmedSegments
    }

    func testSetSessionState(_ state: SessionState) {
        self.sessionState = state
    }

    func testSetRecordingFlags(isRecording: Bool, isTranscribing: Bool) {
        self.isRecording = isRecording
        self.isTranscribing = isTranscribing
    }

    func testStopRecordingForTTSIfNeeded() {
        stopRecordingForTTSIfNeeded()
    }

    func testSimulateInterruption(began: Bool) {
        if began {
            if isRecording {
                transcriptionCoordinator.cancelAndTrackTranscriptionTask()
                isTranscribing = false
                sessionState = .interrupted
            }
        } else {
            if sessionState == .interrupted {
                stopRecording()
            }
        }
    }
    #endif
}
