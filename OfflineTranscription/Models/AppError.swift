import Foundation

enum AppError: LocalizedError {
    case microphonePermissionDenied
    case microphonePermissionRestricted
    case modelDownloadFailed(underlying: Error)
    case modelLoadFailed(underlying: Error)
    case transcriptionFailed(underlying: Error)
    case audioSessionSetupFailed(underlying: Error)
    case noModelSelected
    case modelNotReady
    case audioInterrupted
    case translationUnavailable
    case translationFailed(underlying: Error)
    case ttsFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access was denied. Please enable it in Settings."
        case .microphonePermissionRestricted:
            return "Microphone access is restricted on this device."
        case .modelDownloadFailed(let error):
            return "Failed to download the model: \(error.localizedDescription)"
        case .modelLoadFailed(let error):
            return "Failed to load the model: \(error.localizedDescription)"
        case .transcriptionFailed(let error):
            return "Transcription failed: \(error.localizedDescription)"
        case .audioSessionSetupFailed(let error):
            return "Audio session setup failed: \(error.localizedDescription)"
        case .noModelSelected:
            return "No transcription model selected."
        case .modelNotReady:
            return "The transcription model is not ready yet."
        case .audioInterrupted:
            return "Recording was interrupted by another app or phone call."
        case .translationUnavailable:
            return "Native translation is unavailable. Requires iOS 18.0+ with the Translation framework."
        case .translationFailed(let error):
            return "Translation failed: \(error.localizedDescription)"
        case .ttsFailed(let error):
            return "Text-to-speech failed: \(error.localizedDescription)"
        }
    }
}
