using OfflineSpeechTranslation.Models;

namespace OfflineSpeechTranslation.Interfaces;

/// <summary>
/// Abstraction over different ASR backends (whisper.cpp, sherpa-onnx offline).
/// Each implementation handles model loading, transcription, and resource cleanup.
/// Port of Android AsrEngine interface + iOS ASREngine protocol.
/// </summary>
public interface IASREngine : IDisposable
{
    /// <summary>Whether a model is currently loaded and ready for transcription.</summary>
    bool IsLoaded { get; }

    /// <summary>Whether this engine supports real-time streaming transcription.</summary>
    bool IsStreaming { get; }

    /// <summary>Load a model from the given directory/file path.</summary>
    Task<bool> LoadModelAsync(string modelPath, CancellationToken ct = default);

    /// <summary>Transcribe audio samples (16kHz mono float [-1,1]).</summary>
    Task<ASRResult> TranscribeAsync(
        float[] audioSamples,
        int numThreads,
        string language,
        CancellationToken ct = default);

    /// <summary>Release all native resources.</summary>
    void Release();

    // ── Streaming support (default no-ops for offline engines) ──

    /// <summary>Feed audio samples to the streaming decoder.</summary>
    void FeedAudio(float[] samples) { }

    /// <summary>Poll the current streaming result.</summary>
    ASRSegment? GetStreamingResult() => null;

    /// <summary>Check if an utterance endpoint (trailing silence) has been detected.</summary>
    bool IsEndpointDetected() => false;

    /// <summary>Reset streaming state for the next utterance.</summary>
    void ResetStreamingState() { }

    /// <summary>Flush remaining buffered audio through the decoder.</summary>
    ASRSegment? DrainFinalAudio() => null;
}
