import Foundation

/// Coordinates real-time transcription: inference loop, VAD, chunking, and text assembly.
///
/// Extracted from WhisperService to isolate inference loop state and logic.
/// Owns buffer tracking, silence detection, and chunk management internally.
/// Delegates observable state updates back to WhisperService via internal mutation methods.
@MainActor
final class TranscriptionCoordinator {

    // MARK: - Internal State

    private(set) var transcriptionTask: Task<Void, Never>?
    private var lingeringTranscriptionTask: Task<Void, Never>?
    private var lastBufferSize: Int = 0
    private var lastConfirmedSegmentEndSeconds: Float = 0
    private var prevUnconfirmedSegments: [ASRSegment] = []
    private var consecutiveSilenceCount: Int = 0
    private var hasCompletedFirstInference: Bool = false
    private var movingAverageInferenceSeconds: Double = 0.0
    private(set) var completedChunksText: String = ""
    private var lastUIMeterUpdateTimestamp: CFAbsoluteTime = 0

    // MARK: - Constants

    private static let sampleRate: Float = AudioConstants.sampleRateFloat
    private static let displayEnergyFrameLimit = 160
    private static let uiMeterUpdateInterval: CFTimeInterval = 0.12
    private static let inlineWhitespaceRegex: NSRegularExpression = {
        return try! NSRegularExpression(pattern: "[^\\S\\n]+")
    }()

    /// SenseVoice chunk duration: 5s for natural turn-taking.
    private static let maxChunkSeconds: Float = 5.0
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
    /// Minimum RMS energy to submit audio for inference.
    private static let minInferenceRMS: Float = 0.012
    /// Bypass VAD for the first N seconds so initial speech is never dropped.
    private static let initialVADBypassSeconds: Float = 1.0
    /// Keep a pre-roll of audio when VAD says silence, so utterance onsets
    /// that straddle VAD boundaries are not lost.
    private static let vadPrerollSeconds: Float = 0.6

    // MARK: - Service Reference

    private unowned let service: WhisperService

    init(service: WhisperService) {
        self.service = service
    }

    // MARK: - Task Management

    func cancelAndTrackTranscriptionTask() {
        guard let task = transcriptionTask else { return }
        task.cancel()
        lingeringTranscriptionTask = task
        transcriptionTask = nil
    }

    func drainLingeringTranscriptionTask() async {
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

    // MARK: - Real-time Loop

    func startLoop() {
        cancelAndTrackTranscriptionTask()
        guard let engine = service.activeEngine else { return }
        transcriptionTask = Task {
            await offlineLoop(engine: engine)
        }
    }

    private func offlineLoop(engine: ASREngine) async {
        while service.isRecording && service.isTranscribing && !Task.isCancelled {
            do {
                try await transcribeCurrentBuffer(engine: engine)
            } catch {
                if !Task.isCancelled {
                    service.updateLastError(.transcriptionFailed(underlying: error))
                }
                break
            }
        }

        if !Task.isCancelled {
            service.endTranscriptionLoop()
        }
    }

    private func transcribeCurrentBuffer(engine: ASREngine) async throws {
        let currentBuffer = service.effectiveAudioSamples
        let nextBufferSize = currentBuffer.count - lastBufferSize
        let nextBufferSeconds = Float(nextBufferSize) / Self.sampleRate
        refreshRealtimeMeters(engine: engine)

        let effectiveDelay = adaptiveDelay()
        guard nextBufferSeconds > Float(effectiveDelay) else {
            try await Task.sleep(for: .milliseconds(100))
            return
        }

        // Bypass VAD for broadcast mode — continuous audio, not voice-triggered
        if service.useVAD && service.audioCaptureMode != .systemBroadcast {
            let vadBypassSamples = Int(Self.sampleRate * Self.initialVADBypassSeconds)
            let bypassVadDuringStartup = !hasCompletedFirstInference && currentBuffer.count <= vadBypassSamples
            if !bypassVadDuringStartup {
                let voiceDetected = isVoiceDetected(
                    in: service.effectiveRelativeEnergy,
                    nextBufferInSeconds: nextBufferSeconds
                )
                if !voiceDetected {
                    consecutiveSilenceCount += 1
                    let prerollSamples = Int(Self.sampleRate * Self.vadPrerollSeconds)
                    lastBufferSize = max(currentBuffer.count - prerollSamples, 0)
                    return
                }
                consecutiveSilenceCount = 0
            }
        }

        // Chunk-based windowing
        let bufferEndSeconds = Float(currentBuffer.count) / Self.sampleRate
        var chunkEndSeconds = lastConfirmedSegmentEndSeconds + Self.maxChunkSeconds

        if bufferEndSeconds > chunkEndSeconds {
            finalizeCurrentChunk()
            lastConfirmedSegmentEndSeconds = chunkEndSeconds
            chunkEndSeconds = lastConfirmedSegmentEndSeconds + Self.maxChunkSeconds
        }

        // Slice audio for the current chunk window
        let sliceStartSeconds = lastConfirmedSegmentEndSeconds
        let sliceStartSample = min(Int(sliceStartSeconds * Self.sampleRate), currentBuffer.count)
        let sliceEndSample = min(Int(chunkEndSeconds * Self.sampleRate), currentBuffer.count)
        let audioSamples = Array(currentBuffer[sliceStartSample..<sliceEndSample])
        guard !audioSamples.isEmpty else { return }

        // RMS energy gate: skip inference on near-silence to avoid hallucinations
        let sliceRMS = sqrt(audioSamples.reduce(Float(0)) { $0 + $1 * $1 } / Float(audioSamples.count))
        if sliceRMS < Self.minInferenceRMS {
            try await Task.sleep(for: .milliseconds(500))
            return
        }

        lastBufferSize = currentBuffer.count

        let options = ASRTranscriptionOptions(
            withTimestamps: service.enableTimestamps,
            temperature: 0.0
        )

        let sliceDurationSeconds = Float(audioSamples.count) / Self.sampleRate
        let startTime = CFAbsoluteTimeGetCurrent()
        let result = try await engine.transcribe(audioArray: audioSamples, options: options)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        guard !Task.isCancelled else { return }

        let wordCount = result.text.split(separator: " ").count
        if elapsed > 0 && wordCount > 0 {
            service.updateTokensPerSecond(Double(wordCount) / elapsed)
        }

        // Track inference time with EMA for CPU-aware delay
        if movingAverageInferenceSeconds <= 0 {
            movingAverageInferenceSeconds = elapsed
        } else {
            movingAverageInferenceSeconds = Self.inferenceEmaAlpha * elapsed
                + (1.0 - Self.inferenceEmaAlpha) * movingAverageInferenceSeconds
        }

        NSLog("[TranscriptionCoordinator] chunk: %.1fs audio in %.2fs (%.1fx, %d words, emaInf=%.3fs, delay=%.2fs)",
              sliceDurationSeconds, elapsed, Double(sliceDurationSeconds) / elapsed, wordCount,
              movingAverageInferenceSeconds, adaptiveDelay())

        hasCompletedFirstInference = true
        processTranscriptionResult(result, sliceOffset: sliceStartSeconds)
    }

    // MARK: - VAD & Delay

    private func isVoiceDetected(in energy: [Float], nextBufferInSeconds: Float) -> Bool {
        guard !energy.isEmpty else { return false }
        let recentEnergy = energy.suffix(10)
        let peakEnergy = recentEnergy.max() ?? 0
        let avgEnergy = recentEnergy.reduce(0, +) / Float(recentEnergy.count)
        return peakEnergy >= service.silenceThreshold || avgEnergy >= service.silenceThreshold * 0.5
    }

    private func adaptiveDelay() -> Double {
        if consecutiveSilenceCount > 5 {
            return min(service.realtimeDelayInterval * 3.0, 3.0)
        } else if consecutiveSilenceCount > 2 {
            return service.realtimeDelayInterval * 2.0
        }

        if !hasCompletedFirstInference {
            return Double(Self.initialMinNewAudioSeconds)
        }

        return computeCpuAwareDelay(baseDelay: Double(Self.sherpaBaseDelaySeconds))
    }

    private func computeCpuAwareDelay(baseDelay: Double) -> Double {
        let avg = movingAverageInferenceSeconds
        guard avg > 0 else { return baseDelay }
        let budgetDelay = avg / Double(Self.targetInferenceDutyCycle)
        return max(baseDelay, min(budgetDelay, Double(Self.maxCpuProtectDelaySeconds)))
    }

    // MARK: - Meters & Results

    private func refreshRealtimeMeters(engine: ASREngine, force: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        if !force, now - lastUIMeterUpdateTimestamp < Self.uiMeterUpdateInterval { return }
        lastUIMeterUpdateTimestamp = now

        let sampleCount = service.effectiveAudioSamples.count
        let nextBufferSeconds = Double(sampleCount) / Double(Self.sampleRate)
        let nextEnergy = Array(service.effectiveRelativeEnergy.suffix(Self.displayEnergyFrameLimit))
        service.updateMeters(energy: nextEnergy, bufferSeconds: nextBufferSeconds)
    }

    func processTranscriptionResult(_ result: ASRResult, sliceOffset: Float = 0) {
        let newSegments = result.segments

        if let lang = result.language, !lang.isEmpty, lang != service.detectedLanguage {
            service.updateDetectedLanguage(lang)
            service.applyDetectedLanguageToTranslation(lang)
        }

        service.updateUnconfirmedSegments(newSegments)
        prevUnconfirmedSegments = newSegments

        // Build text from completed chunks + current chunk segments
        let withinChunkConfirmed = normalizedJoinedText(from: service.confirmedSegments)
        let nextConfirmedText = [completedChunksText, withinChunkConfirmed]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let nextHypothesisText = normalizedJoinedText(from: newSegments)

        let changed = service.confirmedText != nextConfirmedText || service.hypothesisText != nextHypothesisText
        service.updateTranscriptionText(confirmed: nextConfirmedText, hypothesis: nextHypothesisText)
        if changed {
            service.scheduleTranslationUpdate()
        }
    }

    // MARK: - Chunk Management

    func finalizeCurrentChunk() {
        let allSegments = service.confirmedSegments + service.unconfirmedSegments
        let chunkText = normalizedJoinedText(from: allSegments)
        if !chunkText.isEmpty {
            if completedChunksText.isEmpty {
                completedChunksText = chunkText
            } else {
                completedChunksText += "\n" + chunkText
            }
        }
        service.updateSegments(confirmed: [], unconfirmed: [])
        prevUnconfirmedSegments = []
        let nextConfirmedText = completedChunksText
        let changed = service.confirmedText != nextConfirmedText || !service.hypothesisText.isEmpty
        service.updateTranscriptionText(confirmed: nextConfirmedText, hypothesis: "")
        if changed {
            service.scheduleTranslationUpdate()
        }
    }

    // MARK: - Text Normalization

    func normalizedJoinedText(from segments: [ASRSegment]) -> String {
        segments.lazy
            .map { self.normalizeDisplayText($0.text) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func normalizeDisplayText(_ text: String) -> String {
        text
            .components(separatedBy: "\n")
            .map { line in
                collapseInlineWhitespace(in: line)
                    .trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func collapseInlineWhitespace(in line: String) -> String {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return Self.inlineWhitespaceRegex.stringByReplacingMatches(
            in: line, options: [], range: range, withTemplate: " "
        )
    }

    // MARK: - Full Text Assembly

    func assembleFullText(confirmedSegments: [ASRSegment], unconfirmedSegments: [ASRSegment]) -> String {
        let currentChunkConfirmed = normalizedJoinedText(from: confirmedSegments)
        let currentChunkHypothesis = normalizedJoinedText(from: unconfirmedSegments)
        let currentChunk = [currentChunkConfirmed, currentChunkHypothesis]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let parts = [completedChunksText, currentChunk].filter { !$0.isEmpty }
        return parts.joined(separator: "\n")
    }

    // MARK: - State Reset

    func reset() {
        cancelAndTrackTranscriptionTask()
        lastBufferSize = 0
        lastConfirmedSegmentEndSeconds = 0
        prevUnconfirmedSegments = []
        consecutiveSilenceCount = 0
        hasCompletedFirstInference = false
        movingAverageInferenceSeconds = 0.0
        completedChunksText = ""
        lastUIMeterUpdateTimestamp = 0
    }

    /// Reset only buffer tracking for TTS resume (fresh inference window).
    func resetBufferTracking() {
        lastBufferSize = 0
        consecutiveSilenceCount = 0
        hasCompletedFirstInference = false
    }

    /// Clear completed chunks and segment tracking for fresh interpretation segment.
    func clearCompletedChunks() {
        completedChunksText = ""
        prevUnconfirmedSegments = []
        lastConfirmedSegmentEndSeconds = 0
    }
}
