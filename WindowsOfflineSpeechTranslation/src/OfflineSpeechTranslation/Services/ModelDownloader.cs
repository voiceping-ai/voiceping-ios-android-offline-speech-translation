using System.Diagnostics;
using OfflineSpeechTranslation.Models;

namespace OfflineSpeechTranslation.Services;

/// <summary>
/// Downloads model files from HuggingFace with progress and resume.
/// Port of Android ModelDownloader.kt + iOS ModelDownloader.swift.
/// </summary>
public sealed class ModelDownloader
{
    private static readonly HttpClient _client = new()
    {
        Timeout = TimeSpan.FromMinutes(10)
    };

    /// <summary>
    /// Base directory for all downloaded models.
    /// %LOCALAPPDATA%\OfflineSpeechTranslation\Models\
    /// </summary>
    public static string ModelsBaseDir =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OfflineSpeechTranslation", "Models");

    /// <summary>
    /// Get the model directory for a specific model.
    /// </summary>
    public static string GetModelDir(ModelInfo model) =>
        Path.Combine(ModelsBaseDir, model.Id);

    /// <summary>
    /// Check if all files for a model are downloaded.
    /// </summary>
    public static bool IsModelDownloaded(ModelInfo model)
    {
        var dir = GetModelDir(model);
        return model.Files.All(f => File.Exists(Path.Combine(dir, f.LocalName)));
    }

    /// <summary>
    /// Get the primary model file path (for engine loading).
    /// For whisper: returns the .bin file. For sherpa-onnx: returns the directory.
    /// </summary>
    public static string GetModelPath(ModelInfo model)
    {
        var dir = GetModelDir(model);
        return model.EngineType == EngineType.WhisperCpp
            ? Path.Combine(dir, model.Files[0].LocalName)
            : dir;
    }

    /// <summary>
    /// Try to delete a file, retrying briefly if it is locked by another process.
    /// </summary>
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

    /// <summary>
    /// Try to move/rename a file, retrying with delays to handle transient locks
    /// (e.g. Windows Defender scanning the file after write).
    /// </summary>
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
                Debug.WriteLine($"[ModelDownloader] File.Move attempt {attempt + 1} failed, retrying...");
                Thread.Sleep(1000);
            }
        }
    }

    /// <summary>
    /// Download a single file from url to targetPath via a .tmp intermediate,
    /// starting fresh (no resume).
    /// </summary>
    private static async Task DownloadFileFreshAsync(
        string url, string targetPath, string tempPath,
        int fileIndex, int totalFiles,
        IProgress<double>? progress, CancellationToken ct)
    {
        TryDeleteFile(tempPath);

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        using var response = await _client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
        response.EnsureSuccessStatusCode();

        var totalBytes = response.Content.Headers.ContentLength ?? 0;
        long bytesWritten = 0;

        await using (var contentStream = await response.Content.ReadAsStreamAsync(ct))
        await using (var fileStream = new FileStream(tempPath, FileMode.Create,
            FileAccess.Write, FileShare.Read, 81920, true))
        {
            var buffer = new byte[81920];
            int bytesRead;

            while ((bytesRead = await contentStream.ReadAsync(buffer, ct)) > 0)
            {
                await fileStream.WriteAsync(buffer.AsMemory(0, bytesRead), ct);
                bytesWritten += bytesRead;

                if (totalBytes > 0)
                    progress?.Report((fileIndex + (double)bytesWritten / totalBytes) / totalFiles);
            }

            await fileStream.FlushAsync(ct);
        }
        // FileStream is now fully disposed

        if (totalBytes > 0 && bytesWritten != totalBytes)
        {
            TryDeleteFile(tempPath);
            throw new IOException(
                $"Download incomplete for {Path.GetFileName(targetPath)}: expected {totalBytes} bytes, got {bytesWritten}");
        }

        TryMoveFile(tempPath, targetPath);
        progress?.Report((fileIndex + 1.0) / totalFiles);
    }

    /// <summary>
    /// Download all files for a model with progress reporting.
    /// Supports resume via HTTP Range headers.
    /// </summary>
    public static async Task DownloadAsync(
        ModelInfo model,
        IProgress<double>? progress = null,
        CancellationToken ct = default)
    {
        var dir = GetModelDir(model);
        Directory.CreateDirectory(dir);

        int totalFiles = model.Files.Count;

        for (int i = 0; i < totalFiles; i++)
        {
            var file = model.Files[i];
            var targetPath = Path.Combine(dir, file.LocalName);
            var tempPath = targetPath + ".tmp";

            // Skip if already downloaded
            if (File.Exists(targetPath))
            {
                progress?.Report((i + 1.0) / totalFiles);
                continue;
            }

            long existingBytes = 0;
            if (File.Exists(tempPath))
            {
                try { existingBytes = new FileInfo(tempPath).Length; }
                catch (IOException) { existingBytes = 0; }
            }

            // If we have partial data, try to resume
            if (existingBytes > 0)
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, file.Url);
                request.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(existingBytes, null);
                Debug.WriteLine($"[ModelDownloader] Resuming {file.LocalName} from byte {existingBytes}");

                HttpResponseMessage response;
                try
                {
                    response = await _client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
                }
                catch
                {
                    // Network error during resume; fall through to fresh download
                    await DownloadFileFreshAsync(file.Url, targetPath, tempPath, i, totalFiles, progress, ct);
                    continue;
                }

                using (response)
                {
                    if (response.StatusCode == System.Net.HttpStatusCode.PartialContent)
                    {
                        // Resume succeeded
                        var totalBytes = (response.Content.Headers.ContentLength ?? 0) + existingBytes;
                        await using var contentStream = await response.Content.ReadAsStreamAsync(ct);

                        long bytesWritten = existingBytes;

                        FileStream fileStream;
                        try
                        {
                            fileStream = new FileStream(tempPath, FileMode.Append,
                                FileAccess.Write, FileShare.Read, 81920, true);
                        }
                        catch (IOException)
                        {
                            // File locked; start fresh
                            await DownloadFileFreshAsync(file.Url, targetPath, tempPath, i, totalFiles, progress, ct);
                            continue;
                        }

                        await using (fileStream)
                        {
                            var buffer = new byte[81920];
                            int bytesRead;

                            while ((bytesRead = await contentStream.ReadAsync(buffer, ct)) > 0)
                            {
                                await fileStream.WriteAsync(buffer.AsMemory(0, bytesRead), ct);
                                bytesWritten += bytesRead;
                                if (totalBytes > 0)
                                    progress?.Report((i + (double)bytesWritten / totalBytes) / totalFiles);
                            }

                            await fileStream.FlushAsync(ct);
                        }
                        // FileStream is now fully disposed

                        if (totalBytes > 0 && bytesWritten != totalBytes)
                        {
                            TryDeleteFile(tempPath);
                            throw new IOException(
                                $"Download incomplete for {file.LocalName}: expected {totalBytes} bytes, got {bytesWritten}");
                        }

                        TryMoveFile(tempPath, targetPath);
                        Debug.WriteLine($"[ModelDownloader] Resumed {file.LocalName}");
                        progress?.Report((i + 1.0) / totalFiles);
                        continue;
                    }

                    // Server returned 200 OK, 416, or other non-206: download fresh
                }

                await DownloadFileFreshAsync(file.Url, targetPath, tempPath, i, totalFiles, progress, ct);
            }
            else
            {
                // No partial data, download from scratch
                await DownloadFileFreshAsync(file.Url, targetPath, tempPath, i, totalFiles, progress, ct);
            }

            Debug.WriteLine($"[ModelDownloader] Downloaded {file.LocalName}");
        }
    }

    /// <summary>
    /// Delete all files for a model to reclaim disk space.
    /// </summary>
    public static void DeleteModel(ModelInfo model)
    {
        var dir = GetModelDir(model);
        if (Directory.Exists(dir))
        {
            Directory.Delete(dir, recursive: true);
            Debug.WriteLine($"[ModelDownloader] Deleted model: {model.Id}");
        }
    }
}
