using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OfflineSpeechTranslation.Models;
using OfflineSpeechTranslation.Services;
using OfflineSpeechTranslation.ViewModels;

namespace OfflineSpeechTranslation.Views;

public sealed partial class TranscriptionPage : Page
{
    public TranscriptionViewModel VM => App.TranscriptionVM;

    private bool _serviceSubscribed;

    // Computed binding helpers
    public Visibility ShowPlaceholder =>
        string.IsNullOrEmpty(VM.Service.ConfirmedText) && string.IsNullOrEmpty(VM.Service.HypothesisText)
            ? Visibility.Visible : Visibility.Collapsed;

    public Visibility ShowLoadingOverlay =>
        VM.Service.ModelState is ASRModelState.Downloading or ASRModelState.Loading
            ? Visibility.Visible : Visibility.Collapsed;

    public Visibility ShowDownloadProgress =>
        VM.Service.ModelState == ASRModelState.Downloading
            ? Visibility.Visible : Visibility.Collapsed;

    public string StatsText
    {
        get
        {
            var dur = TimeSpan.FromSeconds(VM.Service.BufferSeconds);
            return $"{dur:mm\\:ss} | {VM.Service.TokensPerSecond:F1} tok/s";
        }
    }

    public string ResourceText =>
        $"CPU: {VM.Service.CpuPercent:F0}% | RAM: {VM.Service.MemoryMB:F0} MB";

    public string ModelInfoText =>
        VM.Service.CurrentModel != null
            ? $"{VM.Service.CurrentModel.DisplayName} ({VM.Service.CurrentModel.InferenceMethod})"
            : "No model loaded";

    public TranscriptionPage()
    {
        this.InitializeComponent();
        Loaded += (_, _) => AttachServiceHandlers();
        Unloaded += (_, _) => DetachServiceHandlers();
    }

    private async void Page_Loaded(object sender, RoutedEventArgs e)
    {
        App.Evidence.LogEvent("transcription_page_loaded");
        _ = App.Evidence.CaptureScreenshotAsync("transcription_page_loaded");

        // Auto-load saved model if available
        if (VM.Service.ModelState == ASRModelState.Unloaded)
        {
            try
            {
                await VM.LoadSavedModelAsync();
            }
            catch (Exception ex)
            {
                App.Evidence.LogEvent("saved_model_auto_load_failed", new { error = ex.ToString() }, level: "error");

                var dialog = new ContentDialog
                {
                    Title = "Model Auto-Load Failed",
                    Content = ex.Message,
                    CloseButtonText = "OK",
                    XamlRoot = this.XamlRoot
                };
                await dialog.ShowAsync();
            }
        }

        // Auto-transcribe test audio if trigger file or --test-audio argument is present
        var triggerFile = Path.Combine(AppContext.BaseDirectory, "test-audio.trigger");
        var args = Environment.GetCommandLineArgs();
        bool shouldTest = File.Exists(triggerFile) || args.Any(a => a == "--test-audio");
        if (shouldTest && VM.Service.ModelState == ASRModelState.Loaded)
        {
            try { File.Delete(triggerFile); } catch { }
            await VM.TranscribeTestAudioCommand.ExecuteAsync(null);
        }
    }

    private void RecordButton_Click(object sender, RoutedEventArgs e)
    {
        App.Evidence.LogEvent("ui_record_button_click");
        VM.ToggleRecordingCommand.Execute(null);
    }

    private void SettingsButton_Click(object sender, RoutedEventArgs e)
    {
        App.Evidence.LogEvent("ui_open_settings");
        Frame.Navigate(typeof(SettingsPage));
    }

    private void AttachServiceHandlers()
    {
        if (_serviceSubscribed) return;
        VM.Service.PropertyChanged += Service_PropertyChanged;
        _serviceSubscribed = true;

        // Ensure x:Bind computed properties reflect current state.
        Bindings.Update();
    }

    private void DetachServiceHandlers()
    {
        if (!_serviceSubscribed) return;
        VM.Service.PropertyChanged -= Service_PropertyChanged;
        _serviceSubscribed = false;
    }

    private void Service_PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        // Refresh computed x:Bind properties (StatsText, ShowPlaceholder, etc.).
        // Keep this filtered to avoid calling Bindings.Update() for every property change.
        switch (e.PropertyName)
        {
            case nameof(SpeechTranslationService.ConfirmedText):
            case nameof(SpeechTranslationService.HypothesisText):
            case nameof(SpeechTranslationService.BufferSeconds):
            case nameof(SpeechTranslationService.TokensPerSecond):
            case nameof(SpeechTranslationService.CpuPercent):
            case nameof(SpeechTranslationService.MemoryMB):
            case nameof(SpeechTranslationService.ModelState):
            case nameof(SpeechTranslationService.SessionState):
                DispatcherQueue.TryEnqueue(() => Bindings.Update());
                break;
        }
    }
}
