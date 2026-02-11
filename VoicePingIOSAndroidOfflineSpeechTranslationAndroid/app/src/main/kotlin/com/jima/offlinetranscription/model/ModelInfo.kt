package com.voiceping.offlinetranscription.model

enum class EngineType { SHERPA_ONNX, ANDROID_SPEECH }
enum class SherpaModelType { SENSE_VOICE }

/** Which translation backend to use. */
enum class TranslationProvider(val displayName: String) {
    /** Google ML Kit Translation — offline, ~30 MB per language pair, 50+ languages. */
    ML_KIT("ML Kit (Offline)"),
    /** Android system TranslationManager (API 31+) — uses system-managed language packs. */
    ANDROID_SYSTEM("Android System (API 31+)")
}

/** Mode for Android SpeechRecognizer engine. */
enum class AndroidSpeechMode {
    /** Guaranteed on-device recognition via createOnDeviceSpeechRecognizer (API 31+). */
    OFFLINE,
    /** Standard recognizer — may use cloud when available (API 26+). */
    ONLINE
}

data class ModelFile(val url: String, val localName: String)

data class ModelInfo(
    val id: String,
    val displayName: String,
    val engineType: EngineType,
    val sherpaModelType: SherpaModelType? = null,
    val androidSpeechMode: AndroidSpeechMode? = null,
    val parameterCount: String,
    val sizeOnDisk: String,
    val description: String,
    val languages: String = "99 languages",
    val files: List<ModelFile>,
) {
    val inferenceMethod: String
        get() = when (engineType) {
            EngineType.SHERPA_ONNX -> "sherpa-onnx offline (ONNX Runtime)"
            EngineType.ANDROID_SPEECH -> when (androidSpeechMode) {
                AndroidSpeechMode.OFFLINE -> "Android SpeechRecognizer (on-device, API 31+)"
                AndroidSpeechMode.ONLINE -> "Android SpeechRecognizer (cloud-backed)"
                null -> "Android SpeechRecognizer"
            }
        }

    companion object {
        private const val SENSEVOICE_BASE_URL =
            "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/"

        val availableModels = listOf(
            ModelInfo(
                id = "sensevoice-small",
                displayName = "SenseVoice Small",
                engineType = EngineType.SHERPA_ONNX,
                sherpaModelType = SherpaModelType.SENSE_VOICE,
                parameterCount = "234M",
                sizeOnDisk = "~240 MB",
                description = "Multilingual (zh/en/ja/ko/yue). 5x faster than Whisper Small.",
                languages = "zh/en/ja/ko/yue",
                files = listOf(
                    ModelFile("${SENSEVOICE_BASE_URL}model.int8.onnx", "model.int8.onnx"),
                    ModelFile("${SENSEVOICE_BASE_URL}tokens.txt", "tokens.txt"),
                )
            ),
            ModelInfo(
                id = "android-speech-offline",
                displayName = "Android Speech (Offline)",
                engineType = EngineType.ANDROID_SPEECH,
                androidSpeechMode = AndroidSpeechMode.OFFLINE,
                parameterCount = "System",
                sizeOnDisk = "0 MB",
                description = "Guaranteed on-device recognition via createOnDeviceSpeechRecognizer. Requires Android 12+ (API 31).",
                languages = "System languages",
                files = emptyList()
            ),
            ModelInfo(
                id = "android-speech-online",
                displayName = "Android Speech (Online)",
                engineType = EngineType.ANDROID_SPEECH,
                androidSpeechMode = AndroidSpeechMode.ONLINE,
                parameterCount = "System",
                sizeOnDisk = "0 MB",
                description = "Standard SpeechRecognizer — uses cloud when available, falls back to on-device.",
                languages = "System languages",
                files = emptyList()
            ),
        )

        val defaultModel = availableModels.first { it.id == "sensevoice-small" }

        /** Group models by engine for UI display. */
        val modelsByEngine: Map<EngineType, List<ModelInfo>>
            get() = availableModels.groupBy { it.engineType }
    }
}
