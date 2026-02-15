using OfflineSpeechTranslation.Interfaces;
using OfflineSpeechTranslation.Interop;
using OfflineSpeechTranslation.Models;

namespace OfflineSpeechTranslation.Services;

public sealed class CTranslate2TranslationEngine : ITranslationEngine
{
    private readonly SemaphoreSlim _mutex = new(1, 1);

    private NativeTranslation.Translator? _translator;
    private string? _currentModelId;
    private string? _currentSrc;
    private string? _currentTgt;

    public bool ModelReady { get; private set; }
    public double DownloadProgress { get; private set; }
    public string? DownloadStatus { get; private set; }
    public string? Warning { get; private set; }

    public async Task PrepareAsync(string sourceLanguageCode, string targetLanguageCode, CancellationToken ct = default)
    {
        var src = NormalizeLang(sourceLanguageCode);
        var tgt = NormalizeLang(targetLanguageCode);
        if (src.Length == 0 || tgt.Length == 0 || src == tgt)
        {
            await _mutex.WaitAsync(ct);
            try
            {
                Warning = null;
                DownloadStatus = null;
                DownloadProgress = 0;
                ModelReady = true;
            }
            finally
            {
                _mutex.Release();
            }
            return;
        }

        var model = TranslationModelInfo.Find(src, tgt);
        if (model == null)
        {
            await _mutex.WaitAsync(ct);
            try
            {
                Warning = $"No offline translation model available for {src} -> {tgt}.";
                DownloadStatus = null;
                DownloadProgress = 0;
                ModelReady = false;
                DisposeTranslator();
            }
            finally
            {
                _mutex.Release();
            }
            return;
        }

        // Fast path
        await _mutex.WaitAsync(ct);
        try
        {
            if (ModelReady &&
                _translator != null &&
                _currentModelId == model.Id &&
                _currentSrc == src &&
                _currentTgt == tgt)
            {
                return;
            }

            // Reset
            Warning = null;
            DownloadStatus = null;
            DownloadProgress = 0;
            ModelReady = false;
            DisposeTranslator();
        }
        finally
        {
            _mutex.Release();
        }

        // Download/extract outside lock
        if (!TranslationModelDownloader.IsModelDownloaded(model))
        {
            DownloadStatus = $"Downloading translation model ({src} -> {tgt})...";
            var progress = new Progress<double>(p =>
            {
                DownloadProgress = p;
            });
            await TranslationModelDownloader.DownloadAndExtractAsync(model, progress, ct);
            DownloadStatus = null;
            DownloadProgress = 1.0;
        }

        // Load native translator
        var modelDir = TranslationModelDownloader.GetExtractedDir(model);
        var translator = NativeTranslation.Translator.TryCreate(modelDir, out var error);
        if (translator == null)
        {
            Warning = error ?? "Failed to load native translation engine.";
            ModelReady = false;
            return;
        }

        await _mutex.WaitAsync(ct);
        try
        {
            _translator = translator;
            _currentModelId = model.Id;
            _currentSrc = src;
            _currentTgt = tgt;
            Warning = null;
            ModelReady = true;
        }
        finally
        {
            _mutex.Release();
        }
    }

    public async Task<string> TranslateAsync(
        string text,
        string sourceLanguageCode,
        string targetLanguageCode,
        CancellationToken ct = default)
    {
        var normalized = (text ?? "").Trim();
        if (normalized.Length == 0) return "";

        var src = NormalizeLang(sourceLanguageCode);
        var tgt = NormalizeLang(targetLanguageCode);
        if (src == tgt) return normalized;

        await _mutex.WaitAsync(ct);
        try
        {
            if (!ModelReady || _translator == null)
                throw new InvalidOperationException("Translation model not ready.");

            return _translator.Translate(normalized);
        }
        finally
        {
            _mutex.Release();
        }
    }

    public void Dispose()
    {
        DisposeTranslator();
        _mutex.Dispose();
    }

    private void DisposeTranslator()
    {
        try { _translator?.Dispose(); }
        catch { /* best-effort */ }
        _translator = null;
        _currentModelId = null;
        _currentSrc = null;
        _currentTgt = null;
        ModelReady = false;
    }

    private static string NormalizeLang(string code) =>
        (code ?? "").Trim().ToLowerInvariant();
}
