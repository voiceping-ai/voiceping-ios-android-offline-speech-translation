using System.Text.RegularExpressions;
using OfflineSpeechTranslation.Models;

namespace OfflineSpeechTranslation.Services;

/// <summary>
/// Manages chunk-based windowing for streaming ASR inference.
/// Port of Android StreamingChunkManager.kt.
///
/// Audio is divided into fixed-size chunks (default 15s). Each chunk is
/// transcribed independently; when the buffer crosses a chunk boundary,
/// the current hypothesis is confirmed and accumulated into CompletedChunksText.
/// </summary>
public class StreamingChunkManager
{
    public const float DefaultChunkSeconds = 15.0f;
    public const float DefaultMinNewAudioSeconds = 1.0f;

    private readonly float _chunkSeconds;
    private readonly int _sampleRate;
    private readonly float _minNewAudioSeconds;

    public string CompletedChunksText { get; private set; } = "";
    public List<ASRSegment> ConfirmedSegments { get; private set; } = [];
    public List<ASRSegment> PrevUnconfirmedSegments { get; private set; } = [];
    public long LastConfirmedSegmentEndMs { get; private set; }
    public int ConsecutiveSilentWindows { get; set; }

    /// <summary>Latest confirmed text (completedChunksText + within-chunk confirmed).</summary>
    public string ConfirmedText { get; set; } = "";

    /// <summary>Latest hypothesis text (unconfirmed segments in current chunk).</summary>
    public string HypothesisText { get; private set; } = "";

    public int ChunkSamples => (int)(_sampleRate * _chunkSeconds);

    public StreamingChunkManager(
        float chunkSeconds = DefaultChunkSeconds,
        int sampleRate = 16000,
        float minNewAudioSeconds = DefaultMinNewAudioSeconds)
    {
        _chunkSeconds = chunkSeconds;
        _sampleRate = sampleRate;
        _minNewAudioSeconds = minNewAudioSeconds;
    }

    /// <summary>
    /// Check if the buffer has crossed a chunk boundary. If so,
    /// finalize the current chunk. Returns slice info or null.
    /// </summary>
    public SliceInfo? ComputeSlice(int currentBufferSamples)
    {
        float bufferEndSeconds = (float)currentBufferSamples / _sampleRate;

        // Loop to handle multiple chunk boundaries if the buffer jumped ahead
        while (true)
        {
            float chunkStartSeconds = LastConfirmedSegmentEndMs / 1000f;
            float chunkEndSeconds = chunkStartSeconds + _chunkSeconds;
            if (bufferEndSeconds <= chunkEndSeconds) break;
            FinalizeCurrentChunk();
            LastConfirmedSegmentEndMs = (long)(chunkEndSeconds * 1000);
        }

        int sliceStartSample = (int)(LastConfirmedSegmentEndMs * _sampleRate / 1000);
        float currentChunkEndSeconds = LastConfirmedSegmentEndMs / 1000f + _chunkSeconds;
        int sliceEndSample = Math.Min(
            (int)(currentChunkEndSeconds * _sampleRate),
            currentBufferSamples);

        if (sliceEndSample <= sliceStartSample) return null;

        return new SliceInfo(sliceStartSample, sliceEndSample, LastConfirmedSegmentEndMs);
    }

    /// <summary>
    /// Process transcription result segments from the engine.
    /// </summary>
    public void ProcessTranscriptionResult(IReadOnlyList<ASRSegment> newSegments, long sliceOffsetMs = 0)
    {
        var adjustedSegments = sliceOffsetMs > 0
            ? newSegments.Select(s => s with
            {
                StartMs = s.StartMs + sliceOffsetMs,
                EndMs = s.EndMs + sliceOffsetMs
            }).ToList()
            : newSegments.ToList();

        // SenseVoice returns single segment with 0ms timestamps — treat as immediate confirmed
        bool isSingleNoTimestamp = adjustedSegments.Count == 1
            && adjustedSegments[0].StartMs == sliceOffsetMs
            && adjustedSegments[0].EndMs == sliceOffsetMs;

        if (isSingleNoTimestamp)
        {
            var text = adjustedSegments[0].Text.Trim();
            if (!string.IsNullOrEmpty(text))
            {
                // Engines like sherpa-onnx return a single segment for the whole window.
                // Replace the in-chunk segment instead of appending, otherwise text duplicates
                // as the window grows (0-1s, 0-2s, 0-3s, ...).
                ConfirmedSegments = adjustedSegments.ToList();
                ConfirmedText = BuildConfirmedText();
                HypothesisText = "";
                PrevUnconfirmedSegments = [];
            }
            return;
        }

        // Multi-segment: prefix-match to find confirmed segments
        int confirmedCount = 0;
        for (int i = 0; i < Math.Min(adjustedSegments.Count, PrevUnconfirmedSegments.Count); i++)
        {
            if (NormalizeForComparison(adjustedSegments[i].Text) ==
                NormalizeForComparison(PrevUnconfirmedSegments[i].Text))
                confirmedCount++;
            else
                break;
        }

        if (confirmedCount > 0)
        {
            var newConfirmed = adjustedSegments.Take(confirmedCount).ToList();
            ConfirmedSegments.AddRange(newConfirmed);
        }

        var unconfirmed = adjustedSegments.Skip(confirmedCount).ToList();
        PrevUnconfirmedSegments = unconfirmed;

        ConfirmedText = BuildConfirmedText();
        HypothesisText = string.Join(" ", unconfirmed.Select(s => s.Text.Trim())).Trim();
    }

    /// <summary>Reset all state for a new recording session.</summary>
    public void Reset()
    {
        CompletedChunksText = "";
        ConfirmedSegments = [];
        PrevUnconfirmedSegments = [];
        LastConfirmedSegmentEndMs = 0;
        ConsecutiveSilentWindows = 0;
        ConfirmedText = "";
        HypothesisText = "";
    }

    private void FinalizeCurrentChunk()
    {
        string chunkText = string.Join(" ",
            ConfirmedSegments.Select(s => s.Text.Trim())
                .Concat(PrevUnconfirmedSegments.Select(s => s.Text.Trim())))
            .Trim();

        if (!string.IsNullOrEmpty(chunkText))
        {
            CompletedChunksText = string.IsNullOrEmpty(CompletedChunksText)
                ? chunkText
                : $"{CompletedChunksText} {chunkText}";
        }

        ConfirmedSegments = [];
        PrevUnconfirmedSegments = [];
    }

    private string BuildConfirmedText()
    {
        string segText = string.Join(" ", ConfirmedSegments.Select(s => s.Text.Trim())).Trim();
        return string.IsNullOrEmpty(CompletedChunksText)
            ? segText
            : string.IsNullOrEmpty(segText)
                ? CompletedChunksText
                : $"{CompletedChunksText} {segText}";
    }

    private static string NormalizeForComparison(string text)
        => Regex.Replace(text.Trim().ToLowerInvariant(), @"\s+", " ");
}

/// <summary>
/// Describes the audio slice to transcribe.
/// </summary>
public record SliceInfo(int StartSample, int EndSample, long SliceOffsetMs)
{
    public int SampleCount => EndSample - StartSample;
}
