import Foundation
import WhisperKit

/// ASREngine implementation backed by WhisperKit (CoreML + Neural Engine).
/// Handles Whisper model download/load and recording via WhisperKit's AudioProcessor.
@MainActor
final class WhisperKitEngine: ASREngine {

    // MARK: - ASREngine conformance

    let isStreaming = false

    private(set) var modelState: ASRModelState = .unloaded
    private(set) var downloadProgress: Double = 0.0

    private var whisperKit: WhisperKit?
    private var lastEnergyUpdateTime: CFAbsoluteTime = 0
    private var sessionStartSampleIndex: Int = 0
    private var sessionStartEnergyIndex: Int = 0

    // Cached values updated from the recording callback
    private(set) var audioSamples: [Float] = []
    private(set) var relativeEnergy: [Float] = []

    private func refreshSessionOffsets(using kit: WhisperKit) {
        sessionStartSampleIndex = kit.audioProcessor.audioSamples.count
        sessionStartEnergyIndex = kit.audioProcessor.relativeEnergy.count
    }

    // MARK: - Model Management

    private func modelFolderKey(for variant: String) -> String {
        "modelFolder_\(variant)"
    }

    func setupModel(_ model: ModelInfo) async throws {
        guard let variant = model.variant else {
            throw AppError.noModelSelected
        }

        // Phase 1: Download
        modelState = .downloading
        downloadProgress = 0.0

        let modelFolderURL: URL
        do {
            modelFolderURL = try await WhisperKit.download(
                variant: variant,
                from: "argmaxinc/whisperkit-coreml",
                progressCallback: { [weak self] progress in
                    Task { @MainActor in
                        self?.downloadProgress = progress.fractionCompleted
                    }
                }
            )
        } catch {
            modelState = .unloaded
            downloadProgress = 0.0
            throw AppError.modelDownloadFailed(underlying: error)
        }

        modelState = .downloaded
        downloadProgress = 1.0

        // Phase 2: Load
        do {
            let config = WhisperKitConfig(
                model: variant,
                modelFolder: modelFolderURL.path(),
                computeOptions: ModelComputeOptions(
                    audioEncoderCompute: .cpuAndNeuralEngine,
                    textDecoderCompute: .cpuAndNeuralEngine
                ),
                verbose: true,
                logLevel: .info,
                prewarm: true,
                load: true,
                download: false
            )

            whisperKit = try await WhisperKit(config)
            modelState = .loaded

            UserDefaults.standard.set(
                modelFolderURL.path(),
                forKey: modelFolderKey(for: variant)
            )
        } catch {
            modelState = .unloaded
            downloadProgress = 0.0
            throw AppError.modelLoadFailed(underlying: error)
        }
    }

    func loadModel(_ model: ModelInfo) async throws {
        guard let variant = model.variant else {
            throw AppError.noModelSelected
        }

        guard let savedFolder = UserDefaults.standard.string(
            forKey: modelFolderKey(for: variant)
        ), FileManager.default.fileExists(atPath: savedFolder) else {
            return
        }

        modelState = .loading

        do {
            let config = WhisperKitConfig(
                model: variant,
                modelFolder: savedFolder,
                computeOptions: ModelComputeOptions(
                    audioEncoderCompute: .cpuAndNeuralEngine,
                    textDecoderCompute: .cpuAndNeuralEngine
                ),
                verbose: true,
                logLevel: .info,
                prewarm: true,
                load: true,
                download: false
            )

            whisperKit = try await WhisperKit(config)
            modelState = .loaded
        } catch {
            modelState = .unloaded
        }
    }

    func isModelDownloaded(_ model: ModelInfo) -> Bool {
        guard let variant = model.variant else { return false }
        guard let savedFolder = UserDefaults.standard.string(
            forKey: modelFolderKey(for: variant)
        ) else { return false }
        return FileManager.default.fileExists(atPath: savedFolder)
    }

    func unloadModel() async {
        stopRecording()
        await whisperKit?.unloadModels()
        whisperKit = nil
        modelState = .unloaded
        downloadProgress = 0.0
        audioSamples = []
        relativeEnergy = []
        sessionStartSampleIndex = 0
        sessionStartEnergyIndex = 0
    }

    // MARK: - Recording

    func startRecording() async throws {
        guard let whisperKit else { throw AppError.modelNotReady }

        // Explicitly reset cached samples so a restarted session never reuses
        // stale buffers from a previous inference run.
        audioSamples = []
        relativeEnergy = []
        lastEnergyUpdateTime = 0
        refreshSessionOffsets(using: whisperKit)

        let granted = await AudioProcessor.requestRecordPermission()
        guard granted else { throw AppError.microphonePermissionDenied }

        try whisperKit.audioProcessor.startRecordingLive(inputDeviceID: nil) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = CFAbsoluteTimeGetCurrent()
                guard now - self.lastEnergyUpdateTime > 0.1 else { return }
                self.lastEnergyUpdateTime = now
                if let kit = self.whisperKit {
                    let rawEnergy = kit.audioProcessor.relativeEnergy
                    let rawSamples = Array(kit.audioProcessor.audioSamples)
                    let energyStart = min(self.sessionStartEnergyIndex, rawEnergy.count)
                    let sampleStart = min(self.sessionStartSampleIndex, rawSamples.count)
                    self.relativeEnergy = Array(rawEnergy.dropFirst(energyStart))
                    self.audioSamples = Array(rawSamples.dropFirst(sampleStart))
                }
            }
        }
    }

    func stopRecording() {
        whisperKit?.audioProcessor.stopRecording()
        if let kit = whisperKit {
            refreshSessionOffsets(using: kit)
        } else {
            sessionStartSampleIndex = 0
            sessionStartEnergyIndex = 0
        }
        audioSamples = []
        relativeEnergy = []
    }

    // MARK: - Transcription

    func transcribe(audioArray: [Float], options: ASRTranscriptionOptions) async throws -> ASRResult {
        guard let whisperKit else { throw AppError.modelNotReady }

        let workerCount = min(4, ProcessInfo.processInfo.activeProcessorCount)
        let seekClip: [Float] = [0]
        let decodingOptions = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: options.language,
            temperature: options.temperature,
            temperatureFallbackCount: 3,
            sampleLength: 224,
            usePrefillPrompt: true,
            usePrefillCache: true,
            skipSpecialTokens: true,
            withoutTimestamps: !options.withTimestamps,
            wordTimestamps: options.withTimestamps,
            clipTimestamps: seekClip,
            concurrentWorkerCount: workerCount
        )

        let results = try await whisperKit.transcribe(
            audioArray: audioArray,
            decodeOptions: decodingOptions
        )

        guard let result = results.first else {
            return ASRResult(text: "", segments: [], language: nil)
        }

        // Convert WhisperKit segments → ASRSegment
        let segments = result.segments.map { seg in
            ASRSegment(id: seg.id, text: seg.text, start: seg.start, end: seg.end)
        }
        let text = result.segments.map(\.text).joined(separator: " ")

        return ASRResult(text: text, segments: segments, language: result.language)
    }
}
