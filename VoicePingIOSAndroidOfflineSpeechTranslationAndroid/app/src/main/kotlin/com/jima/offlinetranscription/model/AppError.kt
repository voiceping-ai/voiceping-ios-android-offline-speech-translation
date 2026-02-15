package com.voiceping.offlinetranscription.model

sealed class AppError(val message: String) {
    class MicrophonePermissionDenied : AppError("Microphone access was denied. Please enable it in Settings.")
    class SystemAudioCaptureUnsupported :
        AppError("System audio capture requires Android 10 (API 29) or later.")
    class SystemAudioCapturePermissionDenied :
        AppError("System audio capture is not enabled. Tap 'Enable System Capture' and accept the prompt.")
    class NoMicrophoneSignal : AppError(
        "No microphone signal detected. Check that the microphone is not muted or blocked."
    )
    class NetworkUnavailable : AppError("No internet connection. Connect to download the model.")
    class ModelDownloadFailed(cause: Throwable) : AppError("Failed to download the model: ${cause.localizedMessage}")
    class ModelLoadFailed(cause: Throwable) : AppError("Failed to load the model: ${cause.localizedMessage}")
    class TranscriptionFailed(cause: Throwable) : AppError("Transcription failed: ${cause.localizedMessage}")
    class TranslationUnavailable : AppError(
        "Native on-device translation is unavailable on this Android version/device."
    )
    class TranslationFailed(cause: Throwable) : AppError("Translation failed: ${cause.localizedMessage}")
    class TtsFailed(cause: Throwable) : AppError("Text-to-speech failed: ${cause.localizedMessage}")
    class NoModelSelected : AppError("No transcription model selected.")
    class ModelNotReady : AppError("The transcription model is not ready yet.")
    class InsufficientStorage(needed: String, available: String) :
        AppError("Not enough storage to download model (need $needed, have $available available).")
}
