using Microsoft.EntityFrameworkCore;
using OfflineSpeechTranslation.Models;

namespace OfflineSpeechTranslation.Data;

/// <summary>
/// EF Core SQLite database for transcription history.
/// Port of Android AppDatabase.kt (Room).
/// DB at: %LOCALAPPDATA%\OfflineSpeechTranslation\transcriptions.db
/// </summary>
public class AppDbContext : DbContext
{
    public DbSet<TranscriptionRecord> Transcriptions { get; set; } = null!;

    private static readonly string DbPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "OfflineSpeechTranslation", "transcriptions.db");

    protected override void OnConfiguring(DbContextOptionsBuilder options)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(DbPath)!);
        // Use WAL mode for better concurrent read/write performance (UI reads while background writes).
        options.UseSqlite($"Data Source={DbPath}");
    }

    /// <summary>Enable WAL journal mode for concurrent reads during writes.</summary>
    private static void EnableWalMode()
    {
        try
        {
            using var db = new AppDbContext();
            db.Database.ExecuteSqlRaw("PRAGMA journal_mode=WAL;");
        }
        catch { /* best-effort; default journal mode still works */ }
    }

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<TranscriptionRecord>(entity =>
        {
            entity.HasKey(e => e.Id);
            entity.Property(e => e.Text).IsRequired();
            entity.Property(e => e.CreatedAt);
            entity.Property(e => e.DurationSeconds);
            entity.Property(e => e.ModelUsed);
            entity.Property(e => e.Language);
            entity.Property(e => e.TranslatedText);
            entity.Property(e => e.TranslationSourceLanguage);
            entity.Property(e => e.TranslationTargetLanguage);
            entity.Property(e => e.TranslationModelId);
            entity.Property(e => e.AudioFileName);
            entity.Property(e => e.TtsEvidenceFileName);
        });
    }

    /// <summary>Ensure database is created on first use.</summary>
    public static void EnsureCreated()
    {
        using var db = new AppDbContext();
        db.Database.EnsureCreated();
        EnsureSchemaUpToDate(db);
        EnableWalMode();
    }

    private static void EnsureSchemaUpToDate(AppDbContext db)
    {
        // EnsureCreated does not update an existing database, so we do a minimal additive schema migration.
        // All additions are nullable columns to keep the migration safe.
        try
        {
            var conn = db.Database.GetDbConnection();
            if (conn.State != System.Data.ConnectionState.Open)
                conn.Open();

            var existing = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            using (var cmd = conn.CreateCommand())
            {
                cmd.CommandText = "PRAGMA table_info('Transcriptions');";
                using var reader = cmd.ExecuteReader();
                while (reader.Read())
                {
                    // Columns: cid, name, type, notnull, dflt_value, pk
                    if (reader.FieldCount > 1 && reader.GetValue(1) is string name && !string.IsNullOrWhiteSpace(name))
                        existing.Add(name);
                }
            }

            void EnsureTextColumn(string name)
            {
                if (existing.Contains(name)) return;
                using var alter = conn.CreateCommand();
                alter.CommandText = $"ALTER TABLE Transcriptions ADD COLUMN {name} TEXT;";
                alter.ExecuteNonQuery();
                existing.Add(name);
            }

            EnsureTextColumn("TranslatedText");
            EnsureTextColumn("TranslationSourceLanguage");
            EnsureTextColumn("TranslationTargetLanguage");
            EnsureTextColumn("TranslationModelId");
            EnsureTextColumn("TtsEvidenceFileName");
        }
        catch
        {
            // Best-effort: schema upgrades can fail on locked DBs; app still works without translation history.
        }
    }
}
