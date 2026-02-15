using System.IO.Compression;
using FluentAssertions;
using OfflineSpeechTranslation.Utilities;

namespace OfflineSpeechTranslation.Tests;

public sealed class EvidenceSessionTests
{
    [Fact]
    public void EvidenceSession_WritesEvents_AndExportsZip()
    {
        EvidenceSession? session = null;
        string? zipPath = null;

        try
        {
            session = EvidenceSession.CreateNew("unit_test");

            session.AppendEvent("test_event", new { foo = "bar" });
            session.WriteJson("foo.json", new { hello = "world" });

            var outputDir = Path.Combine(Path.GetTempPath(), "OfflineSpeechTranslation_EvidenceSessionTests");
            zipPath = session.ExportZip(outputDir);

            File.Exists(zipPath).Should().BeTrue();

            using var zip = ZipFile.OpenRead(zipPath);
            zip.Entries.Select(e => e.FullName).Should().Contain("events.jsonl");
            zip.Entries.Select(e => e.FullName).Should().Contain("foo.json");
        }
        finally
        {
            try
            {
                if (zipPath != null && File.Exists(zipPath))
                    File.Delete(zipPath);
            }
            catch { /* best-effort */ }

            try
            {
                if (session != null && Directory.Exists(session.SessionDir))
                    Directory.Delete(session.SessionDir, recursive: true);
            }
            catch { /* best-effort */ }
        }
    }
}
