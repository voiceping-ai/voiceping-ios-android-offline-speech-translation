using System.IO.Compression;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OfflineSpeechTranslation.Utilities;

/// <summary>
/// Collects structured evidence for real-device bug reports.
/// Writes a JSONL event log plus supporting artifacts (screenshots, manifests),
/// then can export a single ZIP for sharing.
/// </summary>
public sealed class EvidenceSession
{
    private static readonly JsonSerializerOptions JsonIndented = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() }
    };

    private static readonly JsonSerializerOptions JsonCompact = new()
    {
        WriteIndented = false,
        Converters = { new JsonStringEnumConverter() }
    };

    private readonly object _ioLock = new();

    public string SessionId { get; }
    public string SessionDir { get; }
    public DateTimeOffset CreatedAtUtc { get; }

    public string EventsPath => Path.Combine(SessionDir, "events.jsonl");

    public static string EvidenceBaseDir =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OfflineSpeechTranslation",
            "Evidence");

    private EvidenceSession(string sessionId, string sessionDir, DateTimeOffset createdAtUtc)
    {
        SessionId = sessionId;
        SessionDir = sessionDir;
        CreatedAtUtc = createdAtUtc;
    }

    public static EvidenceSession CreateNew(string? label = null)
    {
        var createdAt = DateTimeOffset.UtcNow;

        var id = $"{createdAt:yyyyMMdd_HHmmss}_{Guid.NewGuid().ToString("N")[..8]}";

        var safeLabel = SanitizeLabel(label);
        var folderName = safeLabel is null ? id : $"{id}_{safeLabel}";

        var sessionDir = Path.Combine(EvidenceBaseDir, folderName);
        Directory.CreateDirectory(sessionDir);

        return new EvidenceSession(folderName, sessionDir, createdAt);
    }

    public static bool TryOpenExisting(string sessionId, out EvidenceSession? session)
    {
        session = null;
        if (string.IsNullOrWhiteSpace(sessionId)) return false;

        try
        {
            var dir = Path.Combine(EvidenceBaseDir, sessionId);
            if (!Directory.Exists(dir)) return false;
            var createdAt = TryReadCreatedAtUtc(dir) ?? DateTimeOffset.UtcNow;
            session = new EvidenceSession(sessionId, dir, createdAt);
            return true;
        }
        catch
        {
            return false;
        }
    }

    public void AppendEvent(string name, object? data = null, string level = "info")
    {
        var entry = new
        {
            ts = DateTimeOffset.UtcNow.ToString("O"),
            level,
            @event = name,
            data
        };

        var line = JsonSerializer.Serialize(entry, JsonCompact);

        lock (_ioLock)
        {
            Directory.CreateDirectory(SessionDir);
            File.AppendAllText(EventsPath, line + Environment.NewLine, Encoding.UTF8);
        }
    }

    public void WriteJson(string relativePath, object value)
    {
        var fullPath = GetFullPath(relativePath);
        var dir = Path.GetDirectoryName(fullPath);
        if (!string.IsNullOrEmpty(dir))
            Directory.CreateDirectory(dir);

        lock (_ioLock)
        {
            // Serialize inside the lock to avoid capturing a mutated object from another thread.
            var json = JsonSerializer.Serialize(value, JsonIndented);
            File.WriteAllText(fullPath, json, Encoding.UTF8);
        }
    }

    public void WriteText(string relativePath, string text)
    {
        var fullPath = GetFullPath(relativePath);
        var dir = Path.GetDirectoryName(fullPath);
        if (!string.IsNullOrEmpty(dir))
            Directory.CreateDirectory(dir);

        lock (_ioLock)
        {
            File.WriteAllText(fullPath, text, Encoding.UTF8);
        }
    }

    public void CopyFileIntoSession(string sourcePath, string relativeDestPath, bool overwrite = true)
    {
        if (string.IsNullOrWhiteSpace(sourcePath) || !File.Exists(sourcePath)) return;

        var destPath = GetFullPath(relativeDestPath);
        var dir = Path.GetDirectoryName(destPath);
        if (!string.IsNullOrEmpty(dir))
            Directory.CreateDirectory(dir);

        lock (_ioLock)
        {
            File.Copy(sourcePath, destPath, overwrite);
        }
    }

    public string ExportZip(string outputDir)
    {
        Directory.CreateDirectory(outputDir);

        var zipName = $"evidence_{SessionId}.zip";
        var zipPath = Path.Combine(outputDir, zipName);

        if (File.Exists(zipPath))
            File.Delete(zipPath);

        // Important: keep the ZIP outside SessionDir to avoid self-inclusion.
        ZipFile.CreateFromDirectory(SessionDir, zipPath, CompressionLevel.Optimal, includeBaseDirectory: false);
        return zipPath;
    }

    public string GetFullPath(string relativePath)
    {
        var normalized = relativePath.Replace('\\', '/').TrimStart('/');
        var fullPath = Path.GetFullPath(Path.Combine(SessionDir, normalized.Replace('/', Path.DirectorySeparatorChar)));

        // Prevent path traversal outside the session directory.
        if (!fullPath.StartsWith(SessionDir, StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException($"Path traversal detected: '{relativePath}' resolves outside session directory");

        return fullPath;
    }

    public static string MakeFileName(string extension, string? label = null)
    {
        var safeLabel = SanitizeLabel(label);
        var ts = DateTimeOffset.UtcNow.ToString("yyyyMMdd_HHmmss_fff");
        var ext = extension.Trim().TrimStart('.');
        return safeLabel is null ? $"{ts}.{ext}" : $"{ts}_{safeLabel}.{ext}";
    }

    private static string? SanitizeLabel(string? label)
    {
        if (string.IsNullOrWhiteSpace(label)) return null;

        var invalid = Path.GetInvalidFileNameChars().ToHashSet();
        var sb = new StringBuilder(label.Length);
        foreach (var ch in label.Trim())
        {
            if (invalid.Contains(ch)) continue;
            sb.Append(char.IsWhiteSpace(ch) ? '_' : ch);
        }

        var cleaned = sb.ToString();
        if (string.IsNullOrWhiteSpace(cleaned)) return null;

        cleaned = cleaned.Trim('_');
        if (cleaned.Length > 48) cleaned = cleaned[..48];
        return cleaned;
    }

    private static DateTimeOffset? TryReadCreatedAtUtc(string sessionDir)
    {
        try
        {
            var path = Path.Combine(sessionDir, "manifest.json");
            if (!File.Exists(path)) return null;

            using var doc = JsonDocument.Parse(File.ReadAllText(path, Encoding.UTF8));
            if (!doc.RootElement.TryGetProperty("createdAtUtc", out var prop)) return null;

            var s = prop.GetString();
            if (string.IsNullOrWhiteSpace(s)) return null;
            if (DateTimeOffset.TryParse(s, out var dto)) return dto;
            return null;
        }
        catch
        {
            return null;
        }
    }
}
