namespace OfflineSpeechTranslation.Models;

/// <summary>
/// A single transcription segment with optional timestamps.
/// Port of Android TranscriptionSegment / iOS ASRSegment.
/// </summary>
public record ASRSegment(
    string Text,
    long StartMs = 0,
    long EndMs = 0,
    string? DetectedLanguage = null
);
