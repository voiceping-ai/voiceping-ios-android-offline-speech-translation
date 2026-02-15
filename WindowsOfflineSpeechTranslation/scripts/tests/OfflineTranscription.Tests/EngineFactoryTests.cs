using OfflineSpeechTranslation.Engines;
using OfflineSpeechTranslation.Models;
using OfflineSpeechTranslation.Services;

namespace OfflineSpeechTranslation.Tests;

/// <summary>
/// Tests for EngineFactory: correct engine instantiation per model type.
/// </summary>
public class EngineFactoryTests
{
    [Fact]
    public void Create_WhisperCpp_ReturnsWhisperCppEngine()
    {
        var model = ModelInfo.AvailableModels.First(m => m.EngineType == EngineType.WhisperCpp);
        using var engine = EngineFactory.Create(model);
        Assert.IsType<WhisperCppEngine>(engine);
    }

    [Fact]
    public void Create_SherpaOnnxOffline_ReturnsSherpaOnnxOfflineEngine()
    {
        var model = ModelInfo.AvailableModels.First(m => m.EngineType == EngineType.SherpaOnnxOffline);
        using var engine = EngineFactory.Create(model);
        Assert.IsType<SherpaOnnxOfflineEngine>(engine);
    }

    [Fact]
    public void Create_SherpaOnnxStreaming_ReturnsSherpaOnnxStreamingEngine()
    {
        var model = ModelInfo.AvailableModels.First(m => m.EngineType == EngineType.SherpaOnnxStreaming);
        using var engine = EngineFactory.Create(model);
        Assert.IsType<SherpaOnnxStreamingEngine>(engine);
        Assert.True(engine.IsStreaming);
    }

    [Fact]
    public void Create_AllModels_ReturnNonNull()
    {
        foreach (var model in ModelInfo.AvailableModels)
        {
            using var engine = EngineFactory.Create(model);
            Assert.NotNull(engine);
        }
    }

    [Fact]
    public void Create_EngineStartsUnloaded()
    {
        foreach (var model in ModelInfo.AvailableModels)
        {
            using var engine = EngineFactory.Create(model);
            Assert.False(engine.IsLoaded);
        }
    }
}
