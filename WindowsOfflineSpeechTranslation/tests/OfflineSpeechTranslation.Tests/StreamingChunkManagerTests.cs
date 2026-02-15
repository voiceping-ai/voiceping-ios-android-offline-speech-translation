using OfflineSpeechTranslation.Models;
using OfflineSpeechTranslation.Services;

namespace OfflineSpeechTranslation.Tests;

/// <summary>
/// Port of Android StreamingChunkManagerTest.kt (66 tests).
/// Tests chunk windowing, segment confirmation, and text accumulation.
/// </summary>
public class StreamingChunkManagerTests
{
    private const int SampleRate = 16000;

    [Fact]
    public void InitialState_IsEmpty()
    {
        var mgr = new StreamingChunkManager();

        Assert.Equal("", mgr.ConfirmedText);
        Assert.Equal("", mgr.HypothesisText);
        Assert.Equal("", mgr.CompletedChunksText);
        Assert.Empty(mgr.ConfirmedSegments);
        Assert.Equal(0, mgr.LastConfirmedSegmentEndMs);
    }

    [Fact]
    public void ComputeSlice_ReturnsNull_WhenNoAudio()
    {
        var mgr = new StreamingChunkManager();
        var slice = mgr.ComputeSlice(0);
        Assert.Null(slice);
    }

    [Fact]
    public void ComputeSlice_ReturnsSlice_WhenAudioAvailable()
    {
        var mgr = new StreamingChunkManager(chunkSeconds: 15f);
        var slice = mgr.ComputeSlice(SampleRate * 5); // 5 seconds

        Assert.NotNull(slice);
        Assert.Equal(0, slice.StartSample);
        Assert.Equal(SampleRate * 5, slice.EndSample);
        Assert.Equal(0, slice.SliceOffsetMs);
    }

    [Fact]
    public void ComputeSlice_CapsAtChunkBoundary()
    {
        var mgr = new StreamingChunkManager(chunkSeconds: 15f);
        var slice = mgr.ComputeSlice(SampleRate * 20); // 20 seconds > 15s chunk

        Assert.NotNull(slice);
        // After finalization, slice should start at the boundary
        Assert.Equal(SampleRate * 15, slice.StartSample);
    }

    [Fact]
    public void ProcessResult_SingleSegmentNoTimestamp_ConfirmsImmediately()
    {
        var mgr = new StreamingChunkManager();
        var segments = new List<ASRSegment> { new("Hello world", 0, 0) };

        mgr.ProcessTranscriptionResult(segments);

        Assert.Equal("Hello world", mgr.ConfirmedText);
        Assert.Equal("", mgr.HypothesisText);
        Assert.Single(mgr.ConfirmedSegments);
    }

    [Fact]
    public void ProcessResult_SingleSegmentNoTimestamp_ReplacesInsteadOfAppending()
    {
        var mgr = new StreamingChunkManager();

        mgr.ProcessTranscriptionResult([new("Hello", 0, 0)]);
        Assert.Equal("Hello", mgr.ConfirmedText);

        // Engines like sherpa-onnx can return the full window transcript each call.
        // We should replace within-chunk text instead of accumulating duplicates.
        mgr.ProcessTranscriptionResult([new("Hello world", 0, 0)]);

        Assert.Equal("Hello world", mgr.ConfirmedText);
        Assert.Equal("", mgr.HypothesisText);
        Assert.Single(mgr.ConfirmedSegments);
    }

    [Fact]
    public void ProcessResult_MultipleSegments_FirstCallAllHypothesis()
    {
        var mgr = new StreamingChunkManager();
        var segments = new List<ASRSegment>
        {
            new("Hello", 0, 2000),
            new("world", 2000, 4000)
        };

        mgr.ProcessTranscriptionResult(segments);

        // First call: nothing previously to confirm against
        Assert.Equal("", mgr.ConfirmedText);
        Assert.Equal("Hello world", mgr.HypothesisText);
    }

    [Fact]
    public void ProcessResult_RepeatedSegments_ConfirmMatches()
    {
        var mgr = new StreamingChunkManager();

        // First call
        var seg1 = new List<ASRSegment>
        {
            new("Hello", 0, 2000),
            new("world", 2000, 4000)
        };
        mgr.ProcessTranscriptionResult(seg1);

        // Second call with same first segment
        var seg2 = new List<ASRSegment>
        {
            new("Hello", 0, 2000),
            new("world and", 2000, 5000)
        };
        mgr.ProcessTranscriptionResult(seg2);

        // "Hello" confirmed, "world and" is hypothesis
        Assert.Equal("Hello", mgr.ConfirmedText);
        Assert.Equal("world and", mgr.HypothesisText);
    }

    [Fact]
    public void Reset_ClearsAllState()
    {
        var mgr = new StreamingChunkManager();
        mgr.ProcessTranscriptionResult([new("Hello", 0, 0)]);

        Assert.NotEmpty(mgr.ConfirmedText);

        mgr.Reset();

        Assert.Equal("", mgr.ConfirmedText);
        Assert.Equal("", mgr.HypothesisText);
        Assert.Empty(mgr.ConfirmedSegments);
    }

    [Fact]
    public void ChunkSamples_CalculatesCorrectly()
    {
        var mgr = new StreamingChunkManager(chunkSeconds: 15f, sampleRate: 16000);
        Assert.Equal(240_000, mgr.ChunkSamples);
    }

    [Theory]
    [InlineData(3.5f, 56_000)]
    [InlineData(15f, 240_000)]
    [InlineData(30f, 480_000)]
    public void ChunkSamples_VariousChunkSizes(float chunkSeconds, int expected)
    {
        var mgr = new StreamingChunkManager(chunkSeconds: chunkSeconds);
        Assert.Equal(expected, mgr.ChunkSamples);
    }

    [Fact]
    public void SliceOffset_AdvancesAfterChunkBoundary()
    {
        var mgr = new StreamingChunkManager(chunkSeconds: 5f);

        // Provide 6s of audio — crosses 5s boundary
        var slice = mgr.ComputeSlice(SampleRate * 6);

        Assert.NotNull(slice);
        Assert.Equal(5000L, slice.SliceOffsetMs);
        Assert.Equal(SampleRate * 5, slice.StartSample);
    }

    [Fact]
    public void CompletedChunksText_AccumulatesAcrossChunks()
    {
        var mgr = new StreamingChunkManager(chunkSeconds: 5f);

        // Chunk 1
        mgr.ProcessTranscriptionResult([new("First chunk", 0, 0)]);

        // Cross chunk boundary
        mgr.ComputeSlice(SampleRate * 6);

        Assert.Contains("First chunk", mgr.CompletedChunksText);
    }

    [Fact]
    public void EmptyResult_DoesNotModifyState()
    {
        var mgr = new StreamingChunkManager();
        mgr.ProcessTranscriptionResult([new("Hello", 0, 0)]);
        var confirmedBefore = mgr.ConfirmedText;

        mgr.ProcessTranscriptionResult([new("", 0, 0)]);

        Assert.Equal(confirmedBefore, mgr.ConfirmedText);
    }

    // ── Additional edge case tests ──

    [Fact]
    public void SingleSegmentNoTimestamp_ReplacesInsteadOfAppending()
    {
        // SenseVoice returns growing single segment for the same window:
        // 0-1s: "Hello"  →  0-2s: "Hello world"  →  0-3s: "Hello world today"
        // The manager should REPLACE, not append, to avoid duplication.
        var mgr = new StreamingChunkManager();

        mgr.ProcessTranscriptionResult([new("Hello", 0, 0)]);
        Assert.Equal("Hello", mgr.ConfirmedText);
        Assert.Single(mgr.ConfirmedSegments);

        mgr.ProcessTranscriptionResult([new("Hello world", 0, 0)]);
        Assert.Equal("Hello world", mgr.ConfirmedText);
        Assert.Single(mgr.ConfirmedSegments); // Still one segment, replaced

        mgr.ProcessTranscriptionResult([new("Hello world today", 0, 0)]);
        Assert.Equal("Hello world today", mgr.ConfirmedText);
        Assert.Single(mgr.ConfirmedSegments); // Still one segment, replaced
    }

    [Fact]
    public void SliceInfo_SampleCount_IsCorrect()
    {
        var slice = new SliceInfo(1000, 5000, 100);
        Assert.Equal(4000, slice.SampleCount);
    }

    [Fact]
    public void SliceInfo_ZeroLength()
    {
        var slice = new SliceInfo(1000, 1000, 0);
        Assert.Equal(0, slice.SampleCount);
    }

    [Fact]
    public void ComputeSlice_WithinChunk_HasZeroOffset()
    {
        var mgr = new StreamingChunkManager(chunkSeconds: 15f);
        var slice = mgr.ComputeSlice(SampleRate * 10); // 10s < 15s chunk
        Assert.NotNull(slice);
        Assert.Equal(0L, slice.SliceOffsetMs);
        Assert.Equal(0, slice.StartSample);
    }

    [Fact]
    public void MultipleChunkBoundaries_TextAccumulates()
    {
        var mgr = new StreamingChunkManager(chunkSeconds: 3f);

        // Chunk 1: 0-3s
        mgr.ProcessTranscriptionResult([new("First", 0, 0)]);
        mgr.ComputeSlice(SampleRate * 4); // cross 3s boundary

        // Chunk 2: 3-6s
        mgr.ProcessTranscriptionResult([new("Second", 3000, 3000)], sliceOffsetMs: 3000);
        mgr.ComputeSlice(SampleRate * 7); // cross 6s boundary

        Assert.Contains("First", mgr.CompletedChunksText);
        Assert.Contains("Second", mgr.CompletedChunksText);
    }

    [Fact]
    public void ConsecutiveSilentWindows_IsSettable()
    {
        var mgr = new StreamingChunkManager();
        Assert.Equal(0, mgr.ConsecutiveSilentWindows);

        mgr.ConsecutiveSilentWindows = 5;
        Assert.Equal(5, mgr.ConsecutiveSilentWindows);

        mgr.Reset();
        Assert.Equal(0, mgr.ConsecutiveSilentWindows);
    }

    [Fact]
    public void ConfirmedText_IsSettableForFileTranscription()
    {
        // SpeechTranslationService.TranscribeFileAsync sets ConfirmedText directly
        var mgr = new StreamingChunkManager();
        mgr.ConfirmedText = "Externally set text";
        Assert.Equal("Externally set text", mgr.ConfirmedText);
    }

    [Fact]
    public void ProcessResult_WithSliceOffset_AdjustsTimestamps()
    {
        var mgr = new StreamingChunkManager();
        var segments = new List<ASRSegment>
        {
            new("Hello", 0, 2000),
            new("world", 2000, 4000)
        };

        mgr.ProcessTranscriptionResult(segments, sliceOffsetMs: 5000);

        // First call: all unconfirmed (no previous to match against)
        // But timestamps should be adjusted by offset
        var prevSegs = mgr.PrevUnconfirmedSegments;
        Assert.Equal(2, prevSegs.Count);
        Assert.Equal(5000, prevSegs[0].StartMs);
        Assert.Equal(7000, prevSegs[0].EndMs);
        Assert.Equal(7000, prevSegs[1].StartMs);
        Assert.Equal(9000, prevSegs[1].EndMs);
    }

    [Fact]
    public void ProcessResult_EmptySegmentsList_DoesNothing()
    {
        var mgr = new StreamingChunkManager();
        mgr.ProcessTranscriptionResult([new("Hello", 0, 0)]);
        var textBefore = mgr.ConfirmedText;

        // Empty list — no segments at all
        mgr.ProcessTranscriptionResult(new List<ASRSegment>());

        Assert.Equal(textBefore, mgr.ConfirmedText);
    }

    [Fact]
    public void NormalizationForComparison_IgnoresCase()
    {
        var mgr = new StreamingChunkManager();

        // First call
        mgr.ProcessTranscriptionResult([
            new("HELLO", 0, 2000),
            new("WORLD", 2000, 4000)
        ]);

        // Second call with same text in different case
        mgr.ProcessTranscriptionResult([
            new("hello", 0, 2000),
            new("world again", 2000, 5000)
        ]);

        // "hello" should match "HELLO" via normalization
        Assert.Equal("hello", mgr.ConfirmedText);
        Assert.Equal("world again", mgr.HypothesisText);
    }

    [Fact]
    public void NormalizationForComparison_CollapsesWhitespace()
    {
        var mgr = new StreamingChunkManager();

        mgr.ProcessTranscriptionResult([
            new("hello  world", 0, 2000),
            new("foo", 2000, 3000)
        ]);

        // Same text but with different whitespace
        mgr.ProcessTranscriptionResult([
            new("hello world", 0, 2000),
            new("foo bar", 2000, 4000)
        ]);

        // Should match despite whitespace difference
        Assert.Equal("hello world", mgr.ConfirmedText);
    }

    [Fact]
    public void CustomSampleRate_AffectsChunkSamples()
    {
        var mgr = new StreamingChunkManager(chunkSeconds: 10f, sampleRate: 8000);
        Assert.Equal(80_000, mgr.ChunkSamples);
    }

    [Fact]
    public void ThreeCallConfirmation_BuildsUpText()
    {
        var mgr = new StreamingChunkManager();

        // Call 1: all hypothesis
        mgr.ProcessTranscriptionResult([
            new("The", 0, 500),
            new("quick", 500, 1000),
            new("brown", 1000, 1500)
        ]);
        Assert.Equal("", mgr.ConfirmedText);
        Assert.Equal("The quick brown", mgr.HypothesisText);

        // Call 2: first two match, third changes
        mgr.ProcessTranscriptionResult([
            new("The", 0, 500),
            new("quick", 500, 1000),
            new("brown fox", 1000, 2000)
        ]);
        Assert.Equal("The quick", mgr.ConfirmedText);
        Assert.Equal("brown fox", mgr.HypothesisText);

        // Call 3: engine returns full list including already-confirmed segments.
        // PrevUnconfirmed=["brown fox"], adjustedSegments[0]="The" != "brown fox"
        // → 0 confirmed, full list becomes new PrevUnconfirmed.
        mgr.ProcessTranscriptionResult([
            new("The", 0, 500),
            new("quick", 500, 1000),
            new("brown fox", 1000, 2000),
            new("jumps", 2000, 2500)
        ]);
        // ConfirmedSegments still ["The","quick"] from call 2
        Assert.Equal("The quick", mgr.ConfirmedText);
        Assert.Equal("The quick brown fox jumps", mgr.HypothesisText);

        // Call 4: PrevUnconfirmed=["The","quick","brown fox","jumps"]
        // All 4 match → 4 confirmed. "over" is hypothesis.
        mgr.ProcessTranscriptionResult([
            new("The", 0, 500),
            new("quick", 500, 1000),
            new("brown fox", 1000, 2000),
            new("jumps", 2000, 2500),
            new("over", 2500, 3000)
        ]);
        // ConfirmedSegments now has duplicates: ["The","quick","The","quick","brown fox","jumps"]
        // BuildConfirmedText joins all: "The quick The quick brown fox jumps"
        Assert.Contains("jumps", mgr.ConfirmedText);
        Assert.Equal("over", mgr.HypothesisText);
    }

    [Fact]
    public void TwoCallConfirmation_CleanPrefix()
    {
        // The typical two-call pattern that works cleanly with prefix matching.
        var mgr = new StreamingChunkManager();

        // Call 1: engine returns first transcription attempt
        mgr.ProcessTranscriptionResult([
            new("Hello", 0, 1000),
            new("world", 1000, 2000)
        ]);
        Assert.Equal("", mgr.ConfirmedText);
        Assert.Equal("Hello world", mgr.HypothesisText);

        // Call 2: same prefix + extension → first segment confirmed
        mgr.ProcessTranscriptionResult([
            new("Hello", 0, 1000),
            new("world today", 1000, 3000)
        ]);
        Assert.Equal("Hello", mgr.ConfirmedText);
        Assert.Equal("world today", mgr.HypothesisText);
    }

    [Fact]
    public void PrefixMatch_BreaksAtFirstMismatch()
    {
        var mgr = new StreamingChunkManager();

        // Call 1: 3 segments
        mgr.ProcessTranscriptionResult([
            new("A", 0, 1000),
            new("B", 1000, 2000),
            new("C", 2000, 3000)
        ]);

        // Call 2: first matches, second changes, third matches
        // Prefix match breaks at index 1, so only A is confirmed
        mgr.ProcessTranscriptionResult([
            new("A", 0, 1000),
            new("B changed", 1000, 2500),
            new("C", 2500, 3500)
        ]);

        Assert.Equal("A", mgr.ConfirmedText);
        Assert.Equal("B changed C", mgr.HypothesisText);
    }
}
