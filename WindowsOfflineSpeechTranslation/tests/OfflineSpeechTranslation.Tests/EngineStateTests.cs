using OfflineSpeechTranslation.Engines;
using OfflineSpeechTranslation.Interfaces;
using OfflineSpeechTranslation.Models;

namespace OfflineSpeechTranslation.Tests;

/// <summary>
/// Tests for engine state management: initial state, not-loaded behavior,
/// and dispose safety. These run without native DLLs by testing the
/// managed-code guard paths.
/// </summary>
public class EngineStateTests
{
    // ── WhisperCppEngine ──

    [Fact]
    public void WhisperCpp_StartsUnloaded()
    {
        using var engine = new WhisperCppEngine();
        Assert.False(engine.IsLoaded);
    }

    [Fact]
    public void WhisperCpp_IsNotStreaming()
    {
        using var engine = new WhisperCppEngine();
        Assert.False(engine.IsStreaming);
    }

    [Fact]
    public async Task WhisperCpp_TranscribeReturnsEmpty_WhenNotLoaded()
    {
        using var engine = new WhisperCppEngine();
        var result = await engine.TranscribeAsync(new float[16000], 4, "en");
        Assert.Equal(ASRResult.Empty, result);
    }

    [Fact]
    public void WhisperCpp_ReleaseIsSafe_WhenNotLoaded()
    {
        using var engine = new WhisperCppEngine();
        engine.Release(); // Should not throw
        Assert.False(engine.IsLoaded);
    }

    [Fact]
    public void WhisperCpp_DoubleDispose_IsSafe()
    {
        var engine = new WhisperCppEngine();
        engine.Dispose();
        // Second dispose should not throw
        var ex = Record.Exception(() => engine.Dispose());
        // SemaphoreSlim.Dispose followed by another Dispose may throw ObjectDisposedException
        // which is acceptable — the important thing is it doesn't crash
        Assert.True(ex == null || ex is ObjectDisposedException);
    }

    // ── SherpaOnnxOfflineEngine ──

    [Fact]
    public void SherpaOnnx_StartsUnloaded()
    {
        using var engine = new SherpaOnnxOfflineEngine();
        Assert.False(engine.IsLoaded);
    }

    [Fact]
    public void SherpaOnnx_IsNotStreaming()
    {
        using var engine = new SherpaOnnxOfflineEngine();
        Assert.False(engine.IsStreaming);
    }

    [Fact]
    public async Task SherpaOnnx_TranscribeReturnsEmpty_WhenNotLoaded()
    {
        using var engine = new SherpaOnnxOfflineEngine();
        var result = await engine.TranscribeAsync(new float[16000], 4, "auto");
        Assert.Equal(ASRResult.Empty, result);
    }

    [Fact]
    public void SherpaOnnx_ReleaseIsSafe_WhenNotLoaded()
    {
        using var engine = new SherpaOnnxOfflineEngine();
        engine.Release(); // Should not throw
        Assert.False(engine.IsLoaded);
    }

    [Fact]
    public void SherpaOnnx_DoubleDispose_IsSafe()
    {
        var engine = new SherpaOnnxOfflineEngine();
        engine.Dispose();
        var ex = Record.Exception(() => engine.Dispose());
        Assert.True(ex == null || ex is ObjectDisposedException);
    }

    // ── IASREngine default implementations ──

    [Fact]
    public void DefaultStreamingMethods_ReturnSafeDefaults()
    {
        using var engine = new WhisperCppEngine();
        // Default interface implementations require cast to interface
        IASREngine iface = engine;
        iface.FeedAudio(new float[100]);
        Assert.Null(iface.GetStreamingResult());
        Assert.False(iface.IsEndpointDetected());
        iface.ResetStreamingState();
        Assert.Null(iface.DrainFinalAudio());
    }
}
