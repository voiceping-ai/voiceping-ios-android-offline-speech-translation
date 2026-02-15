using System.ComponentModel.DataAnnotations;

namespace OfflineSpeechTranslation.Models;

/// <summary>
/// Persisted transcription session. Port of Android TranscriptionEntity.
/// </summary>
public class TranscriptionRecord
{
    [Key]
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Text { get; set; } = "";
    public string? TranslatedText { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public double DurationSeconds { get; set; }
    public string ModelUsed { get; set; } = "";
    public string? Language { get; set; }
    public string? TranslationSourceLanguage { get; set; }
    public string? TranslationTargetLanguage { get; set; }
    public string? TranslationModelId { get; set; }
    public string? AudioFileName { get; set; }
    public string? TtsEvidenceFileName { get; set; }
}
