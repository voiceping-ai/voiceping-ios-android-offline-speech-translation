# Windows Offline Transcribe

WinUI 3 (Windows App SDK) desktop app for offline speech transcription.
All ASR inference runs locally after model download.

## Current Scope (Code-Accurate)

- Live transcription with confirmed text plus rolling hypothesis.
- Audio source switching: `Microphone`, `System Audio (WASAPI loopback)`.
- In-app model download/load/switch (9 models across 3 engine types).
- File transcription (`.wav`, `.mp3`).
- Runtime stats while recording (`CPU`, `RAM`, `tok/s`, elapsed audio). Note: `tok/s` is a rough word-per-second estimate.
- History: saves transcript + session audio; export a shareable ZIP (text + metadata + audio).
- Diagnostics: `Evidence Mode` (events.jsonl + model manifests + screenshots; export one ZIP).

## Supported Models

Defined in `src/OfflineSpeechTranslation/Models/ModelInfo.cs`.
Models are downloaded from Hugging Face at runtime and stored under `%LOCALAPPDATA%\\OfflineSpeechTranslation\\Models\\<model-id>\\`.

| Model ID | Engine | Params | Disk | Languages |
|---|---|---:|---:|---|
| `whisper-tiny` | whisper.cpp (C++/P-Invoke) | 39M | ~80 MB | 99 languages |
| `whisper-base` | whisper.cpp (C++/P-Invoke) | 74M | ~150 MB | 99 languages |
| `whisper-small` | whisper.cpp (C++/P-Invoke) | 244M | ~500 MB | 99 languages |
| `whisper-large-v3-turbo` | whisper.cpp (C++/P-Invoke) | 809M | ~834 MB | 99 languages |
| `sensevoice-small` | sherpa-onnx offline (ONNX Runtime) | 234M | ~240 MB | `zh/en/ja/ko/yue` |
| `moonshine-tiny` | sherpa-onnx offline (ONNX Runtime) | 27M | ~125 MB | English |
| `moonshine-base` | sherpa-onnx offline (ONNX Runtime) | 61M | ~290 MB | English |
| `omnilingual-300m` | sherpa-onnx offline (ONNX Runtime) | 300M | ~365 MB | 1,600+ languages |
| `zipformer-20m` | sherpa-onnx streaming (ONNX Runtime) | 20M | ~73 MB | English |

Model weights are not distributed with this repo; model licensing varies. See `NOTICE`.

> **Want to see a new model or device benchmark?** If there is an offline ASR model you would like added, or you have benchmark results to share from your hardware, please [open an issue](https://github.com/atyenoria/windows-offline-transcribe/issues/new). Community contributions of inference benchmarks on different Windows devices are welcome.

## Engines / Inference Methods

This app has two inference paths:

### Live Recording (Microphone / Loopback)

- `sherpa-onnx streaming` (Zipformer):
  - True streaming decode (100 ms audio chunks).
  - Endpoint detection commits "confirmed" text on silence and resets the stream.
- `whisper.cpp` and `sherpa-onnx offline`:
  - Chunk-based loop while recording.
  - Window size: ~15 s for whisper.cpp, ~3.5 s for sherpa-onnx offline.
  - Optional VAD: skips work when recent audio energy is below a threshold.
  - Prefix-match between consecutive results to split confirmed text vs rolling hypothesis.

Provider selection:
- `sherpa-onnx offline` probes `DirectML` first and falls back to `CPU`.
- `sherpa-onnx streaming` uses `CPU` for stable real-time behavior.

### File Transcription

- Uses NAudio to decode audio, resamples to 16 kHz mono Float32, and runs a single engine pass.

## Prereqs

- Windows 10/11 (x64)
- Visual Studio 2022 or newer
- .NET 8 SDK

## Native Dependencies

This app uses native engines via P/Invoke:

- whisper.cpp: `whisper.dll` (see `src/OfflineSpeechTranslation/Interop/WhisperNative.cs`)
- sherpa-onnx C API: `sherpa-onnx-c-api.dll` (see `src/OfflineSpeechTranslation/Interop/SherpaOnnxNative.cs`)

Place required `.dll` files in:

- `libs/runtimes/win-x64/`

They are copied to the build output directory by `src/OfflineSpeechTranslation/OfflineSpeechTranslation.csproj`.

If you use the sherpa-onnx release bundle, make sure you also include its dependent DLLs
(for example `onnxruntime.dll` and DirectML-related DLLs if applicable).

## Build

Open `OfflineSpeechTranslation.sln` and build `x64` (`Debug` or `Release`).

## Diagnostics

- `Save Screenshot` writes PNGs under `%LOCALAPPDATA%\\OfflineSpeechTranslation\\Diagnostics\\`
- `Evidence Mode` writes under `%LOCALAPPDATA%\\OfflineSpeechTranslation\\Evidence\\` and can export a single evidence ZIP.

See `DEVICE_TESTING.md` for a real-device test checklist.

## Tests

```powershell
dotnet test tests/OfflineSpeechTranslation.Tests/OfflineSpeechTranslation.Tests.csproj -c Release
```

## Privacy

- Audio and transcription are processed locally.
- Network is used for model downloads only.
- History and exported ZIPs may contain transcripts and audio.
- Evidence Mode can optionally include transcript text (toggle in Settings).

## License

Apache License 2.0. See `LICENSE` and `NOTICE`.
