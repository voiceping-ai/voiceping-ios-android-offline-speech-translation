using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OfflineSpeechTranslation.Data;
using OfflineSpeechTranslation.Models;
using OfflineSpeechTranslation.Utilities;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage.Pickers;

namespace OfflineSpeechTranslation.Views;

public sealed partial class HistoryDetailPage : Page
{
    private TranscriptionRecord? _record;

    public HistoryDetailPage()
    {
        this.InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);

        if (e.Parameter is string recordId)
        {
            App.Evidence.LogEvent("history_detail_navigate", new { recordId });
            _ = App.Evidence.CaptureScreenshotAsync("history_detail_navigate");

            try
            {
                AppDbContext.EnsureCreated();
                using var db = new AppDbContext();
                _record = db.Transcriptions.Find(recordId);
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"[HistoryDetailPage] Failed to load record: {ex.Message}");
                _record = null;
            }
        }

        if (_record == null) return;

        DateText.Text = _record.CreatedAt.ToLocalTime().ToString("f");
        ModelText.Text = _record.ModelUsed;
        DurationText.Text = $"{TimeSpan.FromSeconds(_record.DurationSeconds):mm\\:ss}";
        LanguageText.Text = _record.Language ?? "";
        TranscriptText.Text = _record.Text;

        if (!string.IsNullOrWhiteSpace(_record.TranslatedText))
        {
            TranslationSection.Visibility = Visibility.Visible;
            TranslationText.Text = _record.TranslatedText;
            CopyTranslationButton.Visibility = Visibility.Visible;
        }
        else
        {
            TranslationSection.Visibility = Visibility.Collapsed;
            TranslationText.Text = "";
            CopyTranslationButton.Visibility = Visibility.Collapsed;
        }

        // Show waveform if audio available
        if (SessionFileManager.HasAudio(_record.AudioFileName))
        {
            WaveformControl.Visibility = Visibility.Visible;
            var audioPath = SessionFileManager.GetAbsolutePath(_record.AudioFileName!);
            WaveformControl.LoadAudio(audioPath);
        }
    }

    private void CopyTranscript_Click(object sender, RoutedEventArgs e)
    {
        if (_record == null) return;
        App.Evidence.LogEvent("history_copy_transcript", new { recordId = _record.Id });
        var dp = new DataPackage();
        dp.SetText(_record.Text);
        Clipboard.SetContent(dp);
    }

    private void CopyTranslation_Click(object sender, RoutedEventArgs e)
    {
        if (_record == null) return;
        if (string.IsNullOrWhiteSpace(_record.TranslatedText)) return;
        App.Evidence.LogEvent("history_copy_translation", new { recordId = _record.Id });
        var dp = new DataPackage();
        dp.SetText(_record.TranslatedText);
        Clipboard.SetContent(dp);
    }

    private async void ExportZip_Click(object sender, RoutedEventArgs e)
    {
        if (_record == null) return;

        try
        {
            App.Evidence.LogEvent("history_export_zip_click", new { recordId = _record.Id });
            _ = App.Evidence.CaptureScreenshotAsync("history_export_zip_click");

            var picker = new FileSavePicker();
            picker.SuggestedStartLocation = PickerLocationId.DocumentsLibrary;
            picker.FileTypeChoices.Add("ZIP Archive", [".zip"]);
            picker.SuggestedFileName = $"speech_translation_{_record.CreatedAt:yyyyMMdd_HHmmss}";

            var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow);
            WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);

            var file = await picker.PickSaveFileAsync();
            if (file == null) return;

            var tempDir = Path.Combine(Path.GetTempPath(), "OfflineSpeechTranslation_Export");
            var zipPath = ZipExporter.Export(_record, tempDir);

            // Copy to user-selected location
            File.Copy(zipPath, file.Path, overwrite: true);

            // Clean up temp
            try { File.Delete(zipPath); } catch { }

            App.Evidence.LogEvent("history_export_zip_done", new
            {
                recordId = _record.Id,
                outputName = Path.GetFileName(file.Path)
            });
            _ = App.Evidence.CaptureScreenshotAsync("history_export_zip_done");
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"[HistoryDetailPage] ExportZip failed: {ex.Message}");
            App.Evidence.LogEvent("history_export_zip_failed", new { error = ex.ToString() }, level: "error");

            var dialog = new ContentDialog
            {
                Title = "Export Failed",
                Content = ex.Message,
                CloseButtonText = "OK",
                XamlRoot = this.XamlRoot
            };
            await dialog.ShowAsync();
        }
    }
}
