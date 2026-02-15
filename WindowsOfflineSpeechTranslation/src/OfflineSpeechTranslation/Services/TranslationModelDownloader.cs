using System.Diagnostics;
using System.IO.Compression;
using OfflineSpeechTranslation.Models;

namespace OfflineSpeechTranslation.Services;

public sealed class TranslationModelDownloader
{
    private static readonly HttpClient _client = new()
    {
        Timeout = TimeSpan.FromMinutes(10)
    };

    public static string TranslationModelsBaseDir =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OfflineSpeechTranslation", "TranslationModels");

    public static string GetModelDir(TranslationModelInfo model) =>
        Path.Combine(TranslationModelsBaseDir, model.Id);

    public static string GetExtractedDir(TranslationModelInfo model) =>
        Path.Combine(GetModelDir(model), "model");

    private static string GetMarkerPath(TranslationModelInfo model) =>
        Path.Combine(GetModelDir(model), "extracted.ok");

    public static bool IsModelDownloaded(TranslationModelInfo model) =>
        File.Exists(GetMarkerPath(model));

    private static void TryDeleteFile(string path)
    {
        if (!File.Exists(path)) return;
        for (int attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                File.Delete(path);
                return;
            }
            catch (IOException) when (attempt < 4)
            {
                Thread.Sleep(500);
            }
        }
    }

    private static void TryDeleteDirectory(string path)
    {
        if (!Directory.Exists(path)) return;
        for (int attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                Directory.Delete(path, recursive: true);
                return;
            }
            catch (IOException) when (attempt < 4)
            {
                Thread.Sleep(800);
            }
            catch (UnauthorizedAccessException) when (attempt < 4)
            {
                Thread.Sleep(800);
            }
        }
    }

    private static void TryMoveFile(string source, string dest)
    {
        for (int attempt = 0; attempt < 10; attempt++)
        {
            try
            {
                File.Move(source, dest, overwrite: true);
                return;
            }
            catch (IOException) when (attempt < 9)
            {
                Debug.WriteLine($"[TranslationModelDownloader] File.Move attempt {attempt + 1} failed, retrying...");
                Thread.Sleep(1000);
            }
        }
    }

    public static async Task DownloadAndExtractAsync(
        TranslationModelInfo model,
        IProgress<double>? progress = null,
        CancellationToken ct = default)
    {
        var modelDir = GetModelDir(model);
        Directory.CreateDirectory(modelDir);

        var zipPath = Path.Combine(modelDir, "model.zip");
        var tmpPath = zipPath + ".tmp";

        if (!File.Exists(zipPath))
        {
            await DownloadFileWithResumeAsync(model.ZipUrl, zipPath, tmpPath, progress, ct);
        }

        // Extract to a staging folder then swap into place (safer than overwriting in-place).
        var extractedDir = GetExtractedDir(model);
        var stagingDir = extractedDir + ".staging";

        TryDeleteDirectory(stagingDir);
        Directory.CreateDirectory(stagingDir);

        // ZipFile extraction can throw if Defender has the zip locked; retry briefly.
        for (int attempt = 0; attempt < 4; attempt++)
        {
            try
            {
                ZipFile.ExtractToDirectory(zipPath, stagingDir, overwriteFiles: true);
                break;
            }
            catch (IOException) when (attempt < 3)
            {
                await Task.Delay(1000, ct);
            }
        }

        TryDeleteDirectory(extractedDir);
        Directory.Move(stagingDir, extractedDir);

        File.WriteAllText(GetMarkerPath(model), DateTime.UtcNow.ToString("O"));
        progress?.Report(1.0);
    }

    private static async Task DownloadFileWithResumeAsync(
        string url,
        string targetPath,
        string tempPath,
        IProgress<double>? progress,
        CancellationToken ct)
    {
        long existingBytes = 0;
        if (File.Exists(tempPath))
        {
            try { existingBytes = new FileInfo(tempPath).Length; }
            catch (IOException) { existingBytes = 0; }
        }

        if (existingBytes > 0)
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(existingBytes, null);
            Debug.WriteLine($"[TranslationModelDownloader] Resuming from byte {existingBytes}");

            using var response = await _client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
            if (response.StatusCode == System.Net.HttpStatusCode.PartialContent)
            {
                var totalBytes = (response.Content.Headers.ContentLength ?? 0) + existingBytes;
                await using var contentStream = await response.Content.ReadAsStreamAsync(ct);
                await using var fileStream = new FileStream(tempPath, FileMode.Append, FileAccess.Write, FileShare.Read, 81920, true);

                long bytesWritten = existingBytes;
                var buffer = new byte[81920];
                int bytesRead;
                while ((bytesRead = await contentStream.ReadAsync(buffer, ct)) > 0)
                {
                    await fileStream.WriteAsync(buffer.AsMemory(0, bytesRead), ct);
                    bytesWritten += bytesRead;
                    if (totalBytes > 0)
                        progress?.Report((double)bytesWritten / totalBytes);
                }
                await fileStream.FlushAsync(ct);
                TryMoveFile(tempPath, targetPath);
                return;
            }
        }

        // Fresh download
        TryDeleteFile(tempPath);
        using (var request = new HttpRequestMessage(HttpMethod.Get, url))
        using (var response = await _client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct))
        {
            response.EnsureSuccessStatusCode();
            var totalBytes = response.Content.Headers.ContentLength ?? 0;
            long bytesWritten = 0;

            await using var contentStream = await response.Content.ReadAsStreamAsync(ct);
            await using var fileStream = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.Read, 81920, true);

            var buffer = new byte[81920];
            int bytesRead;
            while ((bytesRead = await contentStream.ReadAsync(buffer, ct)) > 0)
            {
                await fileStream.WriteAsync(buffer.AsMemory(0, bytesRead), ct);
                bytesWritten += bytesRead;
                if (totalBytes > 0)
                    progress?.Report((double)bytesWritten / totalBytes);
            }
            await fileStream.FlushAsync(ct);
        }

        TryMoveFile(tempPath, targetPath);
    }
}

