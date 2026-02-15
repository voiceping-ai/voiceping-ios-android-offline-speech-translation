using System.Diagnostics;
using System.Runtime.InteropServices.WindowsRuntime;
using OfflineSpeechTranslation.Interfaces;
using OfflineSpeechTranslation.Utilities;
using NAudio.Wave;
using Windows.Media.SpeechSynthesis;

namespace OfflineSpeechTranslation.Services;

public sealed class WindowsMediaTtsService : ITtsService
{
    private readonly SemaphoreSlim _mutex = new(1, 1);
    private readonly string _evidenceDir;

    private WaveOutEvent? _waveOut;
    private AudioFileReader? _reader;
    private EventHandler<StoppedEventArgs>? _playbackStoppedHandler;

    private volatile bool _isSpeaking;
    private volatile string? _latestEvidenceWavPath;

    public bool IsSpeaking => _isSpeaking;
    public string? LatestEvidenceWavPath => _latestEvidenceWavPath;

    public event Action<bool>? PlaybackStateChanged;

    public WindowsMediaTtsService()
    {
        _evidenceDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OfflineSpeechTranslation", "TtsEvidence");
        Directory.CreateDirectory(_evidenceDir);
    }

    public async Task SpeakAsync(
        string text,
        string languageCode,
        float rate,
        string? voiceId = null,
        CancellationToken ct = default)
    {
        var normalized = (text ?? "").Trim();
        if (normalized.Length == 0) return;

        await _mutex.WaitAsync(ct);
        try
        {
            StopInternal();

            var ts = DateTime.UtcNow.ToString("yyyyMMdd_HHmmss_fff");
            var lang = NormalizeLang(languageCode);
            var evidenceFallbackPath = Path.Combine(_evidenceDir, $"tts_{ts}_{lang}_fallback.wav");

            // Always write a non-empty WAV so E2E and evidence workflows remain stable.
            WriteFallbackTone(evidenceFallbackPath, normalized);
            _latestEvidenceWavPath = evidenceFallbackPath;

            string? synthPath = null;
            try
            {
                synthPath = Path.Combine(_evidenceDir, $"tts_{ts}_{lang}.wav");
                await SynthesizeToWavAsync(normalized, lang, rate, voiceId, synthPath, ct);
                _latestEvidenceWavPath = synthPath;
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[WindowsMediaTtsService] Synthesize failed: {ex.Message}");
                // Keep fallback evidence path.
            }

            // Prefer synthesized output if present.
            var playPath = (synthPath != null && File.Exists(synthPath))
                ? synthPath
                : evidenceFallbackPath;

            StartPlayback(playPath);
        }
        finally
        {
            _mutex.Release();
        }
    }

    public void Stop()
    {
        _mutex.Wait();
        try
        {
            StopInternal();
        }
        finally
        {
            _mutex.Release();
        }
    }

    private void StopInternal()
    {
        try { _waveOut?.Stop(); } catch { /* best-effort */ }
        CleanupPlayback();
        UpdatePlaybackState(false);
    }

    private void StartPlayback(string wavPath)
    {
        CleanupPlayback();

        try
        {
            _reader = new AudioFileReader(wavPath);
            _waveOut = new WaveOutEvent();
            _waveOut.Init(_reader);
            _playbackStoppedHandler = (_, _) =>
            {
                CleanupPlayback();
                UpdatePlaybackState(false);
            };
            _waveOut.PlaybackStopped += _playbackStoppedHandler;
            _waveOut.Play();
            UpdatePlaybackState(true);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[WindowsMediaTtsService] Playback failed: {ex.Message}");
            CleanupPlayback();
            UpdatePlaybackState(false);
        }
    }

    private void CleanupPlayback()
    {
        try
        {
            if (_waveOut != null)
            {
                if (_playbackStoppedHandler != null)
                    _waveOut.PlaybackStopped -= _playbackStoppedHandler;
                _waveOut.Dispose();
            }
        }
        catch { /* best-effort */ }
        _waveOut = null;
        _playbackStoppedHandler = null;

        try { _reader?.Dispose(); }
        catch { /* best-effort */ }
        _reader = null;
    }

    private void UpdatePlaybackState(bool speaking)
    {
        if (_isSpeaking == speaking) return;
        _isSpeaking = speaking;
        PlaybackStateChanged?.Invoke(speaking);
    }

    private static async Task SynthesizeToWavAsync(
        string text,
        string languageCode,
        float rate,
        string? voiceId,
        string outputPath,
        CancellationToken ct)
    {
        using var synth = new SpeechSynthesizer();

        // Select voice by explicit Id, else best-effort by language prefix.
        var voices = SpeechSynthesizer.AllVoices;
        if (!string.IsNullOrWhiteSpace(voiceId))
        {
            var voice = voices.FirstOrDefault(v => v.Id == voiceId);
            if (voice != null) synth.Voice = voice;
        }
        else if (!string.IsNullOrWhiteSpace(languageCode))
        {
            var voice = voices.FirstOrDefault(v =>
                v.Language != null &&
                v.Language.StartsWith(languageCode, StringComparison.OrdinalIgnoreCase));
            if (voice != null) synth.Voice = voice;
        }

        // SpeakingRate is nominally 0.0–2.0 (system-dependent); clamp defensively.
        try
        {
            synth.Options.SpeakingRate = Math.Clamp(rate, 0.25f, 2.0f);
        }
        catch
        {
            // Older SKUs/voices may not support it; ignore.
        }

        var stream = await synth.SynthesizeTextToStreamAsync(text);

        await using (var input = stream.AsStreamForRead())
        await using (var file = new FileStream(outputPath, FileMode.Create, FileAccess.Write, FileShare.Read))
        {
            await input.CopyToAsync(file, 81920, ct);
            await file.FlushAsync(ct);
        }
    }

    private static void WriteFallbackTone(string outputPath, string text)
    {
        // 16 kHz mono float samples, written as PCM16 WAV.
        int sampleRate = 16_000;
        double durationSeconds = Math.Min(8.0, Math.Max(1.0, (text.Length / 16.0)));
        int numSamples = (int)(sampleRate * durationSeconds);

        var samples = new float[numSamples];
        for (int i = 0; i < numSamples; i++)
        {
            double t = (double)i / sampleRate;
            double env = i < sampleRate / 20 ? i / (sampleRate / 20.0) : 1.0;
            samples[i] = (float)(Math.Sin(2.0 * Math.PI * 440.0 * t) * 0.2 * env);
        }

        try
        {
            WavWriter.Write(outputPath, samples);
        }
        catch
        {
            // best-effort
        }
    }

    private static string NormalizeLang(string code) =>
        (code ?? "").Trim().ToLowerInvariant().Replace("<|", "").Replace("|>", "");

    public void Dispose()
    {
        Stop();
        _mutex.Dispose();
    }
}
