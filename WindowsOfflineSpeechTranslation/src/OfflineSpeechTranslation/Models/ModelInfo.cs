namespace OfflineSpeechTranslation.Models;

/// <summary>
/// Metadata for an available ASR model. Port of Android ModelInfo.kt.
/// 9 models across 3 engine types matching Android parity.
/// </summary>
public record ModelInfo(
    string Id,
    string DisplayName,
    EngineType EngineType,
    string ParameterCount,
    string SizeOnDisk,
    string Description,
    string Languages,
    IReadOnlyList<ModelFile> Files,
    SherpaModelType? SherpaModelType = null
)
{
    public string InferenceMethod => EngineType switch
    {
        EngineType.WhisperCpp => "whisper.cpp (C++/P-Invoke)",
        EngineType.SherpaOnnxOffline => "sherpa-onnx offline (ONNX Runtime)",
        EngineType.SherpaOnnxStreaming => "sherpa-onnx streaming (ONNX Runtime)",
        _ => "Unknown"
    };

    // ── HuggingFace base URLs (matching Android ModelInfo.kt) ──

    private const string WhisperBaseUrl =
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/";

    private const string MoonshineTinyBaseUrl =
        "https://huggingface.co/csukuangfj/sherpa-onnx-moonshine-tiny-en-int8/resolve/main/";

    private const string MoonshineBaseBaseUrl =
        "https://huggingface.co/csukuangfj/sherpa-onnx-moonshine-base-en-int8/resolve/main/";

    private const string SenseVoiceBaseUrl =
        "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/";

    private const string OmnilingualBaseUrl =
        "https://huggingface.co/csukuangfj2/sherpa-onnx-omnilingual-asr-1600-languages-300M-ctc-int8-2025-11-12/resolve/main/";

    private const string ZipformerEnBaseUrl =
        "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26/resolve/main/";

    private static IReadOnlyList<ModelFile> MoonshineFiles(string baseUrl) =>
    [
        new($"{baseUrl}preprocess.onnx", "preprocess.onnx"),
        new($"{baseUrl}encode.int8.onnx", "encode.int8.onnx"),
        new($"{baseUrl}uncached_decode.int8.onnx", "uncached_decode.int8.onnx"),
        new($"{baseUrl}cached_decode.int8.onnx", "cached_decode.int8.onnx"),
        new($"{baseUrl}tokens.txt", "tokens.txt"),
    ];

    /// <summary>
    /// All available models (9 models across 3 engine types, matching Android parity).
    /// </summary>
    public static IReadOnlyList<ModelInfo> AvailableModels { get; } =
    [
        // ── Whisper (whisper.cpp) ──
        new(
            Id: "whisper-tiny",
            DisplayName: "Whisper Tiny",
            EngineType: EngineType.WhisperCpp,
            ParameterCount: "39M",
            SizeOnDisk: "~80 MB",
            Description: "Fastest Whisper model. Good for quick notes.",
            Languages: "99 languages",
            Files: [new($"{WhisperBaseUrl}ggml-tiny.bin", "ggml-tiny.bin")]
        ),
        new(
            Id: "whisper-base",
            DisplayName: "Whisper Base",
            EngineType: EngineType.WhisperCpp,
            ParameterCount: "74M",
            SizeOnDisk: "~150 MB",
            Description: "Balanced speed and accuracy. Recommended for general use.",
            Languages: "99 languages",
            Files: [new($"{WhisperBaseUrl}ggml-base.bin", "ggml-base.bin")]
        ),
        new(
            Id: "whisper-small",
            DisplayName: "Whisper Small",
            EngineType: EngineType.WhisperCpp,
            ParameterCount: "244M",
            SizeOnDisk: "~500 MB",
            Description: "Higher accuracy, slower. Best for important recordings.",
            Languages: "99 languages",
            Files: [new($"{WhisperBaseUrl}ggml-small.bin", "ggml-small.bin")]
        ),
        new(
            Id: "whisper-large-v3-turbo",
            DisplayName: "Whisper Large V3 Turbo",
            EngineType: EngineType.WhisperCpp,
            ParameterCount: "809M",
            SizeOnDisk: "~834 MB",
            Description: "Near-SOTA accuracy. Best quality, larger download.",
            Languages: "99 languages",
            Files: [new($"{WhisperBaseUrl}ggml-large-v3-turbo-q8_0.bin", "ggml-large-v3-turbo-q8_0.bin")]
        ),

        // ── SenseVoice (sherpa-onnx offline) ──
        new(
            Id: "sensevoice-small",
            DisplayName: "SenseVoice Small",
            EngineType: EngineType.SherpaOnnxOffline,
            ParameterCount: "234M",
            SizeOnDisk: "~240 MB",
            Description: "Multilingual (zh/en/ja/ko/yue). 5x faster than Whisper Small.",
            Languages: "zh/en/ja/ko/yue",
            Files:
            [
                new($"{SenseVoiceBaseUrl}model.int8.onnx", "model.int8.onnx"),
                new($"{SenseVoiceBaseUrl}tokens.txt", "tokens.txt"),
            ],
            SherpaModelType: Models.SherpaModelType.SenseVoice
        ),

        // ── Moonshine (sherpa-onnx offline) ──
        new(
            Id: "moonshine-tiny",
            DisplayName: "Moonshine Tiny",
            EngineType: EngineType.SherpaOnnxOffline,
            ParameterCount: "27M",
            SizeOnDisk: "~125 MB",
            Description: "Ultra-fast, English only. 5x faster than Whisper Tiny.",
            Languages: "English",
            Files: MoonshineFiles(MoonshineTinyBaseUrl),
            SherpaModelType: Models.SherpaModelType.Moonshine
        ),
        new(
            Id: "moonshine-base",
            DisplayName: "Moonshine Base",
            EngineType: EngineType.SherpaOnnxOffline,
            ParameterCount: "61M",
            SizeOnDisk: "~290 MB",
            Description: "Fast English with higher accuracy than Tiny.",
            Languages: "English",
            Files: MoonshineFiles(MoonshineBaseBaseUrl),
            SherpaModelType: Models.SherpaModelType.Moonshine
        ),

        // ── Omnilingual (sherpa-onnx offline, NemoCtc) ──
        new(
            Id: "omnilingual-300m",
            DisplayName: "Omnilingual 300M",
            EngineType: EngineType.SherpaOnnxOffline,
            ParameterCount: "300M",
            SizeOnDisk: "~365 MB",
            Description: "1,600+ languages. Facebook MMS CTC model, int8 quantized.",
            Languages: "1,600+ languages",
            Files:
            [
                new($"{OmnilingualBaseUrl}model.int8.onnx", "model.int8.onnx"),
                new($"{OmnilingualBaseUrl}tokens.txt", "tokens.txt"),
            ],
            SherpaModelType: Models.SherpaModelType.OmnilingualCtc
        ),

        // ── Zipformer Streaming (sherpa-onnx streaming) ──
        new(
            Id: "zipformer-20m",
            DisplayName: "Zipformer Streaming",
            EngineType: EngineType.SherpaOnnxStreaming,
            ParameterCount: "20M",
            SizeOnDisk: "~73 MB",
            Description: "Real-time streaming English. Ultra-low latency.",
            Languages: "English",
            Files:
            [
                new($"{ZipformerEnBaseUrl}encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx",
                    "encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx"),
                new($"{ZipformerEnBaseUrl}decoder-epoch-99-avg-1-chunk-16-left-128.onnx",
                    "decoder-epoch-99-avg-1-chunk-16-left-128.onnx"),
                new($"{ZipformerEnBaseUrl}joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx",
                    "joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx"),
                new($"{ZipformerEnBaseUrl}tokens.txt", "tokens.txt"),
            ],
            SherpaModelType: Models.SherpaModelType.ZipformerTransducer
        ),
    ];

    public static ModelInfo DefaultModel => AvailableModels.First(m => m.Id == "whisper-base");

    /// <summary>
    /// Group models by engine type for UI display (computed once, not per access).
    /// </summary>
    public static IReadOnlyDictionary<EngineType, IReadOnlyList<ModelInfo>> ModelsByEngine { get; } =
        AvailableModels
            .GroupBy(m => m.EngineType)
            .ToDictionary(g => g.Key, g => (IReadOnlyList<ModelInfo>)g.ToList());
}
