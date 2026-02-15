# Device Test Matrix (Windows)

This project targets WinUI 3 (.NET 8) and uses native DLL engines. Most bugs show up only on a real Windows machine, so use this checklist to validate before shipping.

## Setup

1. Put native DLLs in `libs/runtimes/win-x64/` (they get copied next to the exe on build).
2. Build `OfflineSpeechTranslation.sln` for `x64`.
3. Run the app once to create:
   - `%LOCALAPPDATA%\\OfflineSpeechTranslation\\settings.json`
   - `%LOCALAPPDATA%\\OfflineSpeechTranslation\\transcriptions.db`

## Evidence Collection (Real Device Proof)

If you want screenshots + model/file evidence for each action (recommended for bug reports):

1. Open `Settings` -> enable `Evidence Mode`.
   - This starts a new evidence session folder under:
     - `%LOCALAPPDATA%\\OfflineSpeechTranslation\\Evidence\\`
2. Run the test cases below.
   - The app will auto-log actions and auto-capture screenshots on major state changes (navigation, model state, recording state).
3. When finished: `Settings` -> `Export Evidence ZIP`.
   - Share the exported ZIP when reporting bugs. It contains:
     - `events.jsonl` (timeline of actions/state)
     - `device.json` (OS/runtime info)
     - `models/*.json` (model files present + sizes, plus hashes for small files)
     - `screenshots/*.png`

## Functional Cases

### First Launch / Model Setup

- Launch with no `SelectedModelId`.
  - Expected: `ModelSetupPage` is shown.
- Select each model and let it download.
  - Expected: progress text + progress bar update; app remains responsive.
- Disable network mid-download.
  - Expected: error dialog; app doesn't hang; retry works after network returns.
- Missing native DLLs (remove `whisper.dll` / `sherpa-onnx-c-api.dll` from output).
  - Expected: clear error dialog showing the missing DLL or entry point.

### Model Persistence

- Quit and relaunch after a model is loaded and downloaded.
  - Expected: app navigates to `TranscriptionPage` and auto-loads the saved model.

### Recording (Microphone)

- Settings -> `Capture Source = Microphone`.
- Start recording, speak, stop.
  - Expected: Confirmed + hypothesis text update while recording, final text saved when stopping.
- Rapid toggle record (start/stop 5-10 times quickly).
  - Expected: no crash, UI state stays correct, no stuck "recording" indicator.
- Microphone blocked (Windows privacy settings off).
  - Expected: start fails gracefully with an error (not a silent no-op).

### Recording (System Audio / Loopback)

- Settings -> `Capture Source = System Audio (Loopback)`.
- Play a YouTube/video/music track; start recording; stop.
  - Expected: transcription reflects the played audio.
- Multi-channel output configs (5.1/7.1).
  - Expected: no crash; audio is down-mixed to mono and transcribed.

### VAD / Non-Speech

- Enable/disable VAD while idle.
  - Expected: preference persists after restart.
- Long silence while recording (30-60s).
  - Expected: CPU usage drops (no constant inference), app stays responsive.

### File Transcription

- Transcribe `.wav` (16k mono), `.wav` (44.1k stereo), `.mp3`.
  - Expected: decode succeeds; transcription runs; result saved to history.

### History / Export

- Verify new transcriptions appear in History.
  - Expected: list shows newest first; opening a record shows full text.
- Delete a history item.
  - Expected: DB row removed and `%LOCALAPPDATA%\\OfflineSpeechTranslation\\Sessions\\{id}` deleted.
- Export ZIP from detail view.
  - Expected: ZIP contains `transcript.txt`, `metadata.json`, and `audio.wav` if available.

### Screenshot Capture (For Bug Reports)

- Settings -> `Save Screenshot`.
  - Expected: a PNG is written under `%LOCALAPPDATA%\\OfflineSpeechTranslation\\Diagnostics\\`.
  - Use this when reporting UI bugs or incorrect states.

## Stress / Edge Cases

- Record continuously past 30 minutes.
  - Expected: app does not grow unbounded in memory; capture keeps newest buffer.
- Start recording, then switch model from Settings.
  - Expected: switching is blocked while busy (no crash, no corrupted state).
