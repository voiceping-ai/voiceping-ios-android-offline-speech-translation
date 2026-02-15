namespace OfflineSpeechTranslation.Models;

/// <summary>
/// A single file that needs to be downloaded for a model.
/// Port of Android ModelFile.
/// </summary>
public record ModelFile(string Url, string LocalName);
