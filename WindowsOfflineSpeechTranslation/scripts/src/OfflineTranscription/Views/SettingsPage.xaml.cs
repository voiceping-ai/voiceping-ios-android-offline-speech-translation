using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OfflineSpeechTranslation.Models;
using OfflineSpeechTranslation.Services;
using OfflineSpeechTranslation.Utilities;
using Windows.Storage.Pickers;

namespace OfflineSpeechTranslation.Views;

public sealed partial class SettingsPage : Page
{
    public AppPreferences Prefs => App.Preferences;
    private TranscriptionService Service => App.TranscriptionService;
    private EvidenceService Evidence => App.Evidence;

    private bool _initializing;

    public SettingsPage()
    {
        _initializing = true;
        this.InitializeComponent();
        ModelListView.ItemsSource = ModelInfo.AvailableModels;
        UpdateCurrentModelText();

        // Initialize capture source selection from preferences.
        CaptureSourceCombo.SelectedIndex = Prefs.CaptureSource == CaptureSource.SystemLoopback ? 1 : 0;

        // Diagnostics toggles
        EvidenceModeToggle.IsOn = Prefs.EvidenceMode;
        EvidenceIncludeTextToggle.IsOn = Prefs.EvidenceIncludeTranscriptText;
        UpdateEvidenceStatusText();

        _initializing = false;
    }

    private void UpdateCurrentModelText()
    {
        var model = Service.CurrentModel;
        CurrentModelText.Text = model != null
            ? $"{model.DisplayName} — {model.InferenceMethod}"
            : "No model loaded. Select one below.";
    }

    private async void ModelItem_Click(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not ModelInfo model) return;
        if (Service.IsBusy) return;

        Evidence.LogEvent("settings_model_click", new { modelId = model.Id, displayName = model.DisplayName });
        _ = Evidence.CaptureScreenshotAsync($"settings_model_click_{model.Id}");

        // Confirm if switching from loaded model
        if (Service.CurrentModel != null && Service.CurrentModel.Id != model.Id)
        {
            var dialog = new ContentDialog
            {
                Title = "Switch Model",
                Content = $"Switch to {model.DisplayName}? Current transcription will be cleared.",
                PrimaryButtonText = "Switch",
                CloseButtonText = "Cancel",
                XamlRoot = this.XamlRoot
            };

            if (await dialog.ShowAsync() != ContentDialogResult.Primary)
                return;
        }

        try
        {
            await Service.SelectAndLoadModelAsync(model);
            UpdateCurrentModelText();
            Evidence.CaptureModelEvidence(model);
            _ = Evidence.CaptureScreenshotAsync($"settings_model_loaded_{model.Id}");

            // Navigate back to transcription
            Frame.Navigate(typeof(TranscriptionPage));
        }
        catch (Exception ex)
        {
            Evidence.LogEvent("settings_model_load_error", new { modelId = model.Id, error = ex.ToString() }, level: "error");
            _ = Evidence.CaptureScreenshotAsync($"settings_model_error_{model.Id}");

            var dialog = new ContentDialog
            {
                Title = "Model Load Failed",
                Content = ex.Message,
                CloseButtonText = "OK",
                XamlRoot = this.XamlRoot
            };
            await dialog.ShowAsync();
        }
    }

    private void CopyText_Click(object sender, RoutedEventArgs e)
    {
        Evidence.LogEvent("settings_copy_text");
        App.TranscriptionVM.CopyTextCommand.Execute(null);
    }

    private void ClearText_Click(object sender, RoutedEventArgs e)
    {
        Evidence.LogEvent("settings_clear_text");
        App.TranscriptionVM.ClearTranscriptionCommand.Execute(null);
    }

    private void CaptureSourceCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_initializing) return;
        if (CaptureSourceCombo.SelectedItem is not ComboBoxItem item) return;
        if (item.Tag is not string tag) return;

        if (Enum.TryParse<CaptureSource>(tag, ignoreCase: true, out var src))
        {
            Prefs.CaptureSource = src;
            Evidence.LogEvent("settings_capture_source", new { source = src.ToString() });
            _ = Evidence.CaptureScreenshotAsync("settings_capture_source");
        }
    }

    private async void EvidenceModeToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (_initializing) return;
        bool previous = Prefs.EvidenceMode;
        try
        {
            Prefs.EvidenceMode = EvidenceModeToggle.IsOn;

            if (Prefs.EvidenceMode)
            {
                var session = Evidence.StartNewSession("enabled");
                await Evidence.CaptureScreenshotAsync("evidence_enabled");

                EvidenceStatusText.Text =
                    $"Evidence enabled.\nSession: {session.SessionId}\n{session.SessionDir}";
            }
            else
            {
                EvidenceStatusText.Text = "Evidence mode is off.";
            }
        }
        catch (Exception ex)
        {
            Evidence.LogEvent("evidence_mode_toggle_failed", new { error = ex.ToString() }, level: "error");
            Prefs.EvidenceMode = previous;
            _initializing = true;
            EvidenceModeToggle.IsOn = Prefs.EvidenceMode;
            _initializing = false;

            var dialog = new ContentDialog
            {
                Title = "Evidence Mode Failed",
                Content = ex.Message,
                CloseButtonText = "OK",
                XamlRoot = this.XamlRoot
            };
            await dialog.ShowAsync();
        }
    }

    private void EvidenceIncludeTextToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (_initializing) return;
        Prefs.EvidenceIncludeTranscriptText = EvidenceIncludeTextToggle.IsOn;
        Evidence.LogEvent("evidence_include_transcript_text", new { enabled = Prefs.EvidenceIncludeTranscriptText });
        UpdateEvidenceStatusText();
    }

    private async void StartEvidenceSession_Click(object sender, RoutedEventArgs e)
    {
        if (!Prefs.EvidenceMode)
        {
            var dialog = new ContentDialog
            {
                Title = "Evidence Mode Off",
                Content = "Enable Evidence Mode first.",
                CloseButtonText = "OK",
                XamlRoot = this.XamlRoot
            };
            await dialog.ShowAsync();
            return;
        }

        try
        {
            var session = Evidence.StartNewSession("manual");
            await Evidence.CaptureScreenshotAsync("evidence_session_started");
            UpdateEvidenceStatusText();

            var ok = new ContentDialog
            {
                Title = "Evidence Session Started",
                Content = session.SessionDir,
                CloseButtonText = "OK",
                XamlRoot = this.XamlRoot
            };
            await ok.ShowAsync();
        }
        catch (Exception ex)
        {
            Evidence.LogEvent("evidence_session_start_failed", new { error = ex.ToString() }, level: "error");
            var dialog = new ContentDialog
            {
                Title = "Start Session Failed",
                Content = ex.Message,
                CloseButtonText = "OK",
                XamlRoot = this.XamlRoot
            };
            await dialog.ShowAsync();
        }
    }

    private async void CaptureEvidenceScreenshot_Click(object sender, RoutedEventArgs e)
    {
        if (!Prefs.EvidenceMode)
        {
            var dialog = new ContentDialog
            {
                Title = "Evidence Mode Off",
                Content = "Enable Evidence Mode first.",
                CloseButtonText = "OK",
                XamlRoot = this.XamlRoot
            };
            await dialog.ShowAsync();
            return;
        }

        try
        {
            var path = await Evidence.CaptureScreenshotAsync("manual");
            UpdateEvidenceStatusText();

            if (path == null)
            {
                var empty = new ContentDialog
                {
                    Title = "Screenshot Not Captured",
                    Content = "No screenshot was captured. Try again.",
                    CloseButtonText = "OK",
                    XamlRoot = this.XamlRoot
                };
                await empty.ShowAsync();
                return;
            }

            var ok = new ContentDialog
            {
                Title = "Evidence Screenshot Saved",
                Content = path,
                CloseButtonText = "OK",
                XamlRoot = this.XamlRoot
            };
            await ok.ShowAsync();
        }
        catch (Exception ex)
        {
            Evidence.LogEvent("evidence_screenshot_failed", new { error = ex.ToString() }, level: "error");
            var dialog = new ContentDialog
            {
                Title = "Capture Failed",
                Content = ex.Message,
                CloseButtonText = "OK",
                XamlRoot = this.XamlRoot
            };
            await dialog.ShowAsync();
        }
    }

    private async void ExportEvidenceZip_Click(object sender, RoutedEventArgs e)
    {
        if (!Prefs.EvidenceMode)
        {
            var dialog = new ContentDialog
            {
                Title = "Evidence Mode Off",
                Content = "Enable Evidence Mode first.",
                CloseButtonText = "OK",
                XamlRoot = this.XamlRoot
            };
            await dialog.ShowAsync();
            return;
        }

        try
        {
            var picker = new FileSavePicker();
            picker.SuggestedStartLocation = PickerLocationId.DocumentsLibrary;
            picker.FileTypeChoices.Add("ZIP Archive", [".zip"]);
            picker.SuggestedFileName = $"evidence_{DateTime.Now:yyyyMMdd_HHmmss}";

            if (App.MainWindow == null)
                throw new InvalidOperationException("Main window is not available.");

            var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow);
            WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);

            var file = await picker.PickSaveFileAsync();
            if (file == null) return;

            var tempDir = Path.Combine(Path.GetTempPath(), "OfflineSpeechTranslation_EvidenceExport");
            var zipPath = Evidence.ExportZip(tempDir);
            if (zipPath == null)
                throw new IOException("Failed to create evidence ZIP.");

            File.Copy(zipPath, file.Path, overwrite: true);
            try { File.Delete(zipPath); } catch { /* best-effort */ }

            UpdateEvidenceStatusText();

            var ok = new ContentDialog
            {
                Title = "Evidence ZIP Exported",
                Content = file.Path,
                CloseButtonText = "OK",
                XamlRoot = this.XamlRoot
            };
            await ok.ShowAsync();
        }
        catch (Exception ex)
        {
            Evidence.LogEvent("evidence_export_failed", new { error = ex.ToString() }, level: "error");
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

    private async void SaveScreenshot_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var path = await ScreenCapture.SaveMainWindowScreenshotAsync();
            if (path == null) return;

            Evidence.LogEvent("settings_save_screenshot", new { path });

            var dialog = new ContentDialog
            {
                Title = "Screenshot Saved",
                Content = path,
                CloseButtonText = "OK",
                XamlRoot = this.XamlRoot
            };
            await dialog.ShowAsync();
        }
        catch (Exception ex)
        {
            Evidence.LogEvent("settings_save_screenshot_failed", new { error = ex.ToString() }, level: "error");
            var dialog = new ContentDialog
            {
                Title = "Screenshot Failed",
                Content = ex.Message,
                CloseButtonText = "OK",
                XamlRoot = this.XamlRoot
            };
            await dialog.ShowAsync();
        }
    }

    private void VadToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (_initializing) return;
        Evidence.LogEvent("settings_vad", new { enabled = Prefs.UseVAD });
        _ = Evidence.CaptureScreenshotAsync("settings_vad");
    }

    private void TimestampsToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (_initializing) return;
        Evidence.LogEvent("settings_timestamps", new { enabled = Prefs.ShowTimestamps });
        _ = Evidence.CaptureScreenshotAsync("settings_timestamps");
    }

    private void UpdateEvidenceStatusText()
    {
        if (!Prefs.EvidenceMode)
        {
            EvidenceStatusText.Text = "Evidence mode is off.";
            return;
        }

        var sessionId = Evidence.ActiveSessionId ?? "(no session)";
        var sessionDir = Evidence.ActiveSessionDir ?? "";
        EvidenceStatusText.Text = $"Session: {sessionId}\n{sessionDir}";
    }
}
