namespace OfflineSpeechTranslation.Models;

/// <summary>
/// Metadata for an available offline translation model (CTranslate2).
/// Models are downloaded as a single .zip and extracted under LocalAppData.
/// </summary>
public sealed record TranslationModelInfo(
    string Id,
    string DisplayName,
    string SourceLanguageCode,
    string TargetLanguageCode,
    string ZipUrl,
    string SizeOnDisk
)
{
    private const string PlaceholderBaseUrl =
        "https://huggingface.co/voiceping-ai/windows-offline-speech-translation-models/resolve/main/";

    public static IReadOnlyList<TranslationModelInfo> AvailableModels { get; } =
    [
        new(
            Id: "ct2-opus-mt-en-ja-int8",
            DisplayName: "EN → JA (OPUS-MT, INT8)",
            SourceLanguageCode: "en",
            TargetLanguageCode: "ja",
            ZipUrl: $"{PlaceholderBaseUrl}ct2-opus-mt-en-ja-int8.zip",
            SizeOnDisk: "~120 MB"
        ),
        new(
            Id: "ct2-opus-mt-ja-en-int8",
            DisplayName: "JA → EN (OPUS-MT, INT8)",
            SourceLanguageCode: "ja",
            TargetLanguageCode: "en",
            ZipUrl: $"{PlaceholderBaseUrl}ct2-opus-mt-ja-en-int8.zip",
            SizeOnDisk: "~120 MB"
        ),
    ];

    public static TranslationModelInfo? Find(string sourceLanguageCode, string targetLanguageCode)
    {
        var src = NormalizeLang(sourceLanguageCode);
        var tgt = NormalizeLang(targetLanguageCode);
        return AvailableModels.FirstOrDefault(m =>
            m.SourceLanguageCode == src && m.TargetLanguageCode == tgt);
    }

    private static string NormalizeLang(string code) =>
        (code ?? "").Trim().ToLowerInvariant();
}

