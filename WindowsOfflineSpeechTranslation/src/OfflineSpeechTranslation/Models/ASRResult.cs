namespace OfflineSpeechTranslation.Models;

/// <summary>
/// Result from a transcription operation.
/// </summary>
public record ASRResult(
    string Text,
    IReadOnlyList<ASRSegment> Segments,
    string? DetectedLanguage = null,
    double InferenceTimeMs = 0
)
{
    public static ASRResult Empty => new("", Array.Empty<ASRSegment>());
}
