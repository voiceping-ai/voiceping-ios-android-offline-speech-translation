using System.Diagnostics;
using System.Text.Json;
using OfflineSpeechTranslation.Models;

namespace OfflineSpeechTranslation.Services;

/// <summary>
/// App settings persisted as JSON. Port of Android AppPreferences.kt.
/// Stored at %LOCALAPPDATA%\OfflineSpeechTranslation\settings.json.
/// </summary>
public sealed class AppPreferences
{
    private static readonly string SettingsPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "OfflineSpeechTranslation", "settings.json");

    private SettingsData _data;
    private readonly object _saveLock = new();

    public static string SettingsFilePath => SettingsPath;

    public string? SelectedModelId
    {
        get => _data.SelectedModelId;
        set { _data.SelectedModelId = value; Save(); }
    }

    public bool UseVAD
    {
        get => _data.UseVAD;
        set { _data.UseVAD = value; Save(); }
    }

    public bool ShowTimestamps
    {
        get => _data.ShowTimestamps;
        set { _data.ShowTimestamps = value; Save(); }
    }

    public CaptureSource CaptureSource
    {
        get
        {
            if (Enum.TryParse<CaptureSource>(_data.CaptureSource, ignoreCase: true, out var src))
                return src;
            return CaptureSource.Microphone;
        }
        set { _data.CaptureSource = value.ToString(); Save(); }
    }

    public bool EvidenceMode
    {
        get => _data.EvidenceMode;
        set { _data.EvidenceMode = value; Save(); }
    }

    public string? EvidenceSessionFolder
    {
        get => _data.EvidenceSessionFolder;
        set { _data.EvidenceSessionFolder = value; Save(); }
    }

    public bool EvidenceIncludeTranscriptText
    {
        get => _data.EvidenceIncludeTranscriptText;
        set { _data.EvidenceIncludeTranscriptText = value; Save(); }
    }

    public AppPreferences()
    {
        _data = Load();
    }

    private static SettingsData Load()
    {
        try
        {
            if (File.Exists(SettingsPath))
            {
                var json = File.ReadAllText(SettingsPath);
                return JsonSerializer.Deserialize<SettingsData>(json) ?? new SettingsData();
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[AppPreferences] Failed to load: {ex.Message}");
        }
        return new SettingsData();
    }

    private void Save()
    {
        lock (_saveLock)
        {
            try
            {
                var dir = Path.GetDirectoryName(SettingsPath)!;
                Directory.CreateDirectory(dir);
                var json = JsonSerializer.Serialize(_data, new JsonSerializerOptions { WriteIndented = true });
                File.WriteAllText(SettingsPath, json);
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[AppPreferences] Failed to save: {ex.Message}");
            }
        }
    }

    private class SettingsData
    {
        public string? SelectedModelId { get; set; }
        public bool UseVAD { get; set; } = true;
        public bool ShowTimestamps { get; set; } = false;
        public string CaptureSource { get; set; } = "Microphone";
        public bool EvidenceMode { get; set; } = false;
        public string? EvidenceSessionFolder { get; set; }
        public bool EvidenceIncludeTranscriptText { get; set; } = false;
    }
}
