import Foundation
import WhisperKit
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

    private(set) var whisperKit: WhisperKit?
    private(set) var modelState: ASRModelState = .unloaded
    private(set) var downloadProgress: Double = 0.0
    private(set) var availableModels: [String] = []
    private(set) var currentModelVariant: String?
    private(set) var lastError: AppError?

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

    // Configuration
    var selectedModel: ModelInfo = ModelInfo.defaultModel
    var useVAD: Bool = true
    var silenceThreshold: Float = 0.3
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
    /// Finalized chunk texts, each representing one completed transcription window.
    private var completedChunksText: String = ""
    private var translationTask: Task<Void, Never>?
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
    private static let sampleRate: Float = 16000
    /// Maximum audio chunk duration (seconds). Each chunk is transcribed independently;
    /// when the buffer exceeds this, the current hypothesis is confirmed and a new chunk begins.
    /// 15s matches Android and keeps mobile inference fast (Whisper is O(n) to O(n²) in audio length).
    private static let maxChunkSeconds: Float = 15.0

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
        migrateLegacyModelFolder()
        setupAudioObservers()
        startMetricsSampling()
    }

    deinit {
        // Note: @MainActor deinit is nonisolated in Swift 6, so we cannot access
        // actor-isolated properties here. Task cancellation and engine cleanup
        // happen via stopRecording() / unloadModel() before deallocation.
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

    private func modelFolderKey(for variant: String) -> String {
        "modelFolder_\(variant)"
    }

    private func migrateLegacyModelFolder() {
        let legacyKey = "lastModelFolder"
        guard let legacyFolder = UserDefaults.standard.string(forKey: legacyKey) else { return }

        for model in ModelInfo.availableModels {
            if let variant = model.variant, legacyFolder.contains(variant) {
                let perModelKey = modelFolderKey(for: variant)
                if UserDefaults.standard.string(forKey: perModelKey) == nil {
                    UserDefaults.standard.set(legacyFolder, forKey: perModelKey)
                }
            }
        }
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

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
            modelState = .unloaded
        }
    }

    func fetchAvailableModels() async {
        do {
            let models = try await WhisperKit.fetchAvailableModels(
                from: "argmaxinc/whisperkit-coreml"
            )
            availableModels = models
        } catch {
            lastError = .modelDownloadFailed(underlying: error)
        }
    }

    func setupModel() async {
        let engine = EngineFactory.makeEngine(for: selectedModel)
        activeEngine = engine

        modelState = .downloading
        downloadProgress = 0.0
        lastError = nil

        // Sync download progress from engine in background
        let progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.activeEngine === engine else { break }
                self.downloadProgress = engine.downloadProgress
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
            modelState = .unloaded
            downloadProgress = 0.0
            if let appError = error as? AppError {
                lastError = appError
            } else {
                lastError = .modelLoadFailed(underlying: error)
            }
        }
    }

    func isModelDownloaded(_ model: ModelInfo) -> Bool {
        switch model.engineType {
        case .whisperKit:
            guard let variant = model.variant,
                  let savedFolder = UserDefaults.standard.string(
                      forKey: modelFolderKey(for: variant)
                  ) else {
                return false
            }
            return FileManager.default.fileExists(atPath: savedFolder)
        case .sherpaOnnxOffline, .sherpaOnnxStreaming:
            guard let config = model.sherpaModelConfig else { return false }
            let modelDir = ModelDownloader.modelsDirectory.appendingPathComponent(config.repoName)
            let tokensPath = modelDir.appendingPathComponent(config.tokens)
            return FileManager.default.fileExists(atPath: tokensPath.path)
        case .fluidAudio:
            // FluidAudio manages its own model cache
            return false
        }
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
        whisperKit = nil
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
                // E2E fixture audio is English (JFK sample). Force English to stabilize
                // decoding across multilingual backends (e.g. Whisper, Omnilingual).
                let options = ASRTranscriptionOptions(
                    language: "en",
                    withTimestamps: enableTimestamps
                )
                NSLog("[E2E] Starting transcription with engine \(type(of: engine))...")
                let startTime = CFAbsoluteTimeGetCurrent()
                let result = try await engine.transcribe(audioArray: samples, options: options)
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                guard !Task.isCancelled else { return }
                NSLog("[E2E] Transcription complete: text='\(result.text)', segments=\(result.segments.count)")
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

        if engine.isStreaming {
            transcriptionTask = Task {
                await streamingLoop(engine: engine)
            }
        } else {
            transcriptionTask = Task {
                await offlineLoop(engine: engine)
            }
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

    private func streamingLoop(engine: ASREngine) async {
        while isRecording && isTranscribing && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))

            // Update energy visualization
            bufferEnergy = engine.relativeEnergy
            bufferSeconds = Double(engine.audioSamples.count) / Double(Self.sampleRate)

            // Poll streaming result
            if let result = engine.getStreamingResult() {
                unconfirmedSegments = result.segments
                hypothesisText = normalizedJoinedText(from: result.segments)
                scheduleTranslationUpdate()

                // Endpoint detection → finalize utterance as a new chunk
                if engine.isEndpointDetected() {
                    finalizeCurrentChunk()
                    engine.resetStreamingState()
                }
            }
        }

        if !Task.isCancelled {
            // Capture final result before stopping
            if let result = engine.getStreamingResult(),
               !normalizedJoinedText(from: result.segments).isEmpty {
                unconfirmedSegments = result.segments
                finalizeCurrentChunk()
            }

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

        let effectiveDelay = adaptiveDelay()
        guard nextBufferSeconds > Float(effectiveDelay) else {
            try await Task.sleep(for: .milliseconds(100))
            return
        }

        if useVAD {
            let voiceDetected = isVoiceDetected(
                in: engine.relativeEnergy,
                nextBufferInSeconds: nextBufferSeconds
            )
            if !voiceDetected {
                consecutiveSilenceCount += 1
                lastBufferSize = currentBuffer.count
                return
            }
            consecutiveSilenceCount = 0
        }

        lastBufferSize = currentBuffer.count

        // Update energy visualization
        bufferEnergy = engine.relativeEnergy
        bufferSeconds = Double(currentBuffer.count) / Double(Self.sampleRate)

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

        NSLog("[WhisperService] chunk inference: %.1fs audio in %.2fs (ratio %.1fx, %d words)",
              sliceDurationSeconds, elapsed, Double(sliceDurationSeconds) / elapsed, wordCount)

        processTranscriptionResult(result, sliceOffset: sliceStartSeconds)
    }

    /// Simple voice activity detection using energy levels.
    private func isVoiceDetected(in energy: [Float], nextBufferInSeconds: Float) -> Bool {
        guard !energy.isEmpty else { return false }
        let framesPerSecond: Float = 100
        let windowSize = max(1, Int(nextBufferInSeconds * framesPerSecond))
        let recentEnergy = energy.suffix(windowSize)
        let maxEnergy = recentEnergy.max() ?? 0
        return maxEnergy > silenceThreshold
    }

    private func adaptiveDelay() -> Double {
        if consecutiveSilenceCount > 5 {
            return min(realtimeDelayInterval * 3.0, 3.0)
        } else if consecutiveSilenceCount > 2 {
            return realtimeDelayInterval * 2.0
        }
        return realtimeDelayInterval
    }

    private func processTranscriptionResult(_ result: ASRResult, sliceOffset: Float = 0) {
        let newSegments = result.segments

        if enableEagerMode, !prevUnconfirmedSegments.isEmpty {
            var matchCount = 0
            for (prevSeg, newSeg) in zip(prevUnconfirmedSegments, newSegments) {
                if normalizedSegmentText(prevSeg.text)
                    == normalizedSegmentText(newSeg.text)
                {
                    matchCount += 1
                } else {
                    break
                }
            }

            if matchCount > 0 {
                let newlyConfirmed = Array(newSegments.prefix(matchCount))
                confirmedSegments.append(contentsOf: newlyConfirmed)

                if let lastConfirmed = newlyConfirmed.last {
                    lastConfirmedSegmentEndSeconds = sliceOffset + lastConfirmed.end
                }

                unconfirmedSegments = Array(newSegments.dropFirst(matchCount))
            } else {
                unconfirmedSegments = newSegments
            }
        } else {
            unconfirmedSegments = newSegments
        }

        prevUnconfirmedSegments = unconfirmedSegments

        // Build confirmed text: completed chunks + within-chunk confirmed segments
        let withinChunkConfirmed = normalizedJoinedText(from: confirmedSegments)
        confirmedText = [completedChunksText, withinChunkConfirmed]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        hypothesisText = normalizedJoinedText(from: unconfirmedSegments)
        scheduleTranslationUpdate()
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
        confirmedText = completedChunksText
        hypothesisText = ""
        scheduleTranslationUpdate()
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

    // MARK: - Native Translation / TTS

    private func resetTranslationState(stopTTS: Bool) {
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
                // Fallback when native translation is unavailable:
                // keep UI/TTS functional by reusing source text and surfacing warning inline.
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
        completedChunksText = ""
        bufferEnergy = []
        bufferSeconds = 0
        tokensPerSecond = 0
        prevUnconfirmedSegments = []
        consecutiveSilenceCount = 0
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
