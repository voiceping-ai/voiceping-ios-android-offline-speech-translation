using OfflineSpeechTranslation.Engines;
using OfflineSpeechTranslation.Interfaces;
using OfflineSpeechTranslation.Models;

namespace OfflineSpeechTranslation.Services;

/// <summary>
/// Creates the appropriate ASR engine for a model.
/// Port of iOS EngineFactory.swift.
/// </summary>
public static class EngineFactory
{
    public static IASREngine Create(ModelInfo model) => model.EngineType switch
    {
        EngineType.WhisperCpp => new WhisperCppEngine(),
        EngineType.SherpaOnnxOffline => new SherpaOnnxOfflineEngine(model.SherpaModelType),
        EngineType.SherpaOnnxStreaming => new SherpaOnnxStreamingEngine(),
        _ => throw new NotSupportedException($"Unsupported engine type: {model.EngineType}")
    };
}
