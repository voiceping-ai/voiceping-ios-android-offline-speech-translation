# OfflineSpeechTranslation.NativeTranslation

Native C++ DLL that wraps CTranslate2 + SentencePiece behind a small C ABI so the WinUI app can call it via P/Invoke.

## Expected Model Layout

The WinUI app downloads a translation model as a `.zip` and extracts it to:

`%LOCALAPPDATA%\\OfflineSpeechTranslation\\TranslationModels\\<model-id>\\model\\`

The extracted folder is passed to `OST_CreateTranslator(model_dir)`.

This wrapper expects the folder to contain:

- A CTranslate2 model directory (files like `model.bin`, `config.json`, etc.) at the root
- Tokenizers:
  - `source.spm` and `target.spm`, or
  - a shared `spm.model` (used for both src/tgt)

If no SentencePiece model is found, the wrapper falls back to whitespace tokenization (English-only quality).

## Build (Windows)

This repo does not vendor CTranslate2 or SentencePiece to keep checkout size small.
Install/build those libraries and make them discoverable to CMake, then build this DLL.

Example:

```powershell
cmake -S . -B build -A x64 -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="C:\\deps\\install"
cmake --build build --config Release
```

Copy the built `OfflineSpeechTranslation.NativeTranslation.dll` (and any dependent DLLs) into:

`WindowsOfflineSpeechTranslation\\libs\\runtimes\\win-x64\\`

They will be copied next to the app `.exe` during build.

