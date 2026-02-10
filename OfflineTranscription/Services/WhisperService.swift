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
        didSet { scheduleTranslationUpdate() }
    }
    var translationTargetLanguageCode: String = "ja" {
        didSet { scheduleTranslationUpdate() }
    }
    var ttsRate: Float = AVSpeechUtteranceDefaultSpeechRate
    var ttsVoiceIdentifier: String?

    // Engine delegation
    private(set) var activeEngine: ASREngine?

    /// The current session's audio samples (for saving to disk).
    var currentAudioSamples: [Float] {
        activeEngine?.audioSamples ?? []
    }

    // Private
    private var transcriptionTask: Task<Void, Never>?
    private var lingeringTranscriptionTask: Task<Void, Never>?
    private var lastBufferSize: Int = 0
    private var lastConfirmedSegmentEndSeconds: Float = 0
    private var prevUnconfirmedSegments: [ASRSegment] = []
    private var consecutiveSilenceCount: Int = 0
    private var hasCompletedFirstInference: Bool = false
    /// EMA-smoothed inference time (seconds) for CPU-aware delay calculation.
    private var movingAverageInferenceSeconds: Double = 0.0
    /// Finalized chunk texts, each representing one completed transcription window.
    private var completedChunksText: String = ""
    private var translationTask: Task<Void, Never>?
    private var lastSpokenTranslatedConfirmed: String = ""
    /// Cache: last input text pair sent for translation (to skip redundant calls).
    private var lastTranslationInput: (confirmed: String, hypothesis: String)?
    private var lastUIMeterUpdateTimestamp: CFAbsoluteTime = 0
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
    private static let sampleRate: Float = 16000
    private static let displayEnergyFrameLimit = 160
    private static let uiMeterUpdateInterval: CFTimeInterval = 0.12

    /// SenseVoice chunk duration: 3.5s for fast updates (single-segment model).
    private static let maxChunkSeconds: Float = 3.5

    // MARK: - Adaptive Delay (CPU-aware, matches Android)
    /// Initial inference gate: show first words quickly (matches Android's 0.35s).
    private static let initialMinNewAudioSeconds: Float = 0.35
    /// Base delay between inferences for sherpa-onnx offline after first decode.
    private static let sherpaBaseDelaySeconds: Float = 0.7
    /// Target inference duty cycle — inference should use at most this fraction of wall time.
    private static let targetInferenceDutyCycle: Float = 0.24
    /// Maximum CPU-protection delay cap.
    private static let maxCpuProtectDelaySeconds: Float = 1.6
    /// EMA smoothing factor for inference time tracking.
    private static let inferenceEmaAlpha: Double = 0.20

    /// Minimum RMS energy to submit audio for inference. Below this, the audio is
    /// near-silence and SenseVoice tends to hallucinate ("I.", "Yeah.", "The.").
    private static let minInferenceRMS: Float = 0.012

    /// Bypass VAD for the first N seconds so initial speech is never dropped.
    private static let initialVADBypassSeconds: Float = 1.0
    /// Keep a pre-roll of audio when VAD says silence, so utterance onsets
    /// that straddle VAD boundaries are not lost.
    private static let vadPrerollSeconds: Float = 0.6

    /// Cancel the active transcription task and keep a handle so we can await
    /// full teardown before starting a new inference session.
    private func cancelAndTrackTranscriptionTask() {
        guard let task = transcriptionTask else { return }
        task.cancel()
        lingeringTranscriptionTask = task
        transcriptionTask = nil
    }

    /// Wait for any previously cancelled transcription task to finish.
    private func drainLingeringTranscriptionTask() async {
        if let activeTask = transcriptionTask {
            activeTask.cancel()
            lingeringTranscriptionTask = activeTask
            transcriptionTask = nil
        }
        if let lingering = lingeringTranscriptionTask {
            _ = await lingering.result
            lingeringTranscriptionTask = nil
        }
    }

    init() {
        if let saved = UserDefaults.standard.string(forKey: selectedModelKey),
           let model = ModelInfo.availableModels.first(where: { $0.variant == saved })
                    ?? ModelInfo.availableModels.first(where: { $0.id == saved })
                    ?? ModelInfo.findByLegacyId(saved) {
            self.selectedModel = model
        }
        ttsService.onPlaybackStateChanged = { [weak self] speaking in
            guard let self else { return }
            self.isSpeakingTTS = speaking
            guard speaking else { return }
            if self.isRecording || self.sessionState == .recording {
                self.ttsMicGuardViolations += 1
                self.stopRecordingForTTSIfNeeded()
            }
        }
        setupAudioObservers()
        startMetricsSampling()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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
                cancelAndTrackTranscriptionTask()
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
                            await self.drainLingeringTranscriptionTask()
                            try await engine.startRecording()
                            isTranscribing = true
                            sessionState = .recording
                            realtimeLoop()
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
        guard let config = model.sherpaModelConfig else { return false }
        let modelDir = ModelDownloader.modelsDirectory.appendingPathComponent(config.repoName)
        let tokensPath = modelDir.appendingPathComponent(config.tokens)
        return FileManager.default.fileExists(atPath: tokensPath.path)
    }

    func switchModel(to model: ModelInfo) async {
        if isRecording {
            stopRecording()
        }

        await drainLingeringTranscriptionTask()

        isRecording = false
        isTranscribing = false
        sessionState = .idle
        cancelAndTrackTranscriptionTask()
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
        await drainLingeringTranscriptionTask()

        guard let engine = activeEngine, engine.modelState == .loaded else {
            sessionState = .idle
            throw AppError.modelNotReady
        }

        resetTranscriptionState()
        ttsService.stop()

        do {
            try await engine.startRecording()
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

        isRecording = true
        isTranscribing = true
        sessionState = .recording

        realtimeLoop()
    }

    func stopRecording() {
        guard sessionState == .recording || sessionState == .interrupted
            || sessionState == .starting else { return }

        sessionState = .stopping
        cancelAndTrackTranscriptionTask()
        translationTask?.cancel()
        translationTask = nil
        activeEngine?.stopRecording()
        ttsService.stop()

        // Finalize any remaining hypothesis text as confirmed so it is
        // included when the user saves the session.
        finalizeCurrentChunk()
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
        cancelAndTrackTranscriptionTask()
        activeEngine?.stopRecording()
        isRecording = false
        isTranscribing = false
        sessionState = .idle
        micStoppedForTTS = true
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

        cancelAndTrackTranscriptionTask()
        transcriptionTask = Task {
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
            "timestamp": ISO8601DateFormatter().string(from: Date()),
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
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
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
        let currentChunkConfirmed = normalizedJoinedText(from: confirmedSegments)
        let currentChunkHypothesis = normalizedJoinedText(from: unconfirmedSegments)
        let currentChunk = [currentChunkConfirmed, currentChunkHypothesis]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let parts = [completedChunksText, currentChunk]
            .filter { !$0.isEmpty }
        return parts.joined(separator: "\n")
    }

    // MARK: - Private: Real-time Loop

    private func realtimeLoop() {
        cancelAndTrackTranscriptionTask()

        guard let engine = activeEngine else { return }

        transcriptionTask = Task {
            await offlineLoop(engine: engine)
        }
    }

    private func offlineLoop(engine: ASREngine) async {
        while isRecording && isTranscribing && !Task.isCancelled {
            do {
                try await transcribeCurrentBuffer(engine: engine)
            } catch {
                if !Task.isCancelled {
                    lastError = .transcriptionFailed(underlying: error)
                }
                break
            }
        }

        if !Task.isCancelled {
            isRecording = false
            isTranscribing = false
            sessionState = .idle
            engine.stopRecording()
        }
    }

    private func transcribeCurrentBuffer(engine: ASREngine) async throws {
        let currentBuffer = engine.audioSamples
        let nextBufferSize = currentBuffer.count - lastBufferSize
        let nextBufferSeconds = Float(nextBufferSize) / Self.sampleRate
        refreshRealtimeMeters(engine: engine)

        let effectiveDelay = adaptiveDelay()
        guard nextBufferSeconds > Float(effectiveDelay) else {
            try await Task.sleep(for: .milliseconds(100))
            return
        }

        if useVAD {
            // Bypass VAD for the first second so initial speech is never dropped
            let vadBypassSamples = Int(Self.sampleRate * Self.initialVADBypassSeconds)
            let bypassVadDuringStartup = !hasCompletedFirstInference && currentBuffer.count <= vadBypassSamples
            if !bypassVadDuringStartup {
                let voiceDetected = isVoiceDetected(
                    in: engine.relativeEnergy,
                    nextBufferInSeconds: nextBufferSeconds
                )
                if !voiceDetected {
                    consecutiveSilenceCount += 1
                    // Keep a pre-roll so utterance onsets straddling VAD are preserved
                    let prerollSamples = Int(Self.sampleRate * Self.vadPrerollSeconds)
                    lastBufferSize = max(currentBuffer.count - prerollSamples, 0)
                    return
                }
                consecutiveSilenceCount = 0
            }
        }

        // Chunk-based windowing: process audio in fixed-size chunks to prevent
        // models from receiving unbounded audio. When the buffer grows past the
        // current chunk boundary, finalize the hypothesis and start a new chunk.
        let bufferEndSeconds = Float(currentBuffer.count) / Self.sampleRate
        var chunkEndSeconds = lastConfirmedSegmentEndSeconds + Self.maxChunkSeconds

        if bufferEndSeconds > chunkEndSeconds {
            finalizeCurrentChunk()
            lastConfirmedSegmentEndSeconds = chunkEndSeconds
            // Recompute for the new chunk so we don't produce an empty slice
            chunkEndSeconds = lastConfirmedSegmentEndSeconds + Self.maxChunkSeconds
        }

        // Slice audio for the current chunk window
        let sliceStartSeconds = lastConfirmedSegmentEndSeconds
        let sliceStartSample = min(Int(sliceStartSeconds * Self.sampleRate), currentBuffer.count)
        let sliceEndSample = min(Int(chunkEndSeconds * Self.sampleRate), currentBuffer.count)
        let audioSamples = Array(currentBuffer[sliceStartSample..<sliceEndSample])
        guard !audioSamples.isEmpty else { return }

        // RMS energy gate: skip inference on near-silence audio to avoid
        // SenseVoice hallucinations ("I.", "Yeah.", "The.") and save CPU.
        // NOTE: lastBufferSize is NOT updated on skip — this ensures that when
        // speech resumes after silence, nextBufferSeconds is already large enough
        // to pass the delay guard immediately, giving near-instant response.
        let sliceRMS = sqrt(audioSamples.reduce(Float(0)) { $0 + $1 * $1 } / Float(audioSamples.count))
        if sliceRMS < Self.minInferenceRMS {
            try await Task.sleep(for: .milliseconds(500))
            return
        }

        lastBufferSize = currentBuffer.count

        let options = ASRTranscriptionOptions(
            withTimestamps: enableTimestamps,
            temperature: 0.0
        )

        let sliceDurationSeconds = Float(audioSamples.count) / Self.sampleRate
        let startTime = CFAbsoluteTimeGetCurrent()
        let result = try await engine.transcribe(audioArray: audioSamples, options: options)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        guard !Task.isCancelled else { return }

        let wordCount = result.text.split(separator: " ").count
        if elapsed > 0 && wordCount > 0 {
            tokensPerSecond = Double(wordCount) / elapsed
        }

        // Track inference time with EMA for CPU-aware delay
        if movingAverageInferenceSeconds <= 0 {
            movingAverageInferenceSeconds = elapsed
        } else {
            movingAverageInferenceSeconds = Self.inferenceEmaAlpha * elapsed
                + (1.0 - Self.inferenceEmaAlpha) * movingAverageInferenceSeconds
        }

        NSLog("[WhisperService] chunk inference: %.1fs audio in %.2fs (ratio %.1fx, %d words, emaInf=%.3fs, delay=%.2fs)",
              sliceDurationSeconds, elapsed, Double(sliceDurationSeconds) / elapsed, wordCount,
              movingAverageInferenceSeconds, adaptiveDelay())

        hasCompletedFirstInference = true
        processTranscriptionResult(result, sliceOffset: sliceStartSeconds)
    }

    /// Voice activity detection using peak + average energy (matches Android).
    private func isVoiceDetected(in energy: [Float], nextBufferInSeconds: Float) -> Bool {
        guard !energy.isEmpty else { return false }
        let recentEnergy = energy.suffix(10)
        let peakEnergy = recentEnergy.max() ?? 0
        let avgEnergy = recentEnergy.reduce(0, +) / Float(recentEnergy.count)
        return peakEnergy >= silenceThreshold || avgEnergy >= silenceThreshold * 0.5
    }

    private func adaptiveDelay() -> Double {
        // During silence, back off to save CPU
        if consecutiveSilenceCount > 5 {
            return min(realtimeDelayInterval * 3.0, 3.0)
        } else if consecutiveSilenceCount > 2 {
            return realtimeDelayInterval * 2.0
        }

        // Fast initial gate: show first words quickly (matches Android 0.35s)
        if !hasCompletedFirstInference {
            return Double(Self.initialMinNewAudioSeconds)
        }

        // CPU-aware delay (matches Android architecture)
        return computeCpuAwareDelay(baseDelay: Double(Self.sherpaBaseDelaySeconds))
    }

    /// Compute delay based on actual inference time to maintain a target CPU duty cycle.
    /// If inference takes 0.17s and target duty is 24%, delay = 0.17/0.24 = 0.71s.
    /// This adapts automatically to device speed — fast devices get shorter delays.
    private func computeCpuAwareDelay(baseDelay: Double) -> Double {
        let avg = movingAverageInferenceSeconds
        guard avg > 0 else { return baseDelay }
        let budgetDelay = avg / Double(Self.targetInferenceDutyCycle)
        return max(baseDelay, min(budgetDelay, Double(Self.maxCpuProtectDelaySeconds)))
    }

    /// Update render-facing meters at a fixed cadence with bounded payload size.
    private func refreshRealtimeMeters(engine: ASREngine, force: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        if !force, now - lastUIMeterUpdateTimestamp < Self.uiMeterUpdateInterval {
            return
        }
        lastUIMeterUpdateTimestamp = now

        let sampleCount = engine.audioSamples.count
        let nextBufferSeconds = Double(sampleCount) / Double(Self.sampleRate)
        if bufferSeconds != nextBufferSeconds {
            bufferSeconds = nextBufferSeconds
        }

        let nextEnergy = Array(engine.relativeEnergy.suffix(Self.displayEnergyFrameLimit))
        if bufferEnergy != nextEnergy {
            bufferEnergy = nextEnergy
        }
    }

    private func processTranscriptionResult(_ result: ASRResult, sliceOffset: Float = 0) {
        let newSegments = result.segments

        // Apply detected language to translation direction
        if let lang = result.language, !lang.isEmpty, lang != detectedLanguage {
            detectedLanguage = lang
            applyDetectedLanguageToTranslation(lang)
        }

        // Eager mode disabled for SenseVoice — single-segment models always return
        // 1 segment whose text changes every cycle, so segment comparison never confirms.
        unconfirmedSegments = newSegments

        prevUnconfirmedSegments = unconfirmedSegments

        // Build confirmed text: completed chunks + within-chunk confirmed segments
        let withinChunkConfirmed = normalizedJoinedText(from: confirmedSegments)
        let nextConfirmedText = [completedChunksText, withinChunkConfirmed]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let nextHypothesisText = normalizedJoinedText(from: unconfirmedSegments)
        let transcriptionChanged = confirmedText != nextConfirmedText || hypothesisText != nextHypothesisText
        if confirmedText != nextConfirmedText {
            confirmedText = nextConfirmedText
        }
        if hypothesisText != nextHypothesisText {
            hypothesisText = nextHypothesisText
        }
        if transcriptionChanged {
            scheduleTranslationUpdate()
        }
    }

    /// Finalize the current chunk: combine all segments into completed text and reset per-chunk state.
    private func finalizeCurrentChunk() {
        let allSegments = confirmedSegments + unconfirmedSegments
        let chunkText = normalizedJoinedText(from: allSegments)
        if !chunkText.isEmpty {
            if completedChunksText.isEmpty {
                completedChunksText = chunkText
            } else {
                completedChunksText += "\n" + chunkText
            }
        }
        confirmedSegments = []
        unconfirmedSegments = []
        prevUnconfirmedSegments = []
        let nextConfirmedText = completedChunksText
        let transcriptionChanged = confirmedText != nextConfirmedText || !hypothesisText.isEmpty
        if confirmedText != nextConfirmedText {
            confirmedText = nextConfirmedText
        }
        if !hypothesisText.isEmpty {
            hypothesisText = ""
        }
        if transcriptionChanged {
            scheduleTranslationUpdate()
        }
    }

    private func normalizedJoinedText(from segments: [ASRSegment]) -> String {
        segments
            .map { normalizedSegmentText($0.text) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func normalizedSegmentText(_ text: String) -> String {
        normalizeDisplayText(text)
    }

    private func normalizeDisplayText(_ text: String) -> String {
        // Normalize whitespace within each line but preserve newlines between chunks
        text
            .components(separatedBy: "\n")
            .map { line in
                line.replacingOccurrences(of: "[^\\S\\n]+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Detected Language → Translation Direction

    /// When the ASR engine detects a language, automatically adjust translation direction.
    /// If detected == current target, swap source↔target (e.g. detected "ja" when target is "ja" → flip).
    /// If detected is neither source nor target, set it as source.
    private func applyDetectedLanguageToTranslation(_ lang: String) {
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
            NSLog("[WhisperService] Detected language '%@' — setting as translation source", lang)
            translationSourceLanguageCode = lang
            resetTranslationState(stopTTS: true)
            scheduleTranslationUpdate()
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

    private func scheduleTranslationUpdate() {
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

        // Skip if text hasn't changed since last translation request.
        if let last = lastTranslationInput,
           last.confirmed == confirmedSnapshot,
           last.hypothesis == hypothesisSnapshot {
            return
        }

        #if targetEnvironment(simulator)
        // iOS Simulator cannot run the native Translation framework pipeline.
        // Keep translation/TTS flows testable by using source text fallback inline.
        let simulatorConfirmed = normalizeDisplayText(confirmedSnapshot)
        let simulatorHypothesis = normalizeDisplayText(hypothesisSnapshot)
        translatedConfirmedText = simulatorConfirmed
        translatedHypothesisText = simulatorHypothesis
        translationWarning = sourceCode.caseInsensitiveCompare(targetCode) == .orderedSame
            ? nil
            : "On-device Translation API is unavailable on iOS Simulator. Using source text fallback."
        lastTranslationInput = (confirmedSnapshot, hypothesisSnapshot)
        speakTranslatedDeltaIfNeeded(from: simulatorConfirmed)
        #else
        if sourceCode.caseInsensitiveCompare(targetCode) == .orderedSame {
            translatedConfirmedText = normalizeDisplayText(confirmedSnapshot)
            translatedHypothesisText = normalizeDisplayText(hypothesisSnapshot)
            translationWarning = nil
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
                self.translatedConfirmedText = self.normalizeDisplayText(confirmedSnapshot)
                self.translatedHypothesisText = self.normalizeDisplayText(hypothesisSnapshot)
                warningMessage = appError.localizedDescription
            } catch {
                guard !Task.isCancelled else { return }
                self.translatedConfirmedText = self.normalizeDisplayText(confirmedSnapshot)
                self.translatedHypothesisText = self.normalizeDisplayText(hypothesisSnapshot)
                warningMessage = AppError.translationFailed(underlying: error).localizedDescription
            }

            self.translationWarning = warningMessage
            self.lastTranslationInput = (confirmedSnapshot, hypothesisSnapshot)
            self.speakTranslatedDeltaIfNeeded(from: self.translatedConfirmedText)
        }
        #endif
    }

    private func speakTranslatedDeltaIfNeeded(from translatedConfirmed: String) {
        guard speakTranslatedAudio else { return }

        let normalized = normalizeDisplayText(translatedConfirmed)
        guard !normalized.isEmpty else { return }

        var delta = normalized
        if !lastSpokenTranslatedConfirmed.isEmpty,
           normalized.hasPrefix(lastSpokenTranslatedConfirmed) {
            delta = normalizeDisplayText(
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
        cancelAndTrackTranscriptionTask()
        resetTranslationState(stopTTS: false)
        lastBufferSize = 0
        lastConfirmedSegmentEndSeconds = 0
        confirmedSegments = []
        unconfirmedSegments = []
        confirmedText = ""
        hypothesisText = ""
        isSpeakingTTS = false
        ttsStartCount = 0
        ttsMicGuardViolations = 0
        micStoppedForTTS = false
        detectedLanguage = nil
        completedChunksText = ""
        bufferEnergy = []
        bufferSeconds = 0
        tokensPerSecond = 0
        prevUnconfirmedSegments = []
        consecutiveSilenceCount = 0
        hasCompletedFirstInference = false
        movingAverageInferenceSeconds = 0.0
        lastUIMeterUpdateTimestamp = 0
        lastError = nil
    }

    // MARK: - Testing Support

    #if DEBUG
    func testFeedResult(_ result: ASRResult) {
        processTranscriptionResult(result)
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
                cancelAndTrackTranscriptionTask()
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
