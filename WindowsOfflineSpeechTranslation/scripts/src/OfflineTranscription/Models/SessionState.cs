namespace OfflineSpeechTranslation.Models;

/// <summary>
/// Recording session state machine.
/// </summary>
public enum SessionState
{
    Idle,
    Starting,
    Recording,
    Stopping
}
