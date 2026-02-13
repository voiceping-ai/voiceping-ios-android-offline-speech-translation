# VoicePing iOS + Android Offline Speech Translation

Cross-platform offline speech app with transcription, translation, TTS, and history/export flows.
This repository currently ships a focused model set per platform.

## Current Scope (Code-Accurate)

### iOS app (`OfflineTranscription`)

- ASR models: `SenseVoice Small` and `Apple Speech`.
- Audio source switching:
- `Voice` (microphone)
- `System` (ReplayKit Broadcast Upload Extension)
- Translation: Apple Translation framework bridge (`iOS 18+`).
- TTS: `AVSpeechSynthesizer` (`NativeTTSService`).
- History/details/export:
- SwiftData model (`TranscriptionRecord`)
- audio session files + ZIP export (`SessionFileManager`, `ZIPExporter`)

### Android app (`VoicePingIOSAndroidOfflineSpeechTranslationAndroid`)

- ASR models: `SenseVoice Small`, `Android Speech (Offline)`, `Android Speech (Online)`.
- Audio source switching:
- `Voice` (microphone)
- `System` (MediaProjection playback capture)
- Translation providers:
- ML Kit offline
- Android system translation (`API 31+`) via `AndroidSystemTranslator`
- TTS: `AndroidTtsService` (`TextToSpeech`).
- History/details/export:
- Room (`TranscriptionEntity`, `AppDatabase`)
- playback + waveform + ZIP export (`AudioPlaybackManager`, `SessionExporter`)

## Supported Models

### iOS (`OfflineTranscription/Models/ModelInfo.swift`)

| Model ID | Engine | Languages |
|---|---|---|
| `sensevoice-small` | sherpa-onnx offline | `zh/en/ja/ko/yue` |
| `apple-speech` | SFSpeechRecognizer | `50+ languages` |

### Android (`.../model/ModelInfo.kt`)

| Model ID | Engine | Languages |
|---|---|---|
| `sensevoice-small` | sherpa-onnx offline | `zh/en/ja/ko/yue` |
| `android-speech-offline` | Android SpeechRecognizer (on-device, API 31+) | `System languages` |
| `android-speech-online` | Android SpeechRecognizer (standard recognizer) | `System languages` |

## Architecture

### iOS

- Orchestrator: `OfflineTranscription/Services/WhisperService.swift`
- Engines:
- `SherpaOnnxOfflineEngine`
- `AppleSpeechEngine`
- Translation: `AppleTranslationService`
- TTS: `NativeTTSService`
- Persistence/export: SwiftData + `SessionFileManager` + `ZIPExporter`

### Android

- Orchestrator: `.../service/WhisperEngine.kt`
- Engines:
- `SherpaOnnxEngine`
- `AndroidSpeechEngine`
- Translation:
- `MlKitTranslator`
- `AndroidSystemTranslator`
- TTS: `AndroidTtsService`
- Persistence/export: Room + `AudioPlaybackManager` + `SessionExporter`

## Requirements

### iOS

- Xcode 15+
- iOS 17+
- `xcodegen`

### Android

- JDK 17
- Android SDK 35
- Android 8.0+ (`minSdk 26`)

## Setup

### iOS

```bash
git clone --recurse-submodules <repo-url>
cd ios-android-offline-speech-translation
scripts/setup-ios-deps.sh
scripts/generate-ios-project.sh
open VoicePingIOSAndroidOfflineSpeechTranslation.xcodeproj
```

### Android

```bash
cd VoicePingIOSAndroidOfflineSpeechTranslationAndroid
./setup-deps.sh
./gradlew assembleDebug
```

## Tests and Automation

```bash
# iOS
scripts/ci-ios-unit-test.sh
scripts/ios-e2e-test.sh
scripts/ios-ui-flow-tests.sh

# Android
scripts/ci-android-unit-test.sh
scripts/android-e2e-test.sh
scripts/android-userflow-test.sh
```

## Privacy

- Runtime transcription/translation/TTS are local on device.
- Network access is for model/language pack downloads and dependency setup.

## License

Apache License 2.0. See `LICENSE`.
