using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using OfflineSpeechTranslation.Interfaces;
using OfflineSpeechTranslation.Interop;
using OfflineSpeechTranslation.Models;

namespace OfflineSpeechTranslation.Engines;

/// <summary>
/// sherpa-onnx offline engine via P/Invoke. Supports SenseVoice, Moonshine, and OmnilingualCtc models.
/// Port of iOS SherpaOnnxOfflineEngine.swift.
/// </summary>
public sealed class SherpaOnnxOfflineEngine : IASREngine
{
    private IntPtr _recognizer = IntPtr.Zero;
    private readonly SemaphoreSlim _sem = new(1, 1);
    private bool _disposed;
    private SherpaModelType _modelType;
    private readonly SherpaModelType? _explicitModelType;
    private string _provider = "cpu";

    // Keep marshaled UTF-8 strings alive for the lifetime of the recognizer.
    // (Some native APIs may keep string pointers from the config struct.)
    private readonly Utf8StringPool _stringPool = new();

    public SherpaOnnxOfflineEngine(SherpaModelType? modelType = null)
    {
        _explicitModelType = modelType;
    }

    public bool IsLoaded => _recognizer != IntPtr.Zero;
    public bool IsStreaming => false;
    public string Provider => _provider;
    public SherpaModelType ModelType => _modelType;

    public async Task<bool> LoadModelAsync(string modelDir, CancellationToken ct = default)
    {
        await _sem.WaitAsync(ct);
        try
        {
            Release_Internal();

            return await Task.Run(() =>
            {
                // Use explicit model type if provided, otherwise detect from files
                _modelType = _explicitModelType ?? DetectModelType(modelDir);
                _provider = SelectProvider(modelDir);

                Debug.WriteLine($"[SherpaOnnx] Loading {_modelType} from {modelDir}, provider={_provider}");

                try
                {
                    var config = BuildConfig(modelDir, _modelType, _provider, _stringPool.Pin);
                    _recognizer = SherpaOnnxNative.CreateOfflineRecognizer(ref config);

                    if (_recognizer == IntPtr.Zero)
                    {
                        Debug.WriteLine("[SherpaOnnx] CreateOfflineRecognizer returned null");
                        _stringPool.Clear();
                        return false;
                    }

                    Debug.WriteLine($"[SherpaOnnx] Model loaded successfully, provider={_provider}");
                    return true;
                }
                catch (Exception ex)
                {
                    Debug.WriteLine($"[SherpaOnnx] Load failed: {ex.Message}");
                    // Ensure we don't leak pinned UTF-8 strings on failure.
                    _stringPool.Clear();
                    throw;
                }
            }, ct);
        }
        finally
        {
            _sem.Release();
        }
    }

    public async Task<ASRResult> TranscribeAsync(
        float[] audioSamples,
        int numThreads,
        string language,
        CancellationToken ct = default)
    {
        if (!IsLoaded) return ASRResult.Empty;

        await _sem.WaitAsync(ct);
        try
        {
            var recognizer = _recognizer;
            if (recognizer == IntPtr.Zero) return ASRResult.Empty;

            var sw = Stopwatch.StartNew();

            var result = await Task.Run(() =>
            {
                var stream = SherpaOnnxNative.CreateOfflineStream(recognizer);
                if (stream == IntPtr.Zero) return ASRResult.Empty;

                try
                {
                    SherpaOnnxNative.AcceptWaveformOffline(stream, 16000, audioSamples, audioSamples.Length);
                    SherpaOnnxNative.DecodeOfflineStream(recognizer, stream);

                    var resultPtr = SherpaOnnxNative.GetOfflineStreamResult(stream);
                    var text = SherpaOnnxNative.ReadResultText(resultPtr);
                    SherpaOnnxNative.DestroyOfflineRecognizerResult(resultPtr);

                    // Language: avoid reading unstable struct offsets from the C API result.
                    // SenseVoice may embed language tokens like "<|en|>" in the text itself.
                    string? lang = null;
                    if (_modelType == SherpaModelType.SenseVoice)
                        lang = TryExtractSenseVoiceLanguage(ref text);
                    else if (_modelType == SherpaModelType.Moonshine)
                        lang = "en";
                    // OmnilingualCtc: model outputs text directly, no language detection

                    // Strip CJK spaces for SenseVoice output
                    if (_modelType == SherpaModelType.SenseVoice)
                        text = StripCjkSpaces(text);

                    text = text.Trim();

                    var segments = string.IsNullOrEmpty(text)
                        ? Array.Empty<ASRSegment>()
                        : new[] { new ASRSegment(text, DetectedLanguage: lang) };

                    return new ASRResult(text, segments, lang);
                }
                finally
                {
                    SherpaOnnxNative.DestroyOfflineStream(stream);
                }
            }, ct);

            sw.Stop();
            return result with { InferenceTimeMs = sw.Elapsed.TotalMilliseconds };
        }
        finally
        {
            _sem.Release();
        }
    }

    public void Release()
    {
        _sem.Wait();
        try { Release_Internal(); }
        finally { _sem.Release(); }
    }

    private void Release_Internal()
    {
        if (_recognizer != IntPtr.Zero)
        {
            SherpaOnnxNative.DestroyOfflineRecognizer(_recognizer);
            _recognizer = IntPtr.Zero;
            Debug.WriteLine("[SherpaOnnx] Recognizer released");
        }
        _stringPool.Clear();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Release();
        _sem.Dispose();
    }

    // ── Provider selection ──

    private string SelectProvider(string modelDir)
    {
        // Try DirectML first via recognizer creation (no sine-wave probe)
        try
        {
            using var probePool = new Utf8StringPool();
            var config = BuildConfig(modelDir, _modelType, "directml", probePool.Pin);
            var testRecognizer = SherpaOnnxNative.CreateOfflineRecognizer(ref config);
            if (testRecognizer != IntPtr.Zero)
            {
                SherpaOnnxNative.DestroyOfflineRecognizer(testRecognizer);
                Debug.WriteLine("[SherpaOnnx] DirectML provider available");
                return "directml";
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[SherpaOnnx] DirectML probe failed: {ex.Message}");
        }

        Debug.WriteLine("[SherpaOnnx] Falling back to CPU provider");
        return "cpu";
    }

    // ── Config builders ──

    private static SherpaOnnxOfflineRecognizerConfig BuildConfig(
        string modelDir,
        SherpaModelType modelType,
        string provider,
        Func<string, IntPtr> pin)
    {
        var config = new SherpaOnnxOfflineRecognizerConfig();
        var modelConfig = new SherpaOnnxOfflineModelConfig();

        int threads = ComputeThreads();
        modelConfig.NumThreads = threads;
        modelConfig.Debug = false;
        modelConfig.Provider = pin(provider);
        modelConfig.Tokens = pin(Path.Combine(modelDir, "tokens.txt"));

        switch (modelType)
        {
            case SherpaModelType.SenseVoice:
                modelConfig.SenseVoice = new SherpaOnnxOfflineSenseVoiceModelConfig
                {
                    Model = pin(FindFile(modelDir, "model")),
                    Language = pin("auto"),
                    UseInverseTextNormalization = true
                };
                break;

            case SherpaModelType.Moonshine:
                modelConfig.Moonshine = new SherpaOnnxOfflineMoonshineModelConfig
                {
                    Preprocessor = pin(Path.Combine(modelDir, "preprocess.onnx")),
                    Encoder = pin(FindFile(modelDir, "encode")),
                    UncachedDecoder = pin(FindFile(modelDir, "uncached_decode")),
                    CachedDecoder = pin(FindFile(modelDir, "cached_decode"))
                };
                break;

            case SherpaModelType.OmnilingualCtc:
                modelConfig.NemoCtc = new SherpaOnnxOfflineNemoEncDecCtcModelConfig
                {
                    Model = pin(FindFile(modelDir, "model"))
                };
                break;

            default:
                throw new NotSupportedException($"Unsupported sherpa-onnx model type: {modelType}");
        }

        config.ModelConfig = modelConfig;
        config.DecodingMethod = pin("greedy_search");
        config.MaxActivePaths = 4;

        return config;
    }

    // ── Helpers ──

    internal static SherpaModelType DetectModelType(string modelDir)
    {
        if (File.Exists(Path.Combine(modelDir, "preprocess.onnx")))
            return SherpaModelType.Moonshine;
        if (Directory.Exists(modelDir) && Directory.GetFiles(modelDir, "model*onnx").Length > 0)
            return SherpaModelType.SenseVoice;
        throw new InvalidOperationException(
            $"Cannot detect sherpa-onnx model type in '{modelDir}': " +
            "expected preprocess.onnx (Moonshine) or model*.onnx (SenseVoice)");
    }

    internal static string FindFile(string dir, string prefix)
    {
        // Prefer int8 variant, fall back to regular
        var int8 = Path.Combine(dir, $"{prefix}.int8.onnx");
        if (File.Exists(int8)) return int8;
        var regular = Path.Combine(dir, $"{prefix}.onnx");
        if (File.Exists(regular)) return regular;
        return int8; // let sherpa-onnx report the error
    }

    private static int ComputeThreads() => ComputeThreads(Environment.ProcessorCount);

    internal static int ComputeThreads(int cores) => cores switch
    {
        <= 2 => 1,
        <= 4 => 2,
        <= 8 => 4,
        _ => 6
    };

    internal static string? TryExtractSenseVoiceLanguage(ref string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;

        // Common SenseVoice token format: "<|en|>", "<|zh|>", "<|ja|>", "<|ko|>", "<|yue|>".
        var match = Regex.Match(text, @"<\|(?<lang>[a-z]{2,3})\|>", RegexOptions.IgnoreCase);
        if (!match.Success) return null;

        var lang = match.Groups["lang"].Value.Trim().ToLowerInvariant();
        text = Regex.Replace(text, @"<\|[a-z]{2,3}\|>", "", RegexOptions.IgnoreCase).Trim();
        return lang;
    }

    /// <summary>
    /// Strip spaces between CJK characters in SenseVoice output.
    /// Port of iOS stripCJKSpaces.
    /// </summary>
    internal static string StripCjkSpaces(string text)
    {
        // CJK Unified Ideographs, Hiragana, Katakana, CJK Symbols.
        // Use lookbehind/lookahead so the CJK characters are not consumed,
        // allowing overlapping matches (A B C → ABC instead of AB C).
        return Regex.Replace(text,
            @"(?<=[\u3000-\u9FFF\uF900-\uFAFF])\s+(?=[\u3000-\u9FFF\uF900-\uFAFF])",
            "");
    }

    private sealed class Utf8StringPool : IDisposable
    {
        private readonly List<IntPtr> _ptrs = [];
        private bool _disposed;

        public IntPtr Pin(string value)
        {
            if (_disposed) throw new ObjectDisposedException(nameof(Utf8StringPool));
            // sherpa-onnx C API expects UTF-8 char*.
            var ptr = Marshal.StringToCoTaskMemUTF8(value);
            _ptrs.Add(ptr);
            return ptr;
        }

        public void Clear()
        {
            for (int i = 0; i < _ptrs.Count; i++)
            {
                if (_ptrs[i] != IntPtr.Zero)
                    Marshal.FreeCoTaskMem(_ptrs[i]);
            }
            _ptrs.Clear();
        }

        public void Dispose()
        {
            if (_disposed) return;
            Clear();
            _disposed = true;
        }
    }
}
