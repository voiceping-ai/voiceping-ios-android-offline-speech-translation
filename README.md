# Offline Transcription & Translation

Cross-platform (iOS + Android) app for **fully offline speech-to-text transcription and text translation** — all inference runs on-device with no cloud dependency.

- **Transcription**: Record speech from the microphone and transcribe it locally using multiple ASR engines (Whisper, Moonshine, SenseVoice, Zipformer, Parakeet). Supports both batch and real-time streaming modes.
- **Translation**: Translate the transcribed text between languages entirely on-device (iOS: Apple Translation framework, Android: native TranslationManager API).
- **Text-to-Speech**: Read translated or transcribed text aloud using native TTS (AVSpeechSynthesizer / Android TextToSpeech).
- **Audio Playback & Export**: Save session audio as WAV, play back with waveform scrubber, and export sessions as ZIP.

Models are downloaded once from HuggingFace, then all processing — recording, transcription, translation, and playback — works completely offline.

## Features

### Core (Both Platforms)
- Real-time microphone recording with live transcript rendering
- Multiple ASR engine backends with in-app model switching
- On-device model download with progress tracking
- Streaming transcription (Zipformer transducer, endpoint-based)
- Voice Activity Detection (VAD) toggle
- Optional timestamp display
- On-device translation (iOS: Translation framework, Android: TranslationManager)
- Text-to-speech playback (iOS: AVSpeechSynthesizer, Android: TextToSpeech API)
- Session audio saving as WAV (PCM 16kHz mono 16-bit)
- Audio playback with 200-bar waveform scrubber
- ZIP export of session (transcription + audio)
- Transcription history with save, copy, share, delete
- Live audio energy visualization
- CPU/memory/tokens-per-second telemetry display
- Storage guard before large model downloads

### iOS-Specific (SwiftUI + SwiftData)
- 4 ASR engines: WhisperKit (CoreML), sherpa-onnx offline, sherpa-onnx streaming, FluidAudio (Parakeet-TDT)
- 11 models across 6 families
- iOS 18+ native Translation framework
- AVAudioSession interruption + route change handling
- Chunked offline transcription with eager confirmation
- Auto-loads last downloaded model on launch
- Zero-dependency ZIP via NSFileCoordinator

### Android-Specific (Kotlin + Compose + Room)
- 3 ASR engines: whisper.cpp (JNI), sherpa-onnx offline, sherpa-onnx streaming
- 11 models across 5 families
- Native TranslationManager API (Android 12+)
- Runtime microphone permission flow
- Room database with manual migration (v1 to v2)
- FileProvider-based session sharing
- Streaming chunk manager with endpoint detection

## Supported Models

### iOS (11 models)

| Model | Engine | Size | Params | Languages | Weights |
|-------|--------|------|--------|-----------|---------|
| Whisper Tiny | WhisperKit | ~78 MB | 39M | [99](https://github.com/openai/whisper#available-models-and-languages) | [openai/whisper-tiny](https://huggingface.co/openai/whisper-tiny) |
| Whisper Base (.en) | WhisperKit | ~148 MB | 74M | English | [openai/whisper-base.en](https://huggingface.co/openai/whisper-base.en) |
| Whisper Small | WhisperKit | ~488 MB | 244M | [99](https://github.com/openai/whisper#available-models-and-languages) | [openai/whisper-small](https://huggingface.co/openai/whisper-small) |
| Whisper Large V3 Turbo | WhisperKit | ~600 MB | 809M | [99](https://github.com/openai/whisper#available-models-and-languages) | [openai/whisper-large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo) |
| Whisper Large V3 Turbo (Compressed) | WhisperKit | ~1 GB | 809M | [99](https://github.com/openai/whisper#available-models-and-languages) | [openai/whisper-large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo) |
| Moonshine Tiny | sherpa-onnx | ~124 MB | 27M | English | [UsefulSensors/moonshine-tiny](https://huggingface.co/UsefulSensors/moonshine-tiny) |
| Moonshine Base | sherpa-onnx | ~287 MB | 61M | English | [UsefulSensors/moonshine-base](https://huggingface.co/UsefulSensors/moonshine-base) |
| SenseVoice Small | sherpa-onnx | ~239 MB | 234M | zh, en, ja, ko, yue | [FunAudioLLM/SenseVoiceSmall](https://huggingface.co/FunAudioLLM/SenseVoiceSmall) |
| Zipformer Streaming | sherpa-onnx | ~45 MB | 20M | English | [sherpa-onnx-streaming-zipformer-en-20M](https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17) |
| Omnilingual 300M | sherpa-onnx | ~365 MB | 300M | [1,162](https://huggingface.co/facebook/mms-1b-all) | [facebook/mms-1b-all](https://huggingface.co/facebook/mms-1b-all) |
| Parakeet TDT 0.6B | FluidAudio | ~600 MB | 600M | [25 European](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) | [nvidia/parakeet-tdt-0.6b-v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) |

### Android (11 models)

| Model | Engine | Size | Params | Languages | Weights |
|-------|--------|------|--------|-----------|---------|
| Whisper Tiny | whisper.cpp | ~78 MB | 39M | [99](https://github.com/openai/whisper#available-models-and-languages) | [ggml-tiny.bin](https://huggingface.co/ggerganov/whisper.cpp/blob/main/ggml-tiny.bin) |
| Whisper Base | whisper.cpp | ~148 MB | 74M | [99](https://github.com/openai/whisper#available-models-and-languages) | [ggml-base.bin](https://huggingface.co/ggerganov/whisper.cpp/blob/main/ggml-base.bin) |
| Whisper Base (.en) | whisper.cpp | ~148 MB | 74M | English | [ggml-base.en.bin](https://huggingface.co/ggerganov/whisper.cpp/blob/main/ggml-base.en.bin) |
| Whisper Small | whisper.cpp | ~488 MB | 244M | [99](https://github.com/openai/whisper#available-models-and-languages) | [ggml-small.bin](https://huggingface.co/ggerganov/whisper.cpp/blob/main/ggml-small.bin) |
| Whisper Large V3 Turbo | whisper.cpp | ~1.6 GB | 809M | [99](https://github.com/openai/whisper#available-models-and-languages) | [ggml-large-v3-turbo.bin](https://huggingface.co/ggerganov/whisper.cpp/blob/main/ggml-large-v3-turbo.bin) |
| Whisper Large V3 Turbo (q8_0) | whisper.cpp | ~874 MB | 809M | [99](https://github.com/openai/whisper#available-models-and-languages) | [ggml-large-v3-turbo-q8_0.bin](https://huggingface.co/ggerganov/whisper.cpp/blob/main/ggml-large-v3-turbo-q8_0.bin) |
| Moonshine Tiny | sherpa-onnx | ~124 MB | 27M | English | [sherpa-onnx-moonshine-tiny-en-int8](https://huggingface.co/csukuangfj/sherpa-onnx-moonshine-tiny-en-int8) |
| Moonshine Base | sherpa-onnx | ~287 MB | 62M | English | [sherpa-onnx-moonshine-base-en-int8](https://huggingface.co/csukuangfj/sherpa-onnx-moonshine-base-en-int8) |
| SenseVoice Small | sherpa-onnx | ~239 MB | 234M | zh, en, ja, ko, yue | [sherpa-onnx-sense-voice](https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17) |
| Omnilingual 300M | sherpa-onnx | ~365 MB | 300M | [1,162](https://huggingface.co/facebook/mms-1b-all) | [sherpa-onnx-omnilingual-300M-ctc-int8](https://huggingface.co/csukuangfj/sherpa-onnx-omnilingual-asr-1600-languages-300M-ctc-int8-2025-11-12) |
| Zipformer Streaming | sherpa-onnx | ~45 MB | 20M | English | [sherpa-onnx-streaming-zipformer-en-20M](https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17) |

## Architecture

### iOS

```
┌─────────────────────────────────────────────────────────────────┐
│                     OfflineTranscriptionApp                     │
│                        (SwiftUI App)                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────┐  ┌───────────────────┐  ┌──────────────┐ │
│  │ TranscriptionView│  │ TranscriptionHist │  │ ModelSetupView│ │
│  │                  │  │     oryView       │  │              │ │
│  └────────┬─────────┘  └────────┬──────────┘  └──────┬───────┘ │
│           │                     │                     │         │
│  ┌────────▼─────────┐  ┌───────▼──────────┐  ┌──────▼───────┐ │
│  │ Transcription    │  │ AudioPlayer      │  │ ModelMgmt    │ │
│  │ ViewModel        │  │ ViewModel        │  │ ViewModel    │ │
│  └────────┬─────────┘  └─────────────────-┘  └──────────────┘ │
│           │                                                     │
├───────────▼─────────────────────────────────────────────────────┤
│                      WhisperService                             │
│              (Orchestrator — coordinates all services)          │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ ASREngine Protocol                                       │   │
│  │                                                          │   │
│  │  ┌──────────────┐ ┌──────────────┐ ┌──────────────────┐ │   │
│  │  │ WhisperKit   │ │ SherpaOnnx   │ │ SherpaOnnx       │ │   │
│  │  │ Engine       │ │ OfflineEngine│ │ StreamingEngine  │ │   │
│  │  │              │ │              │ │                  │ │   │
│  │  │ CoreML /     │ │ ONNX Runtime │ │ ONNX Runtime    │ │   │
│  │  │ Neural Engine│ │ (Moonshine,  │ │ (Zipformer      │ │   │
│  │  │ (Whisper)    │ │  SenseVoice, │ │  Transducer)    │ │   │
│  │  │              │ │  Omnilingual)│ │                  │ │   │
│  │  └──────────────┘ └──────────────┘ └──────────────────┘ │   │
│  │                                                          │   │
│  │  ┌──────────────┐                                        │   │
│  │  │ FluidAudio   │                                        │   │
│  │  │ Engine       │                                        │   │
│  │  │              │                                        │   │
│  │  │ CoreML       │                                        │   │
│  │  │ (Parakeet    │                                        │   │
│  │  │  TDT)        │                                        │   │
│  │  └──────────────┘                                        │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌────────────────┐ ┌──────────────────┐ ┌─────────────────┐   │
│  │ AudioRecorder  │ │ AppleTranslation │ │ NativeTTS       │   │
│  │                │ │ Service          │ │ Service          │   │
│  │ AVAudioEngine  │ │ (iOS 18+        │ │ (AVSpeech       │   │
│  │ + VAD          │ │  Translation     │ │  Synthesizer)   │   │
│  │                │ │  framework)      │ │                 │   │
│  └────────────────┘ └──────────────────┘ └─────────────────┘   │
│                                                                 │
│  ┌────────────────┐ ┌──────────────────┐ ┌─────────────────┐   │
│  │ ModelDownloader│ │ SessionFile      │ │ SystemMetrics   │   │
│  │                │ │ Manager          │ │                 │   │
│  │ HuggingFace   │ │ WAVWriter +      │ │ CPU / Memory    │   │
│  │ model fetch   │ │ ZIPExporter      │ │ telemetry       │   │
│  └────────────────┘ └──────────────────┘ └─────────────────┘   │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                    SwiftData (Persistence)                       │
│                    TranscriptionRecord                          │
│                    sessions/{uuid}/audio.wav                    │
└─────────────────────────────────────────────────────────────────┘
```

**Layer breakdown:**

- **UI Layer** — SwiftUI views organized by feature: `TranscriptionView` (main recording screen with live waveform and transcript), `TranscriptionHistoryView` (saved sessions list with detail/playback), and `ModelSetupView` (model picker with download progress). Each view is backed by an `@Observable` ViewModel that holds UI state and delegates actions downward.

- **WhisperService (Orchestrator)** — Central coordinator that owns the active ASR engine, manages the recording lifecycle (start, feed audio, collect transcript, stop), and exposes transcription state to ViewModels. Uses `EngineFactory` to instantiate the correct engine from `ModelInfo` at model-switch time.

- **ASREngine Protocol** — Defines `setupModel()`, `transcribe(audio:)`, and `startStreaming()`/`stopStreaming()` so every engine is interchangeable. Four implementations:
  - **WhisperKitEngine** — Runs Whisper models via CoreML on the Apple Neural Engine. Chunked offline transcription with eager text confirmation.
  - **SherpaOnnxOfflineEngine** — Runs Moonshine, SenseVoice, and Omnilingual models via ONNX Runtime CPU. Batch inference on accumulated audio buffers.
  - **SherpaOnnxStreamingEngine** — Runs Zipformer transducer via ONNX Runtime with a 100ms polling loop. Endpoint detection triggers partial-to-confirmed text promotion.
  - **FluidAudioEngine** — Runs NVIDIA Parakeet-TDT via CoreML using the FluidAudio SDK.

- **Supporting Services:**
  - **AudioRecorder** — Wraps `AVAudioEngine` with an install-tap callback that feeds PCM Float32 samples to the active engine. Handles `AVAudioSession` interruptions and route changes (Bluetooth, headphones). Optional VAD gating.
  - **AppleTranslationService** — Uses the iOS 18+ `Translation` framework for on-device text translation between language pairs. Downloads language packs on first use, then works offline.
  - **NativeTTSService** — Wraps `AVSpeechSynthesizer` to read transcribed or translated text aloud.
  - **ModelDownloader** — Downloads model files from HuggingFace with `URLSession`, tracks progress, verifies file size, and caches to the app's Documents directory.
  - **SessionFileManager + WAVWriter + ZIPExporter** — Saves recorded audio as 16kHz/16-bit/mono WAV under `Documents/sessions/{uuid}/audio.wav`. `ZIPExporter` uses `NSFileCoordinator(.forUploading)` for zero-dependency ZIP creation.
  - **SystemMetrics** — Polls CPU usage (`host_processor_info`) and memory footprint (`task_info`) for real-time telemetry during recording.

- **Persistence** — SwiftData `TranscriptionRecord` stores transcription text, duration, model used, language, and an optional `audioFileName` path. SwiftData handles schema migration for nullable field additions automatically.

---

### Android

```
┌─────────────────────────────────────────────────────────────────┐
│                        MainActivity                             │
│                   (Jetpack Compose + Navigation)                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────┐  ┌───────────────────┐  ┌──────────────┐ │
│  │ Transcription    │  │ HistoryScreen /   │  │ ModelSetup   │ │
│  │ Screen           │  │ HistoryDetail     │  │ Screen       │ │
│  │                  │  │ Screen            │  │              │ │
│  └────────┬─────────┘  └────────┬──────────┘  └──────┬───────┘ │
│           │                     │                     │         │
│  ┌────────▼─────────┐  ┌───────▼──────────┐          │         │
│  │ Transcription    │  │ History          │          │         │
│  │ ViewModel        │  │ ViewModel        │          │         │
│  └────────┬─────────┘  └─────────────────-┘          │         │
│           │                                           │         │
├───────────▼───────────────────────────────────────────▼─────────┤
│                       WhisperEngine                             │
│              (Orchestrator — coordinates all services)          │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ AsrEngine Interface                                      │   │
│  │                                                          │   │
│  │  ┌──────────────┐ ┌──────────────┐ ┌──────────────────┐ │   │
│  │  │ WhisperCpp   │ │ SherpaOnnx   │ │ SherpaOnnx       │ │   │
│  │  │ Engine       │ │ Engine       │ │ StreamingEngine  │ │   │
│  │  │              │ │              │ │                  │ │   │
│  │  │ whisper.cpp  │ │ ONNX Runtime │ │ ONNX Runtime    │ │   │
│  │  │ via JNI      │ │ (Moonshine,  │ │ (Zipformer      │ │   │
│  │  │ (libwhisper) │ │  SenseVoice, │ │  Transducer)    │ │   │
│  │  │              │ │  Omnilingual)│ │                  │ │   │
│  │  └──────────────┘ └──────────────┘ └──────────────────┘ │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌────────────────┐ ┌──────────────────┐ ┌─────────────────┐   │
│  │ AudioRecorder  │ │ AndroidNative    │ │ AndroidTts      │   │
│  │                │ │ Translator       │ │ Service          │   │
│  │ AudioRecord    │ │ (Translation     │ │ (TextToSpeech   │   │
│  │ API + VAD      │ │  Manager API)    │ │  API)           │   │
│  └────────────────┘ └──────────────────┘ └─────────────────┘   │
│                                                                 │
│  ┌────────────────┐ ┌──────────────────┐ ┌─────────────────┐   │
│  │ ModelDownloader│ │ AudioPlayback    │ │ SystemMetrics   │   │
│  │                │ │ Manager          │ │                 │   │
│  │ OkHttp +      │ │ WavWriter +      │ │ CPU / Memory    │   │
│  │ HuggingFace   │ │ WaveformGenerator│ │ telemetry       │   │
│  │ model fetch   │ │ + SessionExporter │ │                 │   │
│  └────────────────┘ └──────────────────┘ └─────────────────┘   │
│                                                                 │
│  ┌──────────────────────────────────────┐                       │
│  │ StreamingChunkManager               │                       │
│  │ (endpoint detection + text merging) │                       │
│  └──────────────────────────────────────┘                       │
│                                                                 │
├──────────────────────────────────┬──────────────────────────────┤
│ Room Database (Persistence)      │ whisper.cpp (Native / JNI)  │
│ AppDatabase + TranscriptionDao   │ CMake build → libwhisper.so │
│ TranscriptionEntity              │ WhisperLib.kt (JNI bridge)  │
│ sessions/{uuid}/audio.wav        │                              │
└──────────────────────────────────┴──────────────────────────────┘
```

**Layer breakdown:**

- **UI Layer** — Jetpack Compose screens with `NavHost` navigation. `TranscriptionScreen` shows the live recording UI with waveform visualizer, transcript text, and action buttons. `HistoryScreen` / `HistoryDetailScreen` display saved sessions with waveform playback scrubber and ZIP export. Model setup shows available models with download progress. Each screen reads state from its ViewModel via `collectAsState()`.

- **WhisperEngine (Orchestrator)** — Central coordinator that manages the active ASR engine, recording lifecycle, and real-time/batch transcription loops. Instantiates the correct `AsrEngine` based on `ModelInfo.engineType`. Exposes `StateFlow` properties for transcription text, model state, and metrics.

- **AsrEngine Interface** — Defines `setupModel()`, `transcribeFile()`, and streaming methods so engines are swappable. Three implementations:
  - **WhisperCppEngine** — Loads GGML model files and runs Whisper inference via JNI. The native side is built with CMake from the `whisper.cpp` submodule into `libwhisper.so`. `WhisperLib.kt` provides the Kotlin JNI bridge. Uses a `realtimeLoop()` coroutine that feeds accumulated audio buffers and flushes remaining samples on stop.
  - **SherpaOnnxEngine** — Runs Moonshine, SenseVoice, and Omnilingual models via the sherpa-onnx AAR (`OfflineRecognizer` API). Accepts Float32 audio in [-1, 1] range directly. Uses `Mutex` to prevent concurrent `setupModel()` races.
  - **SherpaOnnxStreamingEngine** — Runs Zipformer transducer via `OnlineRecognizer` + `OnlineStream` API with a 100ms polling loop. Thread safety via `lock.withLock` on `feedAudio()`/`release()`, and managed `ExecutorService` lifecycle (shutdown + awaitTermination before freeing native objects).

- **Supporting Services:**
  - **AudioRecorder** — Wraps Android's `AudioRecord` API to capture 16kHz mono PCM. Feeds Float32 samples to the active engine's audio callback. Handles runtime `RECORD_AUDIO` permission.
  - **AndroidNativeTranslator** — Uses Android's `TranslationManager` API (Android 12+) for fully on-device text translation. Downloads language packs on first use, then works offline.
  - **AndroidTtsService** — Wraps the Android `TextToSpeech` API for reading text aloud with configurable language.
  - **ModelDownloader** — Downloads model files from HuggingFace via OkHttp with progress tracking. Verifies file size before promoting temp file to final path. Checks available storage before large downloads.
  - **AudioPlaybackManager + WavWriter + WaveformGenerator + SessionExporter** — Saves audio as 16kHz/16-bit/mono WAV via chunked `BufferedOutputStream`. `WaveformGenerator` computes 200-bar RMS energy with peak normalization. `AudioPlaybackManager` wraps `MediaPlayer` with a 50ms coroutine position poll. `SessionExporter` creates ZIP archives via `ZipOutputStream` and shares through `FileProvider`.
  - **StreamingChunkManager** — Aggregates streaming transcription output: tracks confirmed vs. partial text, detects endpoint boundaries, and merges chunks into a coherent transcript.
  - **SystemMetrics** — Reads `/proc/stat` for CPU usage and `Runtime` memory APIs for heap telemetry.

- **Persistence** — Room database with `TranscriptionEntity` (text, duration, model, language, optional `audioFileName`). Manual migration v1 to v2 adds the `audioFileName` column via `ALTER TABLE ADD COLUMN`. `AppPreferences` uses Jetpack DataStore for settings.

- **Native Layer** — The `whisper.cpp` git submodule is compiled via CMake into `libwhisper.so` (filtered to `arm64-v8a` and `x86_64` ABIs). `WhisperLib.kt` declares `external fun` JNI methods that map to C++ functions in `whisper_jni.cpp`.

## Translation

Both platforms provide fully offline text translation using OS-level APIs. Translation is triggered after transcription completes — the user selects source and target languages, and the transcribed text is translated on-device.

### iOS — Apple Translation Framework

- **API**: `Translation` framework (`TranslationSession`), available on **iOS 18+**
- **Service**: [AppleTranslationService.swift](OfflineTranscription/Services/AppleTranslationService.swift)
- **How it works**: The SwiftUI `.translationTask()` modifier injects a `TranslationSession` into the service. When translation is requested, the session translates text synchronously on-device using Apple's neural translation models.
- **Language support**: Any language pair supported by iOS Settings > Translate > Downloaded Languages. Users must pre-download language packs via iOS Settings for offline use.
- **No external dependencies** — uses the system framework directly
- **Fallback**: On iOS < 18, translation is unavailable and the UI hides translation controls

### Android — Native TranslationManager API

- **API**: `android.view.translation.TranslationManager`, available on **Android 12+ (API 31)**
- **Service**: [AndroidNativeTranslator.kt](OfflineTranscriptionAndroid/app/src/main/kotlin/com/jima/offlinetranscription/service/AndroidNativeTranslator.kt)
- **How it works**: On first translation request, the service queries `getOnDeviceTranslationCapabilities()` to verify the language pair is available, then creates a `Translator` instance via `createOnDeviceTranslator()`. Subsequent translations reuse the same translator unless the language pair changes.
- **Language support**: Depends on device OEM and installed language packs. Supported pairs must be in `STATE_ON_DEVICE`, `STATE_AVAILABLE_TO_DOWNLOAD`, or `STATE_DOWNLOADING` state.
- **No external dependencies** — uses the Android system translation service (no ML Kit, no Google Translate API)
- **Fallback**: On Android < 12, translation is unavailable

## Text-to-Speech (TTS)

Both platforms read transcribed or translated text aloud using native OS speech synthesis. TTS is triggered by user action and automatically pauses microphone recording to prevent audio feedback.

### iOS — AVSpeechSynthesizer

- **API**: `AVFoundation` (`AVSpeechSynthesizer`, `AVSpeechUtterance`)
- **Service**: [NativeTTSService.swift](OfflineTranscription/Services/NativeTTSService.swift)
- **How it works**: Creates an `AVSpeechUtterance` with the text, language code, and speech rate. Stops any active speech before starting new playback. Optionally selects a specific voice by identifier.
- **Evidence capture**: Simultaneously synthesizes audio to a CAF file for testing/debugging via `AVSpeechSynthesizer.write()` and a `SpeechAudioDumper` helper
- **Speech rate**: Configurable, clamped between `AVSpeechUtteranceMinimumSpeechRate` and `AVSpeechUtteranceMaximumSpeechRate`
- **Language support**: Any language with an installed `AVSpeechSynthesisVoice`

### Android — TextToSpeech API

- **API**: Android `TextToSpeech` system API
- **Service**: [AndroidTtsService.kt](OfflineTranscriptionAndroid/app/src/main/kotlin/com/jima/offlinetranscription/service/AndroidTtsService.kt)
- **How it works**: Initializes the system `TextToSpeech` engine on construction. On `speak()`, validates the requested `Locale` is available (falls back to `Locale.US`), sets speech rate (0.25x–2.0x), and calls `TextToSpeech.speak()`.
- **Evidence capture**: Calls `synthesizeToFile()` to dump TTS audio as WAV before playback. If TTS initialization fails, generates a fallback sine-wave tone file as evidence.
- **Speech rate**: Configurable (0.25x to 2.0x), pitch fixed at 1.0
- **Language support**: Any locale installed on the device; graceful fallback to US English

## Setup

### 1) Clone and initialize submodules
```bash
git clone https://github.com/atyenoria/offline-translation.git
cd offline-translation
git submodule update --init --recursive
```

### 2) iOS
**Requirements:** macOS, Xcode 15+, iOS 17+ simulator/device, XcodeGen (`brew install xcodegen`)

```bash
xcodegen generate
open OfflineTranscription.xcodeproj
```

Build from CLI:
```bash
xcodebuild -project OfflineTranscription.xcodeproj \
  -scheme OfflineTranscription \
  -destination 'generic/platform=iOS Simulator' build
```

### 3) Android
**Requirements:** Android Studio (or SDK/NDK), JDK 17, Android SDK 35, minSdk 26, CMake 3.22.1

Download sherpa-onnx AAR (v1.12.23, ~37 MB):
```bash
./OfflineTranscriptionAndroid/setup-deps.sh
```

Build and test:
```bash
./OfflineTranscriptionAndroid/gradlew -p OfflineTranscriptionAndroid assembleDebug
./OfflineTranscriptionAndroid/gradlew -p OfflineTranscriptionAndroid testDebugUnitTest
```

## Testing

### Unit Tests

**iOS** (116 tests, 8 suites):
```bash
xcodebuild test -scheme OfflineTranscription \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:OfflineTranscriptionTests
```

**Android** (170 tests, 8 classes):
```bash
cd OfflineTranscriptionAndroid
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
  ./gradlew testDebugUnitTest
```

### E2E Model Evidence Tests

These tests cycle through every ASR model, downloading it if needed, running inference on a test WAV file (`whisper.cpp/samples/jfk.wav`), and collecting screenshots + a `result.json` per model. Each model produces 3 PNG screenshots and a JSON result file in `artifacts/e2e/{platform}/{modelId}/`.

**Prerequisites:**
- iOS: Built app in Xcode (or `xcodebuild build`), booted iOS Simulator
- Android: Connected emulator or device via ADB, JDK 17

**iOS** (11 models, XCUITest mode recommended):
```bash
# Run all 11 models via XCUITest (captures screenshots in-process)
./scripts/ios-e2e-test.sh --xcuitest

# Run a single model
./scripts/ios-e2e-test.sh --xcuitest whisper-tiny

# Run multiple specific models
./scripts/ios-e2e-test.sh --xcuitest whisper-tiny moonshine-base sensevoice-small

# Alternative: simctl mode (uses simctl screenshot instead of XCUIScreenshot)
./scripts/ios-e2e-test.sh whisper-tiny
```

**Android** (11 models, UiAutomator2):
```bash
# Run all 11 models (builds, installs, and runs each test)
./scripts/android-e2e-test.sh

# Run a single model
./scripts/android-e2e-test.sh whisper-tiny

# Run multiple specific models
./scripts/android-e2e-test.sh whisper-tiny moonshine-base sensevoice-small
```

**Evidence output:**
```
artifacts/e2e/
  ios/
    whisper-tiny/
      01_model_loading.png
      02_model_loaded.png       # (XCUITest mode)
      03_inference_result.png
      result.json               # { model_id, engine, pass, transcript, duration_ms }
    ...
    audit_report.md
  android/
    whisper-tiny/
      01_model_selected.png
      02_model_loaded.png
      03_inference_result.png
      result.json
    ...
    audit_report.md
```

**Known limitations:**
- `whisper-large-v3-turbo` OOMs on Android emulator (works on physical devices with 8+ GB RAM)
- `moonshine-tiny` may timeout on iOS (slow model download/load on first run)
- `omnilingual-300m` outputs whitespace for short English audio (model limitation)

### User Flow UI Tests

These tests exercise 10 common user interaction patterns (launch, record, save, delete, settings, model switch, etc.) without requiring model downloads — they use whichever model is already loaded.

**iOS** (10 tests, XCUITest):
```bash
# Run all 10 user flow tests
./scripts/ios-ui-flow-tests.sh

# Run a single test
./scripts/ios-ui-flow-tests.sh test_02_testFileTranscription

# Run multiple specific tests
./scripts/ios-ui-flow-tests.sh test_01_appLaunchAndModelLoad test_05_saveAndHistory
```

**Android** (10 tests, UiAutomator2):
```bash
# Run all 10 user flow tests
./scripts/android-userflow-test.sh

# Run a single test
./scripts/android-userflow-test.sh test_01_micButtonToggle

# Run multiple specific tests
./scripts/android-userflow-test.sh test_01_micButtonToggle test_06_saveAndViewHistory
```

**User flow tests:**

| # | iOS Test | Android Test | What It Tests |
|---|----------|-------------|---------------|
| 01 | appLaunchAndModelLoad | micButtonToggle | App launch / mic button states |
| 02 | testFileTranscription | micRecordAndTranscribe | Transcription from audio |
| 03 | recordButtonStates | settingsBottomSheet | Record button / settings UI |
| 04 | settingsNavigation | settingsToggleVAD | Settings navigation / VAD toggle |
| 05 | saveAndHistory | changeModelFlow | Save transcript / model switch |
| 06 | historyEmptyAndDelete | saveAndViewHistory | History CRUD |
| 07 | overflowMenuCopyAndClear | copyTranscript | Copy / clear actions |
| 08 | modelSwitchInSettings | clearTranscription | Model switch / clear |
| 09 | tabSwitchPreservesState | recordWhileNoModel | Tab persistence / error handling |
| 10 | modelSetupOnboarding | historyDeleteItem | Onboarding / delete |

Evidence screenshots are saved to `artifacts/ui-flow-tests/`.

## Use Cases
- Private meeting/interview transcription without cloud upload
- Field data collection in offline/limited-network environments
- Fast on-device dictation and note capture
- ASR model quality comparison across engines
- Device performance benchmarking (CPU, memory, tokens/sec)

## Privacy

- All audio and transcripts are processed and stored locally on device
- Network access is only required for initial model download
- No cloud transcription or analytics services are used

## Known Limitations
- Android emulator microphone behavior varies by host audio backend
- iOS test results depend on locally cached model state
- whisper-large-v3-turbo OOMs on Android emulator (works on physical devices)
- Moonshine Tiny times out on iOS CI (model download/load time)
- Omnilingual 300M outputs whitespace for English (model limitation for short utterances)

## Credits

### ASR Engines
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) (iOS CoreML)
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (Android JNI submodule)
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (cross-platform ONNX Runtime)
- [FluidAudio](https://github.com/FluidInference/FluidAudio) (iOS CoreML, Parakeet-TDT)
- [OpenAI Whisper](https://github.com/openai/whisper) (original model research)
- [ONNX Runtime](https://github.com/microsoft/onnxruntime)

### iOS Dependencies
- [swift-collections](https://github.com/apple/swift-collections)
- [swift-transformers](https://github.com/huggingface/swift-transformers)
- [swift-jinja](https://github.com/huggingface/swift-jinja)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

### Android Dependencies
- [Kotlin](https://github.com/JetBrains/kotlin)
- [AndroidX](https://github.com/androidx/androidx) (Compose, Room, DataStore, Navigation, Lifecycle)
- [OkHttp](https://github.com/square/okhttp)
- [kotlinx.coroutines](https://github.com/Kotlin/kotlinx.coroutines)

## License

This application's source code is licensed under the **Apache License 2.0**. See `LICENSE`.

**Model weights are downloaded at runtime and have their own licenses:**

| Model | License | Commercial Use | Source |
|-------|---------|---------------|--------|
| Whisper (OpenAI) | MIT / Apache 2.0 | Yes | [openai/whisper](https://github.com/openai/whisper) |
| Moonshine (Useful Sensors) | MIT | Yes | [moonshine-ai/moonshine](https://github.com/moonshine-ai/moonshine) |
| SenseVoice (FunAudioLLM) | MIT / [FunASR Model License](https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE) | Yes (with attribution) | [FunAudioLLM/SenseVoice](https://github.com/FunAudioLLM/SenseVoice) |
| Zipformer (k2-fsa) | Apache 2.0 | Yes | [k2-fsa/icefall](https://github.com/k2-fsa/icefall) |
| Parakeet TDT (NVIDIA) | CC-BY-4.0 | Yes (attribution required) | [nvidia/parakeet-tdt-0.6b](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) |
| Omnilingual/MMS (Meta) | **CC-BY-NC-4.0** | **Non-commercial only** | [facebook/mms-1b-all](https://huggingface.co/facebook/mms-1b-all) |

See `NOTICE` for full attribution details and license terms.

## Repository Notes

- `OfflineTranscriptionAndroid/whisper.cpp` is a git submodule
- Binary dependencies are gitignored and must be set up separately:
  - `OfflineTranscriptionAndroid/app/libs/*.aar` (sherpa-onnx)
  - `LocalPackages/SherpaOnnxKit/*.xcframework/` (sherpa-onnx iOS)

## Creator

Created and maintained by **Akinori Nakajima** ([atyenoria](https://github.com/atyenoria)).

<!-- BENCHMARK_RESULTS_START -->
### Inference Token Speed Benchmarks

Measured from E2E `result.json` files using a longer English fixture.

Fixture: `artifacts/benchmarks/long_en_eval.wav` (30.00s, 16kHz mono WAV)

#### Evaluation Method

- Per-model E2E runs with the same English fixture on each platform.
- `duration_sec = duration_ms / 1000` from each model `result.json`.
- `token_count` is computed from transcript words: `[A-Za-z0-9']+`.
- `tok/s = token_count / duration_sec`.
- `RTF = audio_duration_sec / duration_sec`.

#### iOS Graph

![iOS tokens/sec](artifacts/benchmarks/ios_tokens_per_second.svg)

#### iOS Results

| Model | Engine | Words | Duration (s) | Tok/s | RTF | Pass |
|---|---|---:|---:|---:|---:|---|
| `whisper-tiny` | CoreML (WhisperKit) | 0 | 8.95 | 0.00 | 3.35 | FAIL |
| `whisper-base` | CoreML (WhisperKit) | 209 | 30.23 | 6.91 | 0.99 | FAIL |
| `whisper-small` | CoreML (WhisperKit) | 58 | 52.20 | 1.11 | 0.57 | PASS |
| `whisper-large-v3-turbo` | CoreML (WhisperKit) | 59 | 324.20 | 0.18 | 0.09 | PASS |
| `whisper-large-v3-turbo-compressed` | - | 0 | n/a | n/a | n/a | FAIL |
| `moonshine-tiny` | sherpa-onnx offline (ONNX Runtime) | 58 | 1.13 | 51.12 | 26.44 | PASS |
| `moonshine-base` | sherpa-onnx offline (ONNX Runtime) | 58 | 2.01 | 28.82 | 14.90 | PASS |
| `sensevoice-small` | sherpa-onnx offline (ONNX Runtime) | 58 | 4.48 | 12.93 | 6.69 | PASS |
| `zipformer-20m` | sherpa-onnx streaming (ONNX Runtime) | 0 | 0.04 | 0.00 | 720.36 | FAIL |
| `omnilingual-300m` | sherpa-onnx offline (ONNX Runtime) | 0 | 24.82 | 0.00 | 1.21 | FAIL |
| `parakeet-tdt-v3` | CoreML (FluidAudio) | 58 | 9.74 | 5.96 | 3.08 | PASS |

#### Android Graph

![Android tokens/sec](artifacts/benchmarks/android_tokens_per_second.svg)

#### Android Results

| Model | Engine | Words | Duration (s) | Tok/s | RTF | Pass |
|---|---|---:|---:|---:|---:|---|
| `whisper-tiny` | - | 0 | n/a | n/a | n/a | FAIL |
| `whisper-base` | - | 0 | n/a | n/a | n/a | FAIL |
| `whisper-base-en` | - | 0 | n/a | n/a | n/a | FAIL |
| `whisper-small` | - | 0 | n/a | n/a | n/a | FAIL |
| `whisper-large-v3-turbo` | - | 0 | n/a | n/a | n/a | FAIL |
| `whisper-large-v3-turbo-compressed` | - | 0 | n/a | n/a | n/a | FAIL |
| `moonshine-tiny` | - | 0 | n/a | n/a | n/a | FAIL |
| `moonshine-base` | - | 0 | n/a | n/a | n/a | FAIL |
| `sensevoice-small` | - | 0 | n/a | n/a | n/a | FAIL |
| `omnilingual-300m` | - | 0 | n/a | n/a | n/a | FAIL |
| `zipformer-20m` | sherpa-onnx streaming (ONNX Runtime) | 55 | 1.19 | 46.33 | 25.27 | PASS |

#### Reproduce

1. `rm -rf artifacts/e2e/ios/* artifacts/e2e/android/*`
2. `TARGET_SECONDS=30 scripts/prepare-long-eval-audio.sh`
3. `EVAL_WAV_PATH=artifacts/benchmarks/long_en_eval.wav scripts/ios-e2e-test.sh`
4. `INSTRUMENT_TIMEOUT_SEC=300 EVAL_WAV_PATH=artifacts/benchmarks/long_en_eval.wav scripts/android-e2e-test.sh`
5. `python3 scripts/generate-inference-report.py --audio artifacts/benchmarks/long_en_eval.wav --update-readme`

One-command runner: `TARGET_SECONDS=30 scripts/run-inference-benchmarks.sh`

<!-- BENCHMARK_RESULTS_END -->
