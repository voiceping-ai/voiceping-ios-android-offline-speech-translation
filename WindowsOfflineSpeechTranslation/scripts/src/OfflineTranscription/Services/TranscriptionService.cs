using System.Diagnostics;
using CommunityToolkit.Mvvm.ComponentModel;
using OfflineSpeechTranslation.Data;
using OfflineSpeechTranslation.Engines;
using OfflineSpeechTranslation.Interfaces;
using OfflineSpeechTranslation.Models;
using OfflineSpeechTranslation.Utilities;

namespace OfflineSpeechTranslation.Services;

/// <summary>
/// Orchestrates the full transcription workflow: model lifecycle, recording,
/// real-time transcription loop, VAD, chunk windowing, and metrics.
/// Port of iOS WhisperService.swift + Android WhisperEngine.kt.
/// </summary>
public sealed partial class TranscriptionService : ObservableObject, IDisposable
{
    // ── Dependencies ──
    private readonly AudioRecorder _recorder = new();
    private readonly AppPreferences _prefs;
    private readonly SystemMetrics _metrics = new();

    // ── Engine ──
    private IASREngine? _engine;
    private ModelInfo? _currentModel;
    private StreamingChunkManager _chunkManager = new();

    // ── Observable state ──
    [ObservableProperty] private ASRModelState _modelState = ASRModelState.Unloaded;
    [ObservableProperty] private SessionState _sessionState = SessionState.Idle;
    [ObservableProperty] private double _downloadProgress;
    [ObservableProperty] private string _confirmedText = "";
    [ObservableProperty] private string _hypothesisText = "";
    [ObservableProperty] private string _loadingStatusMessage = "";
    [ObservableProperty] private double _bufferSeconds;
    [ObservableProperty] private double _tokensPerSecond;
    [ObservableProperty] private double _cpuPercent;
    [ObservableProperty] private double _memoryMB;

    // ── Transcription loop ──
    private CancellationTokenSource? _loopCts;
    private Task? _loopTask;
    private int _lastProcessedSample;
    private double _emaInferenceTimeMs;
    private string? _lastDetectedLanguage;
    private const double EmaAlpha = 0.20;
    private const double TargetDutyCycle = 0.24;
    private const double MaxDelayMs = 1600;

    // ── VAD ──
    private const float VadEnergyThreshold = 0.3f; // ~−42 dBFS
    private const int VadPrerollChunks = 3;
    private int _vadSilentCount;

    public AudioRecorder Recorder => _recorder;
    public ModelInfo? CurrentModel => _currentModel;

    public TranscriptionService(AppPreferences prefs)
    {
        _prefs = prefs;
    }

    // ── Model lifecycle ──

    public async Task SelectAndLoadModelAsync(ModelInfo model, CancellationToken ct = default)
    {
        OfflineSpeechTranslation.App.Evidence.LogEvent("model_select", new
        {
            modelId = model.Id,
            displayName = model.DisplayName,
            engineType = model.EngineType.ToString()
        });

        // Unload current (Dispose calls Release internally)
        if (_engine != null)
        {
            _engine.Dispose();
            _engine = null;
        }

        _currentModel = model;
        _lastDetectedLanguage = null;

        try
        {
            // Download if needed
            if (!ModelDownloader.IsModelDownloaded(model))
            {
                OfflineSpeechTranslation.App.Evidence.LogEvent("model_download_start", new { modelId = model.Id });
                ModelState = ASRModelState.Downloading;
                LoadingStatusMessage = $"Downloading {model.DisplayName}...";

                int lastBucket = -1;
                var progress = new Progress<double>(p =>
                {
                    DownloadProgress = p;
                    LoadingStatusMessage = $"Downloading {model.DisplayName}... {p:P0}";

                    // Evidence: log at 10% buckets to avoid huge logs.
                    var bucket = (int)Math.Floor(p * 10);
                    if (bucket != lastBucket && bucket is >= 0 and <= 10)
                    {
                        lastBucket = bucket;
                        OfflineSpeechTranslation.App.Evidence.LogEvent("model_download_progress", new
                        {
                            modelId = model.Id,
                            progress = p
                        });
                    }
                });

                await ModelDownloader.DownloadAsync(model, progress, ct);
                OfflineSpeechTranslation.App.Evidence.LogEvent("model_download_complete", new { modelId = model.Id });
            }

            // Load model
            OfflineSpeechTranslation.App.Evidence.LogEvent("model_load_start", new { modelId = model.Id });
            ModelState = ASRModelState.Loading;
            LoadingStatusMessage = $"Loading {model.DisplayName}...";

            _engine = EngineFactory.Create(model);
            var modelPath = ModelDownloader.GetModelPath(model);

            bool success = await _engine.LoadModelAsync(modelPath, ct);
            if (success)
            {
                ModelState = ASRModelState.Loaded;
                LoadingStatusMessage = "";
                _prefs.SelectedModelId = model.Id;
                Debug.WriteLine($"[TranscriptionService] Model loaded: {model.Id}");

                string provider = _engine switch
                {
                    SherpaOnnxOfflineEngine sherpa => sherpa.Provider,
                    SherpaOnnxStreamingEngine streaming => streaming.Provider,
                    _ => "cpu"
                };
                OfflineSpeechTranslation.App.Evidence.LogEvent("model_load_success", new
                {
                    modelId = model.Id,
                    engineType = model.EngineType.ToString(),
                    provider,
                    modelPath
                });
                OfflineSpeechTranslation.App.Evidence.CaptureModelEvidence(model, provider);

                // Configure chunk manager per model (streaming engines handle their own windowing)
                if (!_engine.IsStreaming)
                {
                    float chunkSec = model.EngineType == EngineType.SherpaOnnxOffline ? 3.5f : 15f;
                    _chunkManager = new StreamingChunkManager(chunkSec);
                }
            }
            else
            {
                ModelState = ASRModelState.Error;
                LoadingStatusMessage = $"Failed to load {model.DisplayName}";
                _engine.Dispose();
                _engine = null;
                OfflineSpeechTranslation.App.Evidence.LogEvent("model_load_failed", new { modelId = model.Id }, level: "error");
            }
        }
        catch (OperationCanceledException)
        {
            ModelState = ASRModelState.Error;
            LoadingStatusMessage = "Cancelled.";
            _engine?.Dispose();
            _engine = null;
            OfflineSpeechTranslation.App.Evidence.LogEvent("model_load_cancelled", new { modelId = model.Id }, level: "error");
            throw;
        }
        catch (Exception ex)
        {
            ModelState = ASRModelState.Error;
            LoadingStatusMessage = $"Error: {ex.Message}";
            _engine?.Dispose();
            _engine = null;
            OfflineSpeechTranslation.App.Evidence.LogEvent("model_load_exception", new { modelId = model.Id, error = ex.ToString() }, level: "error");
            throw;
        }
    }

    // ── Recording ──

    public void StartRecording(CaptureSource source = CaptureSource.Microphone)
    {
        if (SessionState != SessionState.Idle || ModelState != ASRModelState.Loaded)
            return;

        CancelLoop();

        SessionState = SessionState.Starting;

        _chunkManager.Reset();
        _lastProcessedSample = 0;
        _vadSilentCount = 0;
        _emaInferenceTimeMs = 0;
        _lastDetectedLanguage = null;
        ConfirmedText = "";
        HypothesisText = "";

        try
        {
            _recorder.StartRecording(source);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[TranscriptionService] Failed to start recording: {ex.Message}");
            LoadingStatusMessage = $"Recording failed: {ex.Message}";
            SessionState = SessionState.Idle;
            OfflineSpeechTranslation.App.Evidence.LogEvent("record_start_failed", new { source = source.ToString(), error = ex.ToString() }, level: "error");
            return;
        }
        SessionState = SessionState.Recording;
        object startPayload = _recorder.LastCaptureDiagnostics is not null
            ? _recorder.LastCaptureDiagnostics
            : new { source = source.ToString() };
        OfflineSpeechTranslation.App.Evidence.LogEvent("record_started", startPayload);

        // Start transcription loop
        _loopCts = new CancellationTokenSource();
        _loopTask = TranscriptionLoopAsync(_loopCts.Token);
    }

    public void StopRecording()
    {
        if (SessionState != SessionState.Recording) return;

        SessionState = SessionState.Stopping;
        CancelLoop();
        _recorder.StopRecording();

        OfflineSpeechTranslation.App.Evidence.LogEvent("record_stopped", new
        {
            samples = _recorder.SampleCount,
            bufferSeconds = _recorder.BufferSeconds
        });

        // Drain final audio for streaming engines
        if (_engine?.IsStreaming == true)
        {
            var finalSegment = _engine.DrainFinalAudio();
            if (finalSegment != null && !string.IsNullOrWhiteSpace(finalSegment.Text))
            {
                var finalText = string.IsNullOrEmpty(ConfirmedText)
                    ? finalSegment.Text
                    : $"{ConfirmedText} {finalSegment.Text}";
                ConfirmedText = finalText.Trim();
                HypothesisText = "";
            }
            else
            {
                // Promote any remaining hypothesis
                ConfirmedText = $"{ConfirmedText} {HypothesisText}".Trim();
                HypothesisText = "";
            }
        }
        else
        {
            // Set final confirmed text (offline engines)
            _chunkManager.ConfirmedText = $"{ConfirmedText} {HypothesisText}".Trim();
            ConfirmedText = _chunkManager.ConfirmedText;
            HypothesisText = "";
        }

        if (_prefs.EvidenceMode)
        {
            if (_prefs.EvidenceIncludeTranscriptText)
            {
                OfflineSpeechTranslation.App.Evidence.LogEvent("record_final_text", new { text = ConfirmedText });
            }
            else
            {
                OfflineSpeechTranslation.App.Evidence.LogEvent("record_final_text", new { textLength = ConfirmedText.Length });
            }
        }

        // Persist to history (best-effort, off the UI thread)
        var textToSave = ConfirmedText;
        var samplesToSave = _recorder.GetAudioSamples();
        var durationToSave = _recorder.BufferSeconds;
        var modelUsed = _currentModel?.DisplayName ?? "";
        var language = _lastDetectedLanguage;
        SaveToHistoryAsync(textToSave, samplesToSave, durationToSave, modelUsed, language);

        SessionState = SessionState.Idle;
    }

    /// <summary>Whether the service is busy (downloading, loading, or recording).</summary>
    public bool IsBusy => ModelState is ASRModelState.Downloading or ASRModelState.Loading
        || SessionState is not SessionState.Idle;

    // ── File transcription ──

    public async Task<ASRResult> TranscribeFileAsync(float[] audioSamples, CancellationToken ct = default)
    {
        if (_engine == null || !_engine.IsLoaded)
            return ASRResult.Empty;

        int threads = ComputeThreads();
        var result = await _engine.TranscribeAsync(audioSamples, threads, "auto", ct);
        if (!string.IsNullOrWhiteSpace(result.DetectedLanguage))
            _lastDetectedLanguage = result.DetectedLanguage;

        // Set confirmed text for save button visibility
        _chunkManager.ConfirmedText = result.Text;
        ConfirmedText = result.Text;
        HypothesisText = "";

        // Persist file transcriptions too (best-effort)
        if (!string.IsNullOrWhiteSpace(result.Text))
        {
            var duration = audioSamples.Length / 16000.0;
            var modelUsed = _currentModel?.DisplayName ?? "";
            SaveToHistoryAsync(result.Text, audioSamples, duration, modelUsed, result.DetectedLanguage);
        }

        return result;
    }

    // ── Transcription loop ──

    private async Task TranscriptionLoopAsync(CancellationToken ct)
    {
        Debug.WriteLine("[TranscriptionService] Transcription loop started");

        if (_engine?.IsStreaming == true)
        {
            await StreamingLoopAsync(ct);
        }
        else
        {
            await OfflineLoopAsync(ct);
        }

        Debug.WriteLine("[TranscriptionService] Transcription loop ended");
    }

    /// <summary>
    /// Streaming transcription loop: feeds audio incrementally, polls results.
    /// Port of Android streamingLoop().
    /// </summary>
    private async Task StreamingLoopAsync(CancellationToken ct)
    {
        Debug.WriteLine("[TranscriptionService] Streaming loop started");
        string streamingConfirmedText = "";

        while (!ct.IsCancellationRequested)
        {
            try
            {
                var currentSamples = _recorder.SampleCount;
                var bufferSeconds = _recorder.BufferSeconds;
                _metrics.Update();

                PostUI(() =>
                {
                    BufferSeconds = bufferSeconds;
                    CpuPercent = _metrics.CpuPercent;
                    MemoryMB = _metrics.MemoryMB;
                });

                // Feed new audio to the streaming engine
                if (currentSamples > _lastProcessedSample)
                {
                    if (_recorder.TryGetAudioSlice(_lastProcessedSample, currentSamples, out var newSamples))
                    {
                        _engine!.FeedAudio(newSamples);
                        _lastProcessedSample = currentSamples;
                    }
                }

                // Poll for streaming result
                var segment = _engine!.GetStreamingResult();
                var hypothesisText = segment?.Text?.Trim() ?? "";

                // Check for endpoint detection
                if (_engine.IsEndpointDetected() && !string.IsNullOrWhiteSpace(hypothesisText))
                {
                    // Promote hypothesis to confirmed
                    streamingConfirmedText = string.IsNullOrEmpty(streamingConfirmedText)
                        ? hypothesisText
                        : $"{streamingConfirmedText} {hypothesisText}";
                    _engine.ResetStreamingState();
                    hypothesisText = "";

                    if (segment?.DetectedLanguage != null)
                        _lastDetectedLanguage = segment.DetectedLanguage;
                }

                var confirmed = streamingConfirmedText;
                var hypothesis = hypothesisText;
                PostUI(() =>
                {
                    ConfirmedText = confirmed;
                    HypothesisText = hypothesis;
                });

                await Task.Delay(100, ct); // 100ms polling interval
            }
            catch (OperationCanceledException) { break; }
            catch (Exception ex)
            {
                Debug.WriteLine($"[TranscriptionService] Streaming loop error: {ex.Message}");
                try { await Task.Delay(500, ct); } catch (OperationCanceledException) { break; }
            }
        }
    }

    /// <summary>
    /// Offline chunk-based transcription loop (original loop, used for non-streaming engines).
    /// </summary>
    private async Task OfflineLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var currentSamples = _recorder.SampleCount;
                var bufferSeconds = _recorder.BufferSeconds;
                _metrics.Update();
                var cpuPercent = _metrics.CpuPercent;
                var memoryMb = _metrics.MemoryMB;

                PostUI(() =>
                {
                    BufferSeconds = bufferSeconds;
                    CpuPercent = cpuPercent;
                    MemoryMB = memoryMb;
                });

                if (currentSamples <= _lastProcessedSample) goto Sleep;

                // VAD check
                if (_prefs.UseVAD)
                {
                    var energy = _recorder.GetRelativeEnergy();
                    if (energy.Length > 0 && energy[^1] < VadEnergyThreshold)
                    {
                        _vadSilentCount++;
                        if (_vadSilentCount > VadPrerollChunks)
                            goto Sleep;
                    }
                    else
                    {
                        _vadSilentCount = 0;
                    }
                }

                // Compute audio slice
                var slice = _chunkManager.ComputeSlice(currentSamples);
                if (slice == null) goto Sleep;

                // Extract audio for this slice
                if (!_recorder.TryGetAudioSlice(slice.StartSample, slice.EndSample, out var audioSlice))
                    goto Sleep;

                // Transcribe
                int threads = ComputeThreads();
                var sw = Stopwatch.StartNew();
                var result = await _engine!.TranscribeAsync(audioSlice, threads, "auto", ct);
                sw.Stop();

                if (ct.IsCancellationRequested) break;

                double inferenceMs = sw.Elapsed.TotalMilliseconds;
                if (!string.IsNullOrWhiteSpace(result.DetectedLanguage))
                    _lastDetectedLanguage = result.DetectedLanguage;

                // EMA adaptive delay
                _emaInferenceTimeMs = _emaInferenceTimeMs == 0
                    ? inferenceMs
                    : _emaInferenceTimeMs * (1 - EmaAlpha) + inferenceMs * EmaAlpha;

                // Tokens/sec
                int tokenCount = result.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length;
                double tokensPerSecond = inferenceMs > 0
                    ? tokenCount / (inferenceMs / 1000.0)
                    : 0;

                // Process results
                var segments = result.Segments.ToList();
                _chunkManager.ProcessTranscriptionResult(segments, slice.SliceOffsetMs);
                var confirmedText = _chunkManager.ConfirmedText;
                var hypothesisText = _chunkManager.HypothesisText;

                PostUI(() =>
                {
                    TokensPerSecond = tokensPerSecond;
                    ConfirmedText = confirmedText;
                    HypothesisText = hypothesisText;
                });

                _lastProcessedSample = slice.EndSample;

                Sleep:
                // Adaptive delay: target 24% duty cycle
                double delayMs = _emaInferenceTimeMs > 0
                    ? Math.Min(_emaInferenceTimeMs / TargetDutyCycle - _emaInferenceTimeMs, MaxDelayMs)
                    : 200;
                delayMs = Math.Max(delayMs, 100);

                await Task.Delay((int)delayMs, ct);
            }
            catch (OperationCanceledException) { break; }
            catch (Exception ex)
            {
                Debug.WriteLine($"[TranscriptionService] Loop error: {ex.Message}");
                try { await Task.Delay(500, ct); }
                catch (OperationCanceledException) { break; }
            }
        }
    }

    // ── Helpers ──

    public void ClearTranscription()
    {
        if (SessionState != SessionState.Idle) return;

        _chunkManager.Reset();
        ConfirmedText = "";
        HypothesisText = "";
        _recorder.ClearBuffers();
    }

    private static int ComputeThreads()
    {
        int cores = Environment.ProcessorCount;
        return cores switch
        {
            <= 2 => 1,
            <= 4 => 2,
            <= 8 => 4,
            _ => 6
        };
    }

    public void Dispose()
    {
        CancelLoop();
        _recorder.Dispose();
        _engine?.Dispose(); // Dispose calls Release internally
    }

    private static void PostUI(Action action)
    {
        var window = OfflineSpeechTranslation.App.MainWindow;
        if (window == null)
        {
            // No window available — skip to avoid cross-thread UI violations.
            Debug.WriteLine("[TranscriptionService] PostUI skipped: MainWindow is null");
            return;
        }

        if (window.DispatcherQueue.HasThreadAccess)
        {
            action();
        }
        else
        {
            window.DispatcherQueue.TryEnqueue(() => action());
        }
    }

    private void CancelLoop()
    {
        var cts = _loopCts;
        var task = _loopTask;
        _loopCts = null;
        _loopTask = null;

        if (cts == null) return;

        try { cts.Cancel(); }
        catch { /* best-effort */ }

        if (task != null)
        {
            _ = task.ContinueWith(_ => cts.Dispose(), TaskScheduler.Default);
        }
        else
        {
            cts.Dispose();
        }
    }

    private static void SaveToHistoryAsync(
        string text,
        float[] audioSamples,
        double durationSeconds,
        string modelUsed,
        string? language)
    {
        if (string.IsNullOrWhiteSpace(text)) return;

        // Avoid capturing the calling thread's context.
        _ = Task.Run(() =>
        {
            try
            {
                AppDbContext.EnsureCreated();

                var record = new TranscriptionRecord
                {
                    Id = Guid.NewGuid().ToString(),
                    Text = text.Trim(),
                    CreatedAt = DateTime.UtcNow,
                    DurationSeconds = durationSeconds,
                    ModelUsed = modelUsed,
                    Language = string.IsNullOrWhiteSpace(language) ? null : language.Trim()
                };

                try
                {
                    if (audioSamples.Length > 0)
                        record.AudioFileName = SessionFileManager.SaveAudio(record.Id, audioSamples);
                }
                catch (Exception ex)
                {
                    Debug.WriteLine($"[TranscriptionService] Failed to save session audio: {ex.Message}");
                    record.AudioFileName = null;
                }

                using var db = new AppDbContext();
                db.Transcriptions.Add(record);
                db.SaveChanges();
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[TranscriptionService] Failed to save history record: {ex.Message}");
            }
        });
    }
}
