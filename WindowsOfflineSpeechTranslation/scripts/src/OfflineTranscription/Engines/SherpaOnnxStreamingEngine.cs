using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.RegularExpressions;
using OfflineSpeechTranslation.Interfaces;
using OfflineSpeechTranslation.Interop;
using OfflineSpeechTranslation.Models;

namespace OfflineSpeechTranslation.Engines;

/// <summary>
/// sherpa-onnx streaming engine via P/Invoke (OnlineRecognizer).
/// Supports Zipformer transducer models for real-time streaming transcription.
/// Port of Android SherpaOnnxStreamingEngine.kt.
/// </summary>
public sealed class SherpaOnnxStreamingEngine : IASREngine
{
    private IntPtr _recognizer = IntPtr.Zero;
    private IntPtr _stream = IntPtr.Zero;
    private readonly SemaphoreSlim _sem = new(1, 1);
    private bool _disposed;
    private string _provider = "cpu";
    private volatile string _latestText = "";

    // Keep marshaled UTF-8 strings alive for the lifetime of the recognizer.
    private readonly Utf8StringPool _stringPool = new();

    // Decode worker: serialises decode calls on a single background thread.
    private BlockingCollection<Action> _decodeQueue = new();
    private Task? _decodeWorker;
    private CancellationTokenSource? _decodeCts;

    private const int MaxDecodeStepsPerPass = 1024;
    private const int BatchStreamChunkSamples = 1600; // 100 ms @ 16 kHz

    public bool IsLoaded => _recognizer != IntPtr.Zero;
    public bool IsStreaming => true;
    public string Provider => _provider;

    public async Task<bool> LoadModelAsync(string modelDir, CancellationToken ct = default)
    {
        await _sem.WaitAsync(ct);
        try
        {
            Release_Internal();

            return await Task.Run(() =>
            {
                _provider = "cpu"; // streaming stays on CPU for stable real-time behavior

                Debug.WriteLine($"[SherpaOnnxStreaming] Loading from {modelDir}, provider={_provider}");

                try
                {
                    var tokensPath = Path.Combine(modelDir, "tokens.txt");
                    var encoderPath = FindFile(modelDir, "encoder");
                    var decoderPath = FindFileDecoder(modelDir, "decoder");
                    var joinerPath = FindFile(modelDir, "joiner");

                    Debug.WriteLine($"[SherpaOnnxStreaming] encoder={Path.GetFileName(encoderPath)}, " +
                        $"decoder={Path.GetFileName(decoderPath)}, joiner={Path.GetFileName(joinerPath)}");

                    int threads = ComputeStreamingThreads();

                    var config = BuildConfig(modelDir, tokensPath, encoderPath,
                        decoderPath, joinerPath, threads, _provider, _stringPool.Pin);

                    _recognizer = SherpaOnnxNative.CreateOnlineRecognizer(ref config);
                    if (_recognizer == IntPtr.Zero)
                    {
                        Debug.WriteLine("[SherpaOnnxStreaming] CreateOnlineRecognizer returned null");
                        _stringPool.Clear();
                        return false;
                    }

                    _stream = SherpaOnnxNative.CreateOnlineStream(_recognizer);
                    if (_stream == IntPtr.Zero)
                    {
                        Debug.WriteLine("[SherpaOnnxStreaming] CreateOnlineStream returned null");
                        SherpaOnnxNative.DestroyOnlineRecognizer(_recognizer);
                        _recognizer = IntPtr.Zero;
                        _stringPool.Clear();
                        return false;
                    }

                    // Start decode worker thread
                    _decodeCts = new CancellationTokenSource();
                    _decodeWorker = Task.Factory.StartNew(
                        () => DecodeWorkerLoop(_decodeCts.Token),
                        _decodeCts.Token,
                        TaskCreationOptions.LongRunning,
                        TaskScheduler.Default);

                    Debug.WriteLine($"[SherpaOnnxStreaming] Model loaded, provider={_provider}, threads={threads}");
                    return true;
                }
                catch (Exception ex)
                {
                    Debug.WriteLine($"[SherpaOnnxStreaming] Load failed: {ex.Message}");
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
                // Create a dedicated stream for batch transcription
                var batchStream = SherpaOnnxNative.CreateOnlineStream(recognizer);
                if (batchStream == IntPtr.Zero) return ASRResult.Empty;

                try
                {
                    // Feed in 100ms chunks (closer to realtime path)
                    int offset = 0;
                    while (offset < audioSamples.Length)
                    {
                        int end = Math.Min(offset + BatchStreamChunkSamples, audioSamples.Length);
                        var chunk = new float[end - offset];
                        Array.Copy(audioSamples, offset, chunk, 0, chunk.Length);
                        SherpaOnnxNative.OnlineStreamAcceptWaveform(batchStream, 16000, chunk, chunk.Length);
                        DecodeUntilNotReady(recognizer, batchStream);
                        offset = end;
                    }

                    SherpaOnnxNative.OnlineStreamInputFinished(batchStream);
                    DecodeUntilNotReady(recognizer, batchStream);

                    var text = ReadResultText(recognizer, batchStream);
                    text = NormalizeStreamingText(text);

                    if (string.IsNullOrWhiteSpace(text))
                        return ASRResult.Empty;

                    var segments = new[] { new ASRSegment(text, DetectedLanguage: "en") };
                    return new ASRResult(text, segments, "en");
                }
                finally
                {
                    SherpaOnnxNative.DestroyOnlineStream(batchStream);
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

    // ── Streaming methods ──

    public void FeedAudio(float[] samples)
    {
        if (!IsLoaded) return;

        _decodeQueue.TryAdd(() =>
        {
            var rec = _recognizer;
            var s = _stream;
            if (rec == IntPtr.Zero || s == IntPtr.Zero) return;

            try
            {
                SherpaOnnxNative.OnlineStreamAcceptWaveform(s, 16000, samples, samples.Length);
                DecodeUntilNotReady(rec, s);
                _latestText = NormalizeStreamingText(ReadResultText(rec, s));
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[SherpaOnnxStreaming] FeedAudio error: {ex.Message}");
            }
        });
    }

    public ASRSegment? GetStreamingResult()
    {
        var text = _latestText.Trim();
        if (string.IsNullOrEmpty(text)) return null;
        return new ASRSegment(text, DetectedLanguage: "en");
    }

    public bool IsEndpointDetected()
    {
        var rec = _recognizer;
        var s = _stream;
        if (rec == IntPtr.Zero || s == IntPtr.Zero) return false;

        try
        {
            return SherpaOnnxNative.OnlineStreamIsEndpoint(rec, s) != 0;
        }
        catch
        {
            return false;
        }
    }

    public void ResetStreamingState()
    {
        var rec = _recognizer;
        var s = _stream;
        if (rec == IntPtr.Zero || s == IntPtr.Zero) return;

        try
        {
            SherpaOnnxNative.OnlineStreamReset(rec, s);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[SherpaOnnxStreaming] Reset failed: {ex.Message}");
        }
        _latestText = "";
    }

    public ASRSegment? DrainFinalAudio()
    {
        // Wait for pending decode work to complete
        var done = new ManualResetEventSlim(false);
        try
        {
            _decodeQueue.TryAdd(() => done.Set());
            done.Wait(TimeSpan.FromSeconds(2));
        }
        catch { /* best-effort */ }
        finally
        {
            done.Dispose();
        }

        var rec = _recognizer;
        var s = _stream;
        if (rec == IntPtr.Zero || s == IntPtr.Zero) return null;

        try
        {
            SherpaOnnxNative.OnlineStreamInputFinished(s);
            DecodeUntilNotReady(rec, s);
            var text = NormalizeStreamingText(ReadResultText(rec, s));
            Debug.WriteLine($"[SherpaOnnxStreaming] drainFinalAudio: text='{text}'");

            // Reset stream for potential reuse
            SherpaOnnxNative.OnlineStreamReset(rec, s);
            _latestText = "";

            if (string.IsNullOrWhiteSpace(text)) return null;
            return new ASRSegment(text, DetectedLanguage: "en");
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[SherpaOnnxStreaming] drainFinalAudio failed: {ex.Message}");
            return null;
        }
    }

    public void Release()
    {
        _sem.Wait();
        try { Release_Internal(); }
        finally { _sem.Release(); }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Release();
        _sem.Dispose();
        _decodeQueue.Dispose();
    }

    // ── Internal helpers ──

    private void Release_Internal()
    {
        // Stop decode worker
        _decodeCts?.Cancel();
        _decodeQueue.CompleteAdding();
        try { _decodeWorker?.Wait(TimeSpan.FromSeconds(2)); } catch { /* best-effort */ }
        _decodeCts?.Dispose();
        _decodeCts = null;
        _decodeWorker = null;

        // Recreate queue for potential reuse after reload
        // (BlockingCollection can't be reused after CompleteAdding)
        _decodeQueue.Dispose();
        _decodeQueue = new BlockingCollection<Action>();

        if (_stream != IntPtr.Zero)
        {
            SherpaOnnxNative.DestroyOnlineStream(_stream);
            _stream = IntPtr.Zero;
        }

        if (_recognizer != IntPtr.Zero)
        {
            SherpaOnnxNative.DestroyOnlineRecognizer(_recognizer);
            _recognizer = IntPtr.Zero;
        }

        _stringPool.Clear();
        _latestText = "";
        Debug.WriteLine("[SherpaOnnxStreaming] Released");
    }

    private void DecodeWorkerLoop(CancellationToken ct)
    {
        try
        {
            foreach (var action in _decodeQueue.GetConsumingEnumerable(ct))
            {
                action();
            }
        }
        catch (OperationCanceledException) { /* expected on shutdown */ }
    }

    private static void DecodeUntilNotReady(IntPtr recognizer, IntPtr stream)
    {
        int steps = 0;
        while (SherpaOnnxNative.IsOnlineStreamReady(recognizer, stream) != 0)
        {
            SherpaOnnxNative.DecodeOnlineStream(recognizer, stream);
            steps++;
            if (steps >= MaxDecodeStepsPerPass)
            {
                Debug.WriteLine($"[SherpaOnnxStreaming] Decode loop guard hit (steps={steps})");
                return;
            }
        }
    }

    private static string ReadResultText(IntPtr recognizer, IntPtr stream)
    {
        var jsonPtr = SherpaOnnxNative.GetOnlineStreamResultAsJson(recognizer, stream);
        if (jsonPtr == IntPtr.Zero) return "";

        try
        {
            var json = SherpaOnnxNative.ReadOnlineResultJson(jsonPtr);
            if (string.IsNullOrEmpty(json)) return "";

            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.TryGetProperty("text", out var textElement))
                return textElement.GetString() ?? "";
            return "";
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[SherpaOnnxStreaming] ReadResultText error: {ex.Message}");
            return "";
        }
        finally
        {
            SherpaOnnxNative.DestroyOnlineStreamResultJson(jsonPtr);
        }
    }

    private static string NormalizeStreamingText(string text)
    {
        return Regex.Replace(text, @"\s+", " ").Trim();
    }

    /// <summary>
    /// Find model file: prefer int8 for encoder/joiner (speed), non-int8 for decoder (accuracy).
    /// </summary>
    private static string FindFile(string dir, string baseName)
    {
        var files = Directory.GetFiles(dir, "*.onnx");
        // Prefer int8 for encoder/joiner
        var int8 = files.FirstOrDefault(f => Path.GetFileName(f).Contains(baseName) &&
            Path.GetFileName(f).Contains("int8"));
        if (int8 != null) return int8;

        var regular = files.FirstOrDefault(f => Path.GetFileName(f).Contains(baseName));
        if (regular != null) return regular;

        return Path.Combine(dir, $"{baseName}.onnx");
    }

    /// <summary>
    /// Find decoder file: prefer non-int8 for accuracy.
    /// </summary>
    private static string FindFileDecoder(string dir, string baseName)
    {
        var files = Directory.GetFiles(dir, "*.onnx");
        // Prefer non-int8 for decoder (accuracy)
        var regular = files.FirstOrDefault(f => Path.GetFileName(f).Contains(baseName) &&
            !Path.GetFileName(f).Contains("int8"));
        if (regular != null) return regular;

        var int8 = files.FirstOrDefault(f => Path.GetFileName(f).Contains(baseName));
        if (int8 != null) return int8;

        return Path.Combine(dir, $"{baseName}.onnx");
    }

    private static int ComputeStreamingThreads()
    {
        int cores = Environment.ProcessorCount;
        return cores <= 4 ? 1 : 2;
    }

    private static SherpaOnnxOnlineRecognizerConfig BuildConfig(
        string modelDir,
        string tokensPath,
        string encoderPath,
        string decoderPath,
        string joinerPath,
        int threads,
        string provider,
        Func<string, IntPtr> pin)
    {
        var config = new SherpaOnnxOnlineRecognizerConfig();

        config.FeatConfig = new SherpaOnnxFeatureConfig
        {
            SampleRate = 16000,
            FeatureDim = 80
        };

        var transducer = new SherpaOnnxOnlineTransducerModelConfig
        {
            Encoder = pin(encoderPath),
            Decoder = pin(decoderPath),
            Joiner = pin(joinerPath)
        };

        config.ModelConfig = new SherpaOnnxOnlineModelConfig
        {
            Transducer = transducer,
            Tokens = pin(tokensPath),
            NumThreads = threads,
            Provider = pin(provider),
            Debug = 0
        };

        config.DecodingMethod = pin("modified_beam_search");
        config.MaxActivePaths = 4;

        // Endpoint detection
        config.EnableEndpoint = 1;
        config.Rule1MinTrailingSilence = 1.8f; // Silence threshold (no speech required)
        config.Rule2MinTrailingSilence = 0.8f; // Silence threshold (after speech)
        config.Rule3MinUtteranceLength = 20.0f; // Max utterance length

        return config;
    }

    /// <summary>
    /// Pool for keeping marshaled UTF-8 strings alive.
    /// </summary>
    private sealed class Utf8StringPool : IDisposable
    {
        private readonly List<IntPtr> _ptrs = [];
        private bool _disposed;

        public IntPtr Pin(string value)
        {
            if (_disposed) throw new ObjectDisposedException(nameof(Utf8StringPool));
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
