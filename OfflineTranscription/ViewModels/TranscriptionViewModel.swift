import Foundation
import SwiftData
import Observation
import AVFoundation

@MainActor
@Observable
final class TranscriptionViewModel {
    let whisperService: WhisperService

    var showError: Bool = false
    var errorMessage: String = ""
    var showPermissionDenied: Bool = false
    private var recordingStartTime: Date?
    private var recordingDuration: TimeInterval = 0

    var isRecording: Bool { whisperService.isRecording }
    var confirmedText: String { whisperService.confirmedText }
    var hypothesisText: String { whisperService.hypothesisText }
    var translatedConfirmedText: String { whisperService.translatedConfirmedText }
    var translatedHypothesisText: String { whisperService.translatedHypothesisText }
    var translationWarning: String? { whisperService.translationWarning }
    var bufferEnergy: [Float] { whisperService.bufferEnergy }
    var bufferSeconds: Double { whisperService.bufferSeconds }
    var tokensPerSecond: Double { whisperService.tokensPerSecond }
    var cpuPercent: Double { whisperService.cpuPercent }
    var memoryMB: Double { whisperService.memoryMB }
    var selectedModel: ModelInfo { whisperService.selectedModel }
    var translationEnabled: Bool { whisperService.translationEnabled }
    var fullText: String { whisperService.fullTranscriptionText }
    var sessionState: SessionState { whisperService.sessionState }

    /// True when the engine has a mid-session error to surface.
    var hasEngineError: Bool { whisperService.lastError != nil }

    /// True when the session was interrupted (phone call, etc.)
    var isInterrupted: Bool { whisperService.sessionState == .interrupted }

    init(whisperService: WhisperService) {
        self.whisperService = whisperService
    }

    func toggleRecording() async {
        if isRecording || isInterrupted {
            stopRecording()
        } else {
            await startRecording()
        }
    }

    func startRecording() async {
        do {
            recordingStartTime = Date()
            recordingDuration = 0
            showPermissionDenied = false
            try await whisperService.startRecording()
        } catch let error as AppError {
            if case .microphonePermissionDenied = error {
                showPermissionDenied = true
            }
            showError = true
            errorMessage = error.localizedDescription
        } catch {
            showError = true
            errorMessage = error.localizedDescription
        }
    }

    func stopRecording() {
        if let start = recordingStartTime {
            recordingDuration = Date().timeIntervalSince(start)
        } else {
            recordingDuration = 0
        }
        whisperService.stopRecording()
    }

    /// Surface any engine error via the shared error alert.
    func surfaceEngineError() {
        if let error = whisperService.lastError {
            if case .translationUnavailable = error {
                whisperService.clearLastError()
                return
            }
            if case .translationFailed = error {
                whisperService.clearLastError()
                return
            }
            showError = true
            errorMessage = error.localizedDescription
            whisperService.clearLastError()
        }
    }

    func openSettings() {
        PermissionManager.openAppSettings()
    }

    func clearTranscription() {
        recordingDuration = 0
        recordingStartTime = nil
        showPermissionDenied = false
        whisperService.clearTranscription()
    }

    #if DEBUG
    func transcribeTestFile(_ path: String) {
        whisperService.transcribeTestFile(path)
    }
    #endif

    @discardableResult
    func saveTranscription(using context: ModelContext) -> Bool {
        let text = fullText
        guard !text.isEmpty else { return false }

        // Use bufferSeconds as fallback for test-file transcriptions where recordingDuration == 0
        let duration = recordingDuration > 0 ? recordingDuration : whisperService.bufferSeconds
        guard duration > 0 else { return false }

        let record = TranscriptionRecord(
            text: text,
            durationSeconds: duration,
            modelUsed: whisperService.selectedModel.displayName
        )

        // Save audio WAV alongside the text record
        let samples = whisperService.currentAudioSamples
        if !samples.isEmpty {
            do {
                try SessionFileManager.saveAudio(samples: samples, for: record.id)
                record.audioFileName = SessionFileManager.relativeAudioPath(for: record.id)
            } catch {
                NSLog("[Save] Failed to write audio WAV: \(error)")
            }
        }

        context.insert(record)
        do {
            try context.save()
            return true
        } catch {
            SessionFileManager.deleteSession(for: record.id)
            showError = true
            errorMessage = "Failed to save: \(error.localizedDescription)"
            return false
        }
    }
}
