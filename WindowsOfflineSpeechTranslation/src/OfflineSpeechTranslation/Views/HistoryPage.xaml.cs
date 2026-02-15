using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OfflineSpeechTranslation.Data;
using OfflineSpeechTranslation.Models;
using OfflineSpeechTranslation.Utilities;

namespace OfflineSpeechTranslation.Views;

public sealed partial class HistoryPage : Page
{
    private List<TranscriptionRecord> _records = [];

    public HistoryPage()
    {
        this.InitializeComponent();
    }

    private void Page_Loaded(object sender, RoutedEventArgs e)
    {
        App.Evidence.LogEvent("history_page_loaded");
        _ = App.Evidence.CaptureScreenshotAsync("history_page_loaded");
        LoadRecords();
    }

    private void LoadRecords()
    {
        try
        {
            AppDbContext.EnsureCreated();

            using var db = new AppDbContext();
            _records = db.Transcriptions
                .OrderByDescending(r => r.CreatedAt)
                .ToList();
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"[HistoryPage] Failed to load records: {ex.Message}");
            _records = [];
        }

        HistoryList.ItemsSource = _records;
        EmptyText.Visibility = _records.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void HistoryList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is TranscriptionRecord record)
        {
            App.Evidence.LogEvent("history_open_record", new { recordId = record.Id });
            _ = App.Evidence.CaptureScreenshotAsync("history_open_record");
            Frame.Navigate(typeof(HistoryDetailPage), record.Id);
        }
    }

    private async void DeleteButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button btn || btn.Tag is not string recordId) return;

        App.Evidence.LogEvent("history_delete_click", new { recordId });
        _ = App.Evidence.CaptureScreenshotAsync("history_delete_click");

        var dialog = new ContentDialog
        {
            Title = "Delete Transcription",
            Content = "This will permanently delete this transcription and its audio.",
            PrimaryButtonText = "Delete",
            CloseButtonText = "Cancel",
            XamlRoot = this.XamlRoot
        };

        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;

        try
        {
            AppDbContext.EnsureCreated();
            using var db = new AppDbContext();
            var record = db.Transcriptions.Find(recordId);
            if (record != null)
            {
                // Delete audio files
                SessionFileManager.DeleteSession(record.Id);

                db.Transcriptions.Remove(record);
                db.SaveChanges();
            }

            App.Evidence.LogEvent("history_delete_success", new { recordId });
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"[HistoryPage] Failed to delete record: {ex.Message}");
            App.Evidence.LogEvent("history_delete_error", new { recordId, error = ex.ToString() }, level: "error");
        }

        _ = App.Evidence.CaptureScreenshotAsync("history_after_delete");
        LoadRecords();
    }
}
