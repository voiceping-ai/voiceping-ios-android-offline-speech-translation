using System.IO.Compression;
using System.Text.Json;
using OfflineSpeechTranslation.Models;
using OfflineSpeechTranslation.Utilities;

namespace OfflineSpeechTranslation.Tests;

/// <summary>
/// Tests for ZipExporter: archive creation, content verification,
/// and handling of records with and without audio.
/// </summary>
public class ZipExporterTests : IDisposable
{
    private readonly string _tempDir;

    public ZipExporterTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"zip_test_{Guid.NewGuid():N}");
        Directory.CreateDirectory(_tempDir);
    }

    public void Dispose()
    {
        if (Directory.Exists(_tempDir))
            Directory.Delete(_tempDir, recursive: true);
    }

    [Fact]
    public void Export_CreatesZipWithTranscriptAndMetadata()
    {
        var record = new TranscriptionRecord
        {
            Text = "Hello, this is a test transcription.",
            DurationSeconds = 5.0,
            ModelUsed = "whisper-base",
            Language = "en"
        };

        var zipPath = ZipExporter.Export(record, _tempDir);

        Assert.True(File.Exists(zipPath));
        Assert.EndsWith(".zip", zipPath);

        using var archive = ZipFile.OpenRead(zipPath);
        var entryNames = archive.Entries.Select(e => e.FullName).ToList();

        Assert.Contains("transcript.txt", entryNames);
        Assert.Contains("metadata.json", entryNames);
    }

    [Fact]
    public void Export_TranscriptContainsText()
    {
        var record = new TranscriptionRecord
        {
            Text = "The quick brown fox jumps over the lazy dog.",
            DurationSeconds = 3.0,
            ModelUsed = "sensevoice-small"
        };

        var zipPath = ZipExporter.Export(record, _tempDir);

        using var archive = ZipFile.OpenRead(zipPath);
        var textEntry = archive.GetEntry("transcript.txt")!;
        using var reader = new StreamReader(textEntry.Open());
        var content = reader.ReadToEnd();

        Assert.Equal(record.Text, content);
    }

    [Fact]
    public void Export_MetadataContainsFields()
    {
        var record = new TranscriptionRecord
        {
            Text = "Test",
            DurationSeconds = 10.5,
            ModelUsed = "moonshine-tiny",
            Language = "en"
        };

        var zipPath = ZipExporter.Export(record, _tempDir);

        using var archive = ZipFile.OpenRead(zipPath);
        var metaEntry = archive.GetEntry("metadata.json")!;
        using var stream = metaEntry.Open();
        var doc = JsonDocument.Parse(stream);
        var root = doc.RootElement;

        Assert.Equal(record.Id, root.GetProperty("id").GetString());
        Assert.Equal(10.5, root.GetProperty("durationSeconds").GetDouble());
        Assert.Equal("moonshine-tiny", root.GetProperty("modelUsed").GetString());
        Assert.Equal("en", root.GetProperty("language").GetString());
    }

    [Fact]
    public void Export_NoAudio_ZipHasTwoEntries()
    {
        var record = new TranscriptionRecord
        {
            Text = "No audio attached",
            DurationSeconds = 1.0,
            ModelUsed = "whisper-base"
        };

        var zipPath = ZipExporter.Export(record, _tempDir);

        using var archive = ZipFile.OpenRead(zipPath);
        Assert.Equal(2, archive.Entries.Count); // transcript.txt + metadata.json
    }

    [Fact]
    public void Export_OverwritesExistingZip()
    {
        var record = new TranscriptionRecord
        {
            Text = "First export",
            DurationSeconds = 1.0,
            ModelUsed = "whisper-base"
        };

        var zipPath1 = ZipExporter.Export(record, _tempDir);
        var size1 = new FileInfo(zipPath1).Length;

        // Export again with different text — same filename (same timestamp)
        record.Text = "Second export with more text to make it larger";
        var zipPath2 = ZipExporter.Export(record, _tempDir);

        Assert.Equal(zipPath1, zipPath2);
        Assert.True(File.Exists(zipPath2));
    }

    [Fact]
    public void Export_ZipFilename_ContainsTimestamp()
    {
        var record = new TranscriptionRecord
        {
            Text = "Test",
            DurationSeconds = 1.0,
            ModelUsed = "whisper-base"
        };

        var zipPath = ZipExporter.Export(record, _tempDir);
        var fileName = Path.GetFileName(zipPath);

        Assert.StartsWith("transcription_", fileName);
        Assert.EndsWith(".zip", fileName);
        Assert.Matches(@"transcription_\d{8}_\d{6}\.zip", fileName);
    }
}
