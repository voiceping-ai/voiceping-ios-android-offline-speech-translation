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
public sealed partial class SpeechTranslationService : ObservableObject, IDisposable
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

    // ── Translation / TTS state ──
    private readonly ITranslationEngine _translationEngine = new CTranslate2TranslationEngine();
    private readonly ITtsService _ttsService = new WindowsMediaTtsService();

    [ObservableProperty] private bool _translationEnabled;
    [ObservableProperty] private string _translationSourceLanguageCode = "en";
    [ObservableProperty] private string _translationTargetLanguageCode = "ja";
    [ObservableProperty] private bool _translationModelReady;
    [ObservableProperty] private double _translationDownloadProgress;
    [ObservableProperty] private string? _translationDownloadStatus;
    [ObservableProperty] private string _translatedConfirmedText = "";
    [ObservableProperty] private string _translatedHypothesisText = "";
    [ObservableProperty] private string? _translationWarning;

    [ObservableProperty] private bool _speakTranslatedAudio;
    [ObservableProperty] private double _ttsRate = 1.0;
    [ObservableProperty] private string? _ttsVoiceId;
    [ObservableProperty] private bool _isSpeakingTts;
    [ObservableProperty] private int _ttsStartCount;
    [ObservableProperty] private int _ttsMicGuardViolations;
    [ObservableProperty] private bool _micStoppedForTts;
    [ObservableProperty] private string? _detectedLanguage;

    private CancellationTokenSource? _translationCts;
    private CancellationTokenSource? _resumeAfterTtsCts;
    private (string confirmed, string hypothesis, string src, string tgt)? _lastTranslationInput;
    private string _lastSpokenTranslatedConfirmed = "";

    // ── Transcription loop ──
    private CancellationTokenSource? _loopCts;
    private Task? _loopTask;
    private int _lastProcessedSample;
    private double _emaInferenceTimeMs;
    private const double EmaAlpha = 0.20;
    private const double TargetDutyCycle = 0.24;
    private const double MaxDelayMs = 1600;

    // ── VAD ──
    private const float VadEnergyThreshold = 0.3f; // ~−42 dBFS
    private const int VadPrerollChunks = 3;
    private int _vadSilentCount;

    public AudioRecorder Recorder => _recorder;
    public ModelInfo? CurrentModel => _currentModel;

    public SpeechTranslationService(AppPreferences prefs)
    {
        _prefs = prefs;

        // Load persisted translation/TTS preferences.
        TranslationEnabled = _prefs.TranslationEnabled;
        TranslationSourceLanguageCode = _prefs.TranslationSourceLanguageCode;
        TranslationTargetLanguageCode = _prefs.TranslationTargetLanguageCode;
        SpeakTranslatedAudio = _prefs.SpeakTranslatedAudio;
        TtsRate = _prefs.TtsRate;
        TtsVoiceId = _prefs.TtsVoiceId;

        _ttsService.PlaybackStateChanged += speaking =>
        {
            PostUI(() =>
            {
                IsSpeakingTts = speaking;
                if (!speaking)
                {
                    ScheduleResumeAfterTts();
                }
            });
        };

        // Best-effort warmup so the first translation doesn't stall on model download.
        if (TranslationEnabled)
        {
            _ = Task.Run(async () =>
            {
                try
                {
                    await PrepareTranslationModelAsync(
                        TranslationSourceLanguageCode,
                        TranslationTargetLanguageCode,
                        CancellationToken.None);
                }
                catch { /* best-effort */ }
            });
        }
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
        DetectedLanguage = null;

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
                Debug.WriteLine($"[SpeechTranslationService] Model loaded: {model.Id}");

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
        DetectedLanguage = null;
        ConfirmedText = "";
        HypothesisText = "";
        ResetTranslationState(stopTts: true);

        try
        {
            _recorder.StartRecording(source);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[SpeechTranslationService] Failed to start recording: {ex.Message}");
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
        ScheduleTranslationUpdate();

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

        // Persist to history (best-effort, off the UI thread).
        // If translation is enabled and the translated snapshot is still empty, compute once before saving.
        var textToSave = ConfirmedText;
        var translatedTextSnapshot = TranslatedConfirmedText;
        var translationSrcToSave = (TranslationSourceLanguageCode ?? "").Trim().ToLowerInvariant();
        var translationTgtToSave = (TranslationTargetLanguageCode ?? "").Trim().ToLowerInvariant();
        var ttsEvidencePathSnapshot = _ttsService.LatestEvidenceWavPath;
        var samplesToSave = _recorder.GetAudioSamples();
        var durationToSave = _recorder.BufferSeconds;
        var modelUsed = _currentModel?.DisplayName ?? "";
        var language = DetectedLanguage;

        _ = Task.Run(async () =>
        {
            string? translatedToSave = translatedTextSnapshot;

            if (TranslationEnabled &&
                translationSrcToSave.Length > 0 &&
                translationTgtToSave.Length > 0 &&
                translationSrcToSave != translationTgtToSave &&
                !string.IsNullOrWhiteSpace(textToSave) &&
                string.IsNullOrWhiteSpace(translatedToSave))
            {
                try
                {
                    await _translationEngine.PrepareAsync(translationSrcToSave, translationTgtToSave, CancellationToken.None);
                    translatedToSave = await _translationEngine.TranslateAsync(
                        textToSave,
                        translationSrcToSave,
                        translationTgtToSave,
                        CancellationToken.None);
                }
                catch
                {
                    translatedToSave = null;
                }
            }

            SaveToHistoryAsync(
                text: textToSave,
                translatedText: translatedToSave,
                translationSourceLanguage: translationSrcToSave,
                translationTargetLanguage: translationTgtToSave,
                ttsEvidenceWavPath: ttsEvidencePathSnapshot,
                audioSamples: samplesToSave,
                durationSeconds: durationToSave,
                modelUsed: modelUsed,
                language: language);
        });

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
        {
            var detected = result.DetectedLanguage.Trim();
            PostUI(() =>
            {
                DetectedLanguage = detected;
                ApplyDetectedLanguageToTranslation(DetectedLanguage);
            });
        }

        // Set confirmed text for save button visibility
        _chunkManager.ConfirmedText = result.Text;
        ConfirmedText = result.Text;
        HypothesisText = "";
        ScheduleTranslationUpdate();

        // Persist file transcriptions too (best-effort)
        if (!string.IsNullOrWhiteSpace(result.Text))
        {
            var duration = audioSamples.Length / 16000.0;
            var modelUsed = _currentModel?.DisplayName ?? "";

            // Best-effort: run translation once for file transcription so history includes it.
            var src = (TranslationSourceLanguageCode ?? "").Trim().ToLowerInvariant();
            var tgt = (TranslationTargetLanguageCode ?? "").Trim().ToLowerInvariant();
            string? translated = null;
            if (TranslationEnabled && src.Length > 0 && tgt.Length > 0 && src != tgt)
            {
                try
                {
                    await PrepareTranslationModelAsync(src, tgt, ct);
                    translated = await _translationEngine.TranslateAsync(result.Text, src, tgt, ct);
                }
                catch
                {
                    translated = null;
                }
            }

            SaveToHistoryAsync(
                text: result.Text,
                translatedText: translated,
                translationSourceLanguage: src,
                translationTargetLanguage: tgt,
                ttsEvidenceWavPath: null,
                audioSamples: audioSamples,
                durationSeconds: duration,
                modelUsed: modelUsed,
                language: result.DetectedLanguage);
        }

        return result;
    }

    // ── Transcription loop ──

    private async Task TranscriptionLoopAsync(CancellationToken ct)
    {
        Debug.WriteLine("[SpeechTranslationService] Transcription loop started");

        if (_engine?.IsStreaming == true)
        {
            await StreamingLoopAsync(ct);
        }
        else
        {
            await OfflineLoopAsync(ct);
        }

        Debug.WriteLine("[SpeechTranslationService] Transcription loop ended");
    }

    /// <summary>
    /// Streaming transcription loop: feeds audio incrementally, polls results.
    /// Port of Android streamingLoop().
    /// </summary>
    private async Task StreamingLoopAsync(CancellationToken ct)
    {
        Debug.WriteLine("[SpeechTranslationService] Streaming loop started");
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

                    if (!string.IsNullOrWhiteSpace(segment?.DetectedLanguage))
                    {
                        var detected = segment.DetectedLanguage.Trim();
                        PostUI(() =>
                        {
                            DetectedLanguage = detected;
                            ApplyDetectedLanguageToTranslation(DetectedLanguage);
                        });
                    }
                }

                var confirmed = streamingConfirmedText;
                var hypothesis = hypothesisText;
                PostUI(() =>
                {
                    ConfirmedText = confirmed;
                    HypothesisText = hypothesis;
                    ScheduleTranslationUpdate();
                });

                await Task.Delay(100, ct); // 100ms polling interval
            }
            catch (OperationCanceledException) { break; }
            catch (Exception ex)
            {
                Debug.WriteLine($"[SpeechTranslationService] Streaming loop error: {ex.Message}");
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
                {
                    var detected = result.DetectedLanguage.Trim();
                    PostUI(() =>
                    {
                        DetectedLanguage = detected;
                        ApplyDetectedLanguageToTranslation(DetectedLanguage);
                    });
                }

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
                    ScheduleTranslationUpdate();
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
                Debug.WriteLine($"[SpeechTranslationService] Loop error: {ex.Message}");
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
        ResetTranslationState(stopTts: true);
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

    // ── Translation / TTS orchestration ──

    partial void OnTranslationEnabledChanged(bool value)
    {
        _prefs.TranslationEnabled = value;
        ResetTranslationState(stopTts: !value);
        if (value)
        {
            var src = TranslationSourceLanguageCode;
            var tgt = TranslationTargetLanguageCode;
            _ = Task.Run(() => PrepareTranslationModelAsync(src, tgt, CancellationToken.None));
        }
        ScheduleTranslationUpdate();
    }

    partial void OnTranslationSourceLanguageCodeChanged(string value)
    {
        _prefs.TranslationSourceLanguageCode = value;
        ResetTranslationState(stopTts: false);
        if (TranslationEnabled)
        {
            var src = TranslationSourceLanguageCode;
            var tgt = TranslationTargetLanguageCode;
            _ = Task.Run(() => PrepareTranslationModelAsync(src, tgt, CancellationToken.None));
        }
        ScheduleTranslationUpdate();
    }

    partial void OnTranslationTargetLanguageCodeChanged(string value)
    {
        _prefs.TranslationTargetLanguageCode = value;
        ResetTranslationState(stopTts: true);
        if (TranslationEnabled)
        {
            var src = TranslationSourceLanguageCode;
            var tgt = TranslationTargetLanguageCode;
            _ = Task.Run(() => PrepareTranslationModelAsync(src, tgt, CancellationToken.None));
        }
        ScheduleTranslationUpdate();
    }

    partial void OnSpeakTranslatedAudioChanged(bool value)
    {
        _prefs.SpeakTranslatedAudio = value;
        if (!value)
            _ttsService.Stop();
    }

    partial void OnTtsRateChanged(double value)
    {
        _prefs.TtsRate = (float)value;
    }

    partial void OnTtsVoiceIdChanged(string? value)
    {
        _prefs.TtsVoiceId = value;
    }

    private void ResetTranslationState(bool stopTts)
    {
        try
        {
            _translationCts?.Cancel();
        }
        catch { /* best-effort */ }
        _translationCts = null;

        TranslatedConfirmedText = "";
        TranslatedHypothesisText = "";
        TranslationWarning = null;
        _lastTranslationInput = null;
        _lastSpokenTranslatedConfirmed = "";

        if (stopTts)
        {
            try { _ttsService.Stop(); }
            catch { /* best-effort */ }
        }
    }

    public void ScheduleTranslationUpdate()
    {
        // Always called on UI thread (from PostUI or user actions).
        try { _translationCts?.Cancel(); } catch { /* best-effort */ }

        if (!TranslationEnabled)
        {
            ResetTranslationState(stopTts: false);
            TranslationModelReady = false;
            TranslationDownloadProgress = 0;
            TranslationDownloadStatus = null;
            return;
        }

        var src = (TranslationSourceLanguageCode ?? "").Trim().ToLowerInvariant();
        var tgt = (TranslationTargetLanguageCode ?? "").Trim().ToLowerInvariant();
        if (src.Length == 0 || tgt.Length == 0) return;

        var confirmedSnapshot = ConfirmedText ?? "";
        var hypothesisSnapshot = HypothesisText ?? "";

        var key = (confirmed: confirmedSnapshot, hypothesis: hypothesisSnapshot, src, tgt);
        if (_lastTranslationInput.HasValue && _lastTranslationInput.Value.Equals(key))
            return;

        var cts = new CancellationTokenSource();
        _translationCts = cts;

        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(180, cts.Token); // debounce
                await RunTranslationAsync(
                    confirmedSnapshot,
                    hypothesisSnapshot,
                    src,
                    tgt,
                    cts.Token);
            }
            catch (OperationCanceledException)
            {
                // ignored
            }
            catch (Exception ex)
            {
                PostUI(() => TranslationWarning = $"Translation failed: {ex.Message}");
            }
        }, cts.Token);
    }

    private async Task RunTranslationAsync(
        string confirmedSnapshot,
        string hypothesisSnapshot,
        string sourceLanguageCode,
        string targetLanguageCode,
        CancellationToken ct)
    {
        string translatedConfirmed = "";
        string translatedHypothesis = "";
        string? warning = null;

        if (sourceLanguageCode == targetLanguageCode)
        {
            translatedConfirmed = confirmedSnapshot.Trim();
            translatedHypothesis = hypothesisSnapshot.Trim();
        }
        else
        {
                try
                {
                    await PrepareTranslationModelAsync(sourceLanguageCode, targetLanguageCode, ct);

                    translatedConfirmed = confirmedSnapshot.Trim().Length == 0
                        ? ""
                        : await _translationEngine.TranslateAsync(
                        confirmedSnapshot,
                        sourceLanguageCode,
                        targetLanguageCode,
                        ct);

                translatedHypothesis = hypothesisSnapshot.Trim().Length == 0
                    ? ""
                    : await _translationEngine.TranslateAsync(
                        hypothesisSnapshot,
                        sourceLanguageCode,
                        targetLanguageCode,
                        ct);
            }
            catch (Exception ex)
            {
                warning = ex.Message;
                translatedConfirmed = confirmedSnapshot.Trim();
                translatedHypothesis = hypothesisSnapshot.Trim();
            }
        }

        ct.ThrowIfCancellationRequested();

        PostUI(() =>
        {
            TranslatedConfirmedText = NormalizeDisplayText(translatedConfirmed);
            TranslatedHypothesisText = NormalizeDisplayText(translatedHypothesis);
            TranslationWarning = warning ?? _translationEngine.Warning;
            TranslationModelReady = _translationEngine.ModelReady;
            TranslationDownloadProgress = _translationEngine.DownloadProgress;
            TranslationDownloadStatus = _translationEngine.DownloadStatus;
            _lastTranslationInput = (confirmedSnapshot, hypothesisSnapshot, sourceLanguageCode, targetLanguageCode);
        });

        if (SpeakTranslatedAudio)
        {
            await SpeakTranslatedDeltaIfNeededAsync(translatedConfirmed, targetLanguageCode);
        }
    }

    private async Task PrepareTranslationModelAsync(string sourceLanguageCode, string targetLanguageCode, CancellationToken ct)
    {
        var src = (sourceLanguageCode ?? "").Trim().ToLowerInvariant();
        var tgt = (targetLanguageCode ?? "").Trim().ToLowerInvariant();
        if (!TranslationEnabled || src.Length == 0 || tgt.Length == 0 || src == tgt)
        {
            PostUI(() =>
            {
                TranslationModelReady = true;
                TranslationDownloadProgress = 0;
                TranslationDownloadStatus = null;
            });
            return;
        }

        // Poll the translation engine state while PrepareAsync runs so the UI can show progress.
        using var pollCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var pollTask = Task.Run(async () =>
        {
            try
            {
                using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(120));
                while (await timer.WaitForNextTickAsync(pollCts.Token))
                {
                    PostUI(() =>
                    {
                        TranslationModelReady = _translationEngine.ModelReady;
                        TranslationDownloadProgress = _translationEngine.DownloadProgress;
                        TranslationDownloadStatus = _translationEngine.DownloadStatus;
                        if (!string.IsNullOrWhiteSpace(_translationEngine.Warning))
                            TranslationWarning = _translationEngine.Warning;
                    });
                }
            }
            catch (OperationCanceledException)
            {
                // ignored
            }
        }, pollCts.Token);

        try
        {
            await _translationEngine.PrepareAsync(src, tgt, ct);
        }
        finally
        {
            try { pollCts.Cancel(); } catch { /* best-effort */ }
            try { await pollTask; } catch { /* best-effort */ }
        }

        PostUI(() =>
        {
            TranslationModelReady = _translationEngine.ModelReady;
            TranslationDownloadProgress = _translationEngine.DownloadProgress;
            TranslationDownloadStatus = _translationEngine.DownloadStatus;
            if (!string.IsNullOrWhiteSpace(_translationEngine.Warning))
                TranslationWarning = _translationEngine.Warning;
        });
    }

    private async Task SpeakTranslatedDeltaIfNeededAsync(string translatedConfirmed, string languageCode)
    {
        if (!SpeakTranslatedAudio) return;

        var normalized = NormalizeDisplayText(translatedConfirmed);
        if (string.IsNullOrWhiteSpace(normalized)) return;

        var delta = normalized;
        if (_lastSpokenTranslatedConfirmed.Length > 0 &&
            normalized.StartsWith(_lastSpokenTranslatedConfirmed, StringComparison.Ordinal))
        {
            delta = NormalizeDisplayText(normalized[_lastSpokenTranslatedConfirmed.Length..]);
        }

        if (string.IsNullOrWhiteSpace(delta)) return;

        var meaningfulChars = delta.Count(char.IsLetterOrDigit);
        if (meaningfulChars < 2) return;

        var micStoppedOk = false;
        try
        {
            micStoppedOk = await PostUIAsync(EnforceMicStoppedForTtsOnUIThread);
        }
        catch
        {
            micStoppedOk = false;
        }

        if (!micStoppedOk)
        {
            await PostUIAsync(() =>
            {
                TranslationWarning = "Microphone is still active; skipped TTS playback to avoid feedback loop.";
            });
            return;
        }

        try
        {
            PostUI(() =>
            {
                TtsStartCount++;
            });

            await _ttsService.SpeakAsync(
                delta,
                languageCode,
                (float)TtsRate,
                voiceId: TtsVoiceId,
                ct: CancellationToken.None);

            _lastSpokenTranslatedConfirmed = normalized;
        }
        catch (Exception ex)
        {
            PostUI(() =>
            {
                MicStoppedForTts = false;
                TranslationWarning = $"TTS failed: {ex.Message}";
            });
        }
    }

    private bool EnforceMicStoppedForTtsOnUIThread()
    {
        // Must run on UI thread: updates observable state + stops capture loop.
        StopRecordingForTtsIfNeededOnUIThread();

        if (SessionState == SessionState.Recording || Recorder.IsRecording)
        {
            TtsMicGuardViolations++;
            try
            {
                CancelLoop();
                Recorder.StopRecording();
            }
            catch { /* best-effort */ }
            SessionState = SessionState.Idle;
            MicStoppedForTts = true;
        }

        return SessionState == SessionState.Idle && !Recorder.IsRecording;
    }

    private void StopRecordingForTtsIfNeededOnUIThread()
    {
        if (SessionState is not (SessionState.Recording or SessionState.Starting))
            return;

        // Stop capture/inference without persisting history (TTS feedback guard).
        SessionState = SessionState.Stopping;
        CancelLoop();
        Recorder.StopRecording();
        SessionState = SessionState.Idle;
        MicStoppedForTts = true;
    }

    private void ScheduleResumeAfterTts()
    {
        if (!MicStoppedForTts) return;

        try { _resumeAfterTtsCts?.Cancel(); } catch { /* best-effort */ }
        var cts = new CancellationTokenSource();
        _resumeAfterTtsCts = cts;

        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(220, cts.Token);
            }
            catch (OperationCanceledException)
            {
                return;
            }

            PostUI(() =>
            {
                if (!MicStoppedForTts) return;
                if (IsSpeakingTts) return;
                _ = ResumeRecordingAfterTtsAsync();
            });
        }, cts.Token);
    }

    private async Task ResumeRecordingAfterTtsAsync()
    {
        if (!MicStoppedForTts) return;
        if (SessionState != SessionState.Idle) return;
        if (ModelState != ASRModelState.Loaded) return;

        // Clear state for a fresh interpretation segment.
        _chunkManager.Reset();
        ConfirmedText = "";
        HypothesisText = "";
        TranslatedConfirmedText = "";
        TranslatedHypothesisText = "";
        TranslationWarning = null;
        _lastTranslationInput = null;
        _lastSpokenTranslatedConfirmed = "";
        DetectedLanguage = null;

        Recorder.ClearBuffers();

        MicStoppedForTts = false;

        await Task.Yield();

        // Resume with the current capture source preference.
        StartRecording(_prefs.CaptureSource);
    }

    private void ApplyDetectedLanguageToTranslation(string? lang)
    {
        if (!TranslationEnabled) return;
        if (string.IsNullOrWhiteSpace(lang)) return;

        var detected = lang.Trim().ToLowerInvariant();
        var currentSource = (TranslationSourceLanguageCode ?? "").Trim().ToLowerInvariant();
        var currentTarget = (TranslationTargetLanguageCode ?? "").Trim().ToLowerInvariant();

        if (detected == currentTarget && detected != currentSource)
        {
            TranslationSourceLanguageCode = currentTarget;
            TranslationTargetLanguageCode = currentSource;
            ResetTranslationState(stopTts: true);
            ScheduleTranslationUpdate();
        }
    }

    private static string NormalizeDisplayText(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return "";
        // Collapse whitespace but preserve newlines.
        var lines = text.Replace("\r\n", "\n").Split('\n');
        for (int i = 0; i < lines.Length; i++)
            lines[i] = string.Join(' ', lines[i].Split(' ', StringSplitOptions.RemoveEmptyEntries)).Trim();
        return string.Join('\n', lines).Trim();
    }

    public void Dispose()
    {
        CancelLoop();
        _recorder.Dispose();
        _engine?.Dispose(); // Dispose calls Release internally
        try { _translationEngine.Dispose(); } catch { /* best-effort */ }
        try { _ttsService.Dispose(); } catch { /* best-effort */ }
    }

    private static void PostUI(Action action)
    {
        var window = OfflineSpeechTranslation.App.MainWindow;
        if (window == null)
        {
            // No window available — skip to avoid cross-thread UI violations.
            Debug.WriteLine("[SpeechTranslationService] PostUI skipped: MainWindow is null");
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

    private static Task PostUIAsync(Action action)
    {
        var window = OfflineSpeechTranslation.App.MainWindow;
        if (window == null)
            return Task.CompletedTask;

        if (window.DispatcherQueue.HasThreadAccess)
        {
            action();
            return Task.CompletedTask;
        }

        var tcs = new TaskCompletionSource<object?>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!window.DispatcherQueue.TryEnqueue(() =>
        {
            try
            {
                action();
                tcs.TrySetResult(null);
            }
            catch (Exception ex)
            {
                tcs.TrySetException(ex);
            }
        }))
        {
            tcs.TrySetResult(null);
        }
        return tcs.Task;
    }

    private static Task<T> PostUIAsync<T>(Func<T> func)
    {
        var window = OfflineSpeechTranslation.App.MainWindow;
        if (window == null)
            return Task.FromResult(default(T)!);

        if (window.DispatcherQueue.HasThreadAccess)
            return Task.FromResult(func());

        var tcs = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!window.DispatcherQueue.TryEnqueue(() =>
        {
            try
            {
                tcs.TrySetResult(func());
            }
            catch (Exception ex)
            {
                tcs.TrySetException(ex);
            }
        }))
        {
            tcs.TrySetResult(default!);
        }
        return tcs.Task;
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
        string? translatedText,
        string? translationSourceLanguage,
        string? translationTargetLanguage,
        string? ttsEvidenceWavPath,
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
                    TranslatedText = string.IsNullOrWhiteSpace(translatedText) ? null : translatedText.Trim(),
                    CreatedAt = DateTime.UtcNow,
                    DurationSeconds = durationSeconds,
                    ModelUsed = modelUsed,
                    Language = string.IsNullOrWhiteSpace(language) ? null : language.Trim(),
                    TranslationSourceLanguage = string.IsNullOrWhiteSpace(translationSourceLanguage) ? null : translationSourceLanguage.Trim(),
                    TranslationTargetLanguage = string.IsNullOrWhiteSpace(translationTargetLanguage) ? null : translationTargetLanguage.Trim(),
                    TranslationModelId = TranslationModelInfo.Find(
                        translationSourceLanguage ?? "",
                        translationTargetLanguage ?? "")?.Id
                };

                try
                {
                    if (audioSamples.Length > 0)
                        record.AudioFileName = SessionFileManager.SaveAudio(record.Id, audioSamples);
                }
                catch (Exception ex)
                {
                    Debug.WriteLine($"[SpeechTranslationService] Failed to save session audio: {ex.Message}");
                    record.AudioFileName = null;
                }

                try
                {
                    if (!string.IsNullOrWhiteSpace(ttsEvidenceWavPath) && File.Exists(ttsEvidenceWavPath))
                        record.TtsEvidenceFileName = SessionFileManager.SaveTtsEvidence(record.Id, ttsEvidenceWavPath);
                }
                catch (Exception ex)
                {
                    Debug.WriteLine($"[SpeechTranslationService] Failed to save TTS evidence: {ex.Message}");
                    record.TtsEvidenceFileName = null;
                }

                using var db = new AppDbContext();
                db.Transcriptions.Add(record);
                db.SaveChanges();
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[SpeechTranslationService] Failed to save history record: {ex.Message}");
            }
        });
    }
}
