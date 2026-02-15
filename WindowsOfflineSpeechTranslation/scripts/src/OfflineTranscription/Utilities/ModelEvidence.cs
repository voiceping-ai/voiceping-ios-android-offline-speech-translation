using System.Security.Cryptography;
using OfflineSpeechTranslation.Models;
using OfflineSpeechTranslation.Services;

namespace OfflineSpeechTranslation.Utilities;

public static class ModelEvidence
{
    private const long MaxHashBytes = 20L * 1024 * 1024; // 20 MB

    public static ModelsEvidenceSnapshot CaptureAll(IEnumerable<ModelInfo> models)
    {
        var list = models.Select(Capture).ToList();
        return new ModelsEvidenceSnapshot(
            CapturedAtUtc: DateTimeOffset.UtcNow.ToString("O"),
            ModelsBaseDir: ModelDownloader.ModelsBaseDir,
            Models: list);
    }

    public static ModelEvidenceSnapshot Capture(ModelInfo model)
    {
        var modelDir = ModelDownloader.GetModelDir(model);
        var files = new List<ModelFileEvidence>(model.Files.Count);

        foreach (var f in model.Files)
        {
            var path = Path.Combine(modelDir, f.LocalName);
            if (!File.Exists(path))
            {
                files.Add(new ModelFileEvidence(
                    LocalName: f.LocalName,
                    Url: f.Url,
                    Exists: false,
                    SizeBytes: null,
                    LastWriteTimeUtc: null,
                    Sha256: null));
                continue;
            }

            var info = new FileInfo(path);
            string? sha = null;
            if (info.Length <= MaxHashBytes)
                sha = TrySha256(path);

            files.Add(new ModelFileEvidence(
                LocalName: f.LocalName,
                Url: f.Url,
                Exists: true,
                SizeBytes: info.Length,
                LastWriteTimeUtc: info.LastWriteTimeUtc.ToString("O"),
                Sha256: sha));
        }

        return new ModelEvidenceSnapshot(
            CapturedAtUtc: DateTimeOffset.UtcNow.ToString("O"),
            ModelId: model.Id,
            DisplayName: model.DisplayName,
            EngineType: model.EngineType,
            ModelDir: modelDir,
            IsDownloaded: ModelDownloader.IsModelDownloaded(model),
            Files: files);
    }

    private static string? TrySha256(string path)
    {
        try
        {
            using var stream = File.OpenRead(path);
            using var sha = SHA256.Create();
            var hash = sha.ComputeHash(stream);
            return Convert.ToHexString(hash).ToLowerInvariant();
        }
        catch
        {
            return null;
        }
    }
}

public sealed record ModelsEvidenceSnapshot(
    string CapturedAtUtc,
    string ModelsBaseDir,
    IReadOnlyList<ModelEvidenceSnapshot> Models);

public sealed record ModelEvidenceSnapshot(
    string CapturedAtUtc,
    string ModelId,
    string DisplayName,
    EngineType EngineType,
    string ModelDir,
    bool IsDownloaded,
    IReadOnlyList<ModelFileEvidence> Files);

public sealed record ModelFileEvidence(
    string LocalName,
    string Url,
    bool Exists,
    long? SizeBytes,
    string? LastWriteTimeUtc,
    string? Sha256);

