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
            entity.Property(e => e.AudioFileName);
        });
    }

    /// <summary>Ensure database is created on first use.</summary>
    public static void EnsureCreated()
    {
        using var db = new AppDbContext();
        db.Database.EnsureCreated();
        EnableWalMode();
    }
}
