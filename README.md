# VoicePing iOS + Android Offline Speech Translation

Cross-platform (iOS + Android) app for **fully offline speech-to-text transcription, text translation, and text-to-speech** — all inference runs on-device with no cloud dependency.

- **Transcription**: Record speech and transcribe it locally using multiple ASR engines (Whisper, Moonshine, SenseVoice, Zipformer, Parakeet). Batch and real-time streaming modes.
- **Translation**: Translate transcribed text on-device (iOS: Apple Translation framework, Android: TranslationManager API).
- **Text-to-Speech**: Read text aloud using native TTS (iOS: AVSpeechSynthesizer, Android: TextToSpeech API).
- **Audio Playback & Export**: Save session audio as WAV, play back with waveform scrubber, and export sessions as ZIP.

Models are downloaded once from HuggingFace, then all processing works completely offline.

## Features

### Both Platforms
- Real-time microphone recording with live transcript rendering
- Multiple ASR engine backends with in-app model switching
- On-device model download with progress tracking
- Streaming transcription (Zipformer transducer, endpoint-based)
- On-device translation
- Text-to-speech playback
- Voice Activity Detection (VAD) toggle
- Optional timestamp display
- Session audio saving as WAV (PCM 16kHz mono 16-bit)
- Audio playback with 200-bar waveform scrubber
- ZIP export of session (transcription + audio)
- Transcription history with save, copy, share, delete
- Live audio energy visualization
- CPU / memory / tokens-per-second telemetry display
- Storage guard before large model downloads

### iOS (SwiftUI + SwiftData)
- 4 ASR engines: WhisperKit (CoreML), sherpa-onnx offline, sherpa-onnx streaming, FluidAudio (Parakeet-TDT)
- 11 models across 6 families
- Apple Translation framework (iOS 18+)
- AVSpeechSynthesizer TTS
- AVAudioSession interruption + route change handling
- Zero-dependency ZIP via NSFileCoordinator

### Android (Kotlin + Compose + Room)
- 3 ASR engines: whisper.cpp (JNI), sherpa-onnx offline, sherpa-onnx streaming
- 11 models across 5 families
- TranslationManager API (Android 12+)
- TextToSpeech API
- Room database with manual migration (v1 to v2)
- FileProvider-based session sharing

## Supported Models

### iOS (11 models)

| Model | Engine | Size | Params | Languages |
|-------|--------|------|--------|-----------|
| Whisper Tiny | WhisperKit (CoreML) | ~80 MB | 39M | 99 languages |
| Whisper Base | WhisperKit (CoreML) | ~150 MB | 74M | 99 languages |
| Whisper Small | WhisperKit (CoreML) | ~500 MB | 244M | 99 languages |
| Whisper Large V3 Turbo | WhisperKit (CoreML) | ~600 MB | 809M | 99 languages |
| Whisper Large V3 Turbo (Compressed) | WhisperKit (CoreML) | ~1 GB | 809M | 99 languages |
| Moonshine Tiny | sherpa-onnx | ~125 MB | 27M | English |
| Moonshine Base | sherpa-onnx | ~280 MB | 61M | English |
| SenseVoice Small | sherpa-onnx | ~240 MB | 234M | zh/en/ja/ko/yue |
| Omnilingual 300M | sherpa-onnx | ~365 MB | 300M | 1,600+ languages |
| Zipformer Streaming | sherpa-onnx | ~46 MB | 20M | English |
| Parakeet TDT 0.6B | FluidAudio (CoreML) | ~600 MB | 600M | 25 European languages |

### Android (11 models)

| Model | Engine | Size | Params | Languages |
|-------|--------|------|--------|-----------|
| Whisper Tiny | whisper.cpp | ~80 MB | 39M | 99 languages |
| Whisper Base | whisper.cpp | ~150 MB | 74M | 99 languages |
| Whisper Base (.en) | whisper.cpp | ~150 MB | 74M | English |
| Whisper Small | whisper.cpp | ~500 MB | 244M | 99 languages |
| Whisper Large V3 Turbo | whisper.cpp | ~1.6 GB | 809M | 99 languages |
| Whisper Large V3 Turbo (q8_0) | whisper.cpp | ~834 MB | 809M | 99 languages |
| Moonshine Tiny | sherpa-onnx | ~125 MB | 27M | English |
| Moonshine Base | sherpa-onnx | ~290 MB | 62M | English |
| SenseVoice Small | sherpa-onnx | ~240 MB | 234M | zh/en/ja/ko/yue |
| Omnilingual 300M | sherpa-onnx | ~365 MB | 300M | 1,600+ languages |
| Zipformer Streaming | sherpa-onnx | ~46 MB | 20M | English |

### Experimental Model Card (iOS + Android)

| Model | Runtime Label | Status |
|-------|---------------|--------|
| TinyLlama 1.1B (ik_llama.cpp) | ik_llama.cpp (GGUF; Metal on iOS, NDK/JNI on Android) | Card only (not selectable). Runtime bridge is not integrated yet. |

## Architecture

### iOS

```
┌───────────────────────────────────────────────────────────────┐
│                   OfflineTranscriptionApp (SwiftUI)            │
├───────────────────────────────────────────────────────────────┤
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────────────┐  │
│  │Transcription │ │ History /    │ │ ModelSetupView       │  │
│  │View          │ │ DetailView   │ │                      │  │
│  └──────┬───────┘ └──────┬───────┘ └──────────┬───────────┘  │
│         │                │                     │              │
├─────────▼────────────────▼─────────────────────▼──────────────┤
│                    WhisperService (Orchestrator)               │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │ ASREngine: WhisperKit | SherpaOnnxOffline |              │ │
│  │            SherpaOnnxStreaming | FluidAudio              │ │
│  └──────────────────────────────────────────────────────────┘ │
│                                                                │
│  ┌────────────────┐ ┌─────────────────┐ ┌─────────────────┐  │
│  │ AudioRecorder  │ │ AppleTranslation│ │ NativeTTS       │  │
│  │ (AVAudioEngine)│ │ Service (iOS18+)│ │ (AVSpeech)      │  │
│  └────────────────┘ └─────────────────┘ └─────────────────┘  │
│  ┌────────────────┐ ┌─────────────────┐ ┌─────────────────┐  │
│  │ ModelDownloader│ │ SessionFile     │ │ SystemMetrics   │  │
│  │ (URLSession)   │ │ Manager + ZIP   │ │                 │  │
│  └────────────────┘ └─────────────────┘ └─────────────────┘  │
│                                                                │
├───────────────────────────────────────────────────────────────┤
│  SwiftData: TranscriptionRecord | sessions/{uuid}/audio.wav   │
└───────────────────────────────────────────────────────────────┘
```

### Android

```
┌───────────────────────────────────────────────────────────────┐
│              MainActivity (Compose + Navigation)               │
├───────────────────────────────────────────────────────────────┤
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────────────┐  │
│  │Transcription │ │ History /    │ │ ModelSetupScreen     │  │
│  │Screen        │ │ DetailScreen │ │                      │  │
│  └──────┬───────┘ └──────┬───────┘ └──────────┬───────────┘  │
│         │                │                     │              │
├─────────▼────────────────▼─────────────────────▼──────────────┤
│                    WhisperEngine (Orchestrator)                │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │ AsrEngine: WhisperCpp (JNI) | SherpaOnnx |              │ │
│  │            SherpaOnnxStreaming                            │ │
│  └──────────────────────────────────────────────────────────┘ │
│                                                                │
│  ┌────────────────┐ ┌─────────────────┐ ┌─────────────────┐  │
│  │ AudioRecorder  │ │ AndroidNative   │ │ AndroidTts      │  │
│  │ (AudioRecord)  │ │ Translator      │ │ Service         │  │
│  └────────────────┘ └─────────────────┘ └─────────────────┘  │
│  ┌────────────────┐ ┌─────────────────┐ ┌─────────────────┐  │
│  │ ModelDownloader│ │ AudioPlayback   │ │ SystemMetrics   │  │
│  │ (OkHttp)      │ │ + Waveform +    │ │                 │  │
│  │               │ │ SessionExporter │ │                 │  │
│  └────────────────┘ └─────────────────┘ └─────────────────┘  │
│                                                                │
├──────────────────────────────┬────────────────────────────────┤
│ Room DB + DataStore          │ whisper.cpp (CMake → JNI)      │
│ TranscriptionEntity          │ libwhisper.so + WhisperLib.kt  │
│ sessions/{uuid}/audio.wav    │                                │
└──────────────────────────────┴────────────────────────────────┘
```

## Translation

### iOS — Apple Translation Framework
- Available on **iOS 18+**
- Uses `TranslationSession` for on-device neural translation
- Language packs downloaded via iOS Settings > Translate

### Android — TranslationManager API
- Available on **Android 12+ (API 31)**
- Uses `android.view.translation.TranslationManager` for on-device translation
- Language support depends on device OEM and installed packs

## Text-to-Speech

### iOS — AVSpeechSynthesizer
- Configurable speech rate and voice selection
- Pauses recording during playback to prevent feedback

### Android — TextToSpeech API
- Speech rate 0.25x–2.0x, configurable locale
- Falls back to US English if requested locale unavailable

## Setup

### iOS
**Requirements:** macOS, Xcode 15+, iOS 17+ simulator or device, XcodeGen (`brew install xcodegen`)

```bash
xcodegen generate
open VoicePingIOSAndroidOfflineSpeechTranslation.xcodeproj
```

### Android
**Requirements:** Android Studio (or SDK/NDK), JDK 17, Android SDK 35, CMake 3.22.1

```bash
# Clone with submodules (whisper.cpp)
git clone --recurse-submodules <repo-url>

# Download sherpa-onnx AAR
./VoicePingIOSAndroidOfflineSpeechTranslationAndroid/setup-deps.sh

# Build
cd VoicePingIOSAndroidOfflineSpeechTranslationAndroid
./gradlew assembleDebug
```

## Testing

### iOS
```bash
# Unit tests (~110 tests, 8 suites)
xcodebuild test -scheme OfflineTranscription \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:OfflineTranscriptionTests
```

### Android
```bash
# Unit tests (170 tests, 8 classes)
cd VoicePingIOSAndroidOfflineSpeechTranslationAndroid
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
  ./gradlew testDebugUnitTest
```

### E2E & User Flow Tests
```bash
# E2E model evidence tests
./scripts/ios-e2e-test.sh --xcuitest
./scripts/android-e2e-test.sh

# User flow UI tests
./scripts/ios-ui-flow-tests.sh
./scripts/android-userflow-test.sh
```

## Tech Stack

| | iOS | Android |
|---|---|---|
| Language | Swift 5.9 | Kotlin 2.1 |
| UI | SwiftUI | Jetpack Compose + Material3 |
| Persistence | SwiftData | Room + DataStore |
| ASR | WhisperKit, sherpa-onnx, FluidAudio | whisper.cpp (JNI), sherpa-onnx |
| Translation | Apple Translation (iOS 18+) | TranslationManager (API 31+) |
| TTS | AVSpeechSynthesizer | TextToSpeech API |
| Min OS | iOS 17.0 | Android 8.0 (API 26) |

## Privacy

- All audio, transcripts, and translations are processed and stored locally on device
- Network access is only required for initial model and language pack downloads
- No cloud transcription, translation, or analytics services are used

## License

Apache License 2.0. See `LICENSE`.

Model weights are downloaded at runtime and have their own licenses — see `NOTICE`.

## Creator

Created by **Akinori Nakajima** ([atyenoria](https://github.com/atyenoria)).
