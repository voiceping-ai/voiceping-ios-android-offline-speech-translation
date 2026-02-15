namespace OfflineSpeechTranslation.Models;

/// <summary>
/// State machine for model lifecycle.
/// Matches iOS ASRModelState / Android ModelState.
/// </summary>
public enum ASRModelState
{
    Unloaded,
    Downloading,
    Loading,
    Loaded,
    Error
}
