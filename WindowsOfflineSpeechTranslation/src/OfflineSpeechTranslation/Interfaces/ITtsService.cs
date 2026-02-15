using System;
using System.Threading;
using System.Threading.Tasks;

namespace OfflineSpeechTranslation.Interfaces;

public interface ITtsService : IDisposable
{
    bool IsSpeaking { get; }
    string? LatestEvidenceWavPath { get; }

    event Action<bool>? PlaybackStateChanged;

    Task SpeakAsync(string text, string languageCode, float rate, string? voiceId = null, CancellationToken ct = default);
    void Stop();
}

