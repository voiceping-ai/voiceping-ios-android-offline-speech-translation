using System.IO.Compression;
using System.Text.Json;
using OfflineSpeechTranslation.Models;

namespace OfflineSpeechTranslation.Utilities;

/// <summary>
/// Exports a transcription session as a ZIP archive.
/// Port of iOS ZIPExporter.swift / Android SessionExporter.kt.
/// Bundle: transcript.txt + translation.txt + metadata.json + audio.wav + tts.wav
/// </summary>
public static class ZipExporter
{
    /// <summary>
    /// Create a ZIP file for a transcription record.
    /// Returns the path to the created ZIP.
    /// </summary>
    public static string Export(TranscriptionRecord record, string outputDir)
    {
        Directory.CreateDirectory(outputDir);

        string zipName = $"speech_translation_{record.CreatedAt:yyyyMMdd_HHmmss}.zip";
        string zipPath = Path.Combine(outputDir, zipName);

        if (File.Exists(zipPath))
            File.Delete(zipPath);

        using var archive = ZipFile.Open(zipPath, ZipArchiveMode.Create);

        // transcript.txt
        var textEntry = archive.CreateEntry("transcript.txt");
        using (var writer = new StreamWriter(textEntry.Open()))
        {
            writer.Write(record.Text);
        }

        // translation.txt
        if (!string.IsNullOrWhiteSpace(record.TranslatedText))
        {
            var translationEntry = archive.CreateEntry("translation.txt");
            using var writer = new StreamWriter(translationEntry.Open());
            writer.Write(record.TranslatedText);
        }

        // metadata.json
        var metadata = new
        {
            id = record.Id,
            createdAt = record.CreatedAt.ToString("O"),
            durationSeconds = record.DurationSeconds,
            modelUsed = record.ModelUsed,
            language = record.Language,
            translation = new
            {
                source = record.TranslationSourceLanguage,
                target = record.TranslationTargetLanguage,
                modelId = record.TranslationModelId,
                hasTranslationText = !string.IsNullOrWhiteSpace(record.TranslatedText)
            },
            tts = new
            {
                evidenceFileName = record.TtsEvidenceFileName
            }
        };
        var metaEntry = archive.CreateEntry("metadata.json");
        using (var stream = metaEntry.Open())
        {
            JsonSerializer.Serialize(stream, metadata, new JsonSerializerOptions { WriteIndented = true });
        }

        // audio.wav (if available)
        if (!string.IsNullOrEmpty(record.AudioFileName))
        {
            var audioPath = SessionFileManager.GetAbsolutePath(record.AudioFileName);
            if (File.Exists(audioPath))
            {
                archive.CreateEntryFromFile(audioPath, "audio.wav");
            }
        }

        // tts.wav (if available)
        if (!string.IsNullOrEmpty(record.TtsEvidenceFileName))
        {
            var ttsPath = SessionFileManager.GetAbsolutePath(record.TtsEvidenceFileName);
            if (File.Exists(ttsPath))
            {
                archive.CreateEntryFromFile(ttsPath, "tts.wav");
            }
        }

        return zipPath;
    }
}
