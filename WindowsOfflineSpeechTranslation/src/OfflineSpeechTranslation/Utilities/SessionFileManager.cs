namespace OfflineSpeechTranslation.Utilities;

/// <summary>
/// Manages session audio files on disk.
/// Port of iOS SessionFileManager.swift / Android session storage.
/// Storage: %LOCALAPPDATA%\OfflineSpeechTranslation\Sessions\{uuid}\audio.wav
/// </summary>
public static class SessionFileManager
{
    private const string SessionsDirName = "Sessions";

    private static readonly string SessionsBaseDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "OfflineSpeechTranslation", SessionsDirName);

    /// <summary>Save audio for a session. Returns the relative audio file name.</summary>
    public static string SaveAudio(string sessionId, float[] samples)
    {
        var dir = Path.Combine(SessionsBaseDir, sessionId);
        Directory.CreateDirectory(dir);

        var audioPath = Path.Combine(dir, "audio.wav");
        WavWriter.Write(audioPath, samples);

        // Store a relative path in the DB so we can relocate base dir if needed.
        return $"{SessionsDirName}/{sessionId}/audio.wav";
    }

    /// <summary>
    /// Copy a TTS evidence WAV into the session directory. Returns the relative file name.
    /// </summary>
    public static string SaveTtsEvidence(string sessionId, string sourceWavPath)
    {
        if (string.IsNullOrWhiteSpace(sourceWavPath) || !File.Exists(sourceWavPath))
            throw new FileNotFoundException("TTS evidence WAV not found.", sourceWavPath);

        var dir = Path.Combine(SessionsBaseDir, sessionId);
        Directory.CreateDirectory(dir);

        var destPath = Path.Combine(dir, "tts.wav");
        File.Copy(sourceWavPath, destPath, overwrite: true);
        return $"{SessionsDirName}/{sessionId}/tts.wav";
    }

    /// <summary>Get absolute path for a relative audio file name.</summary>
    public static string GetAbsolutePath(string relativeFileName)
    {
        // Back-compat: older records stored "sessions/...".
        var normalized = relativeFileName.Replace('\\', '/').TrimStart('/');
        if (normalized.StartsWith("sessions/", StringComparison.OrdinalIgnoreCase))
            normalized = $"{SessionsDirName}/" + normalized["sessions/".Length..];

        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OfflineSpeechTranslation",
            normalized.Replace('/', Path.DirectorySeparatorChar));
    }

    /// <summary>Delete session files from disk.</summary>
    public static void DeleteSession(string sessionId)
    {
        var dir = Path.Combine(SessionsBaseDir, sessionId);
        if (Directory.Exists(dir))
            Directory.Delete(dir, recursive: true);
    }

    /// <summary>Check if audio file exists for a session.</summary>
    public static bool HasAudio(string? relativeFileName)
    {
        if (string.IsNullOrEmpty(relativeFileName)) return false;
        return File.Exists(GetAbsolutePath(relativeFileName));
    }
}
