using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OfflineSpeechTranslation.Models;
using OfflineSpeechTranslation.Services;

namespace OfflineSpeechTranslation.Views;

public sealed partial class ModelSetupPage : Page
{
    public ModelSetupPage()
    {
        this.InitializeComponent();
        ModelList.ItemsSource = ModelInfo.AvailableModels;
    }

    private async void ModelList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ModelList.SelectedItem is not ModelInfo model) return;

        App.Evidence.LogEvent("model_setup_select", new { modelId = model.Id, displayName = model.DisplayName });
        _ = App.Evidence.CaptureScreenshotAsync($"model_setup_select_{model.Id}");

        LoadingOverlay.Visibility = Visibility.Visible;
        LoadingText.Text = $"Preparing {model.DisplayName}...";
        LoadingProgress.Value = 0;
        ModelList.IsEnabled = false;

        var service = App.TranscriptionService;

        // Track download progress (detach when done to avoid leaks/duplicate handlers)
        System.ComponentModel.PropertyChangedEventHandler handler = (s, args) =>
        {
            if (args.PropertyName == nameof(service.DownloadProgress))
            {
                DispatcherQueue.TryEnqueue(() =>
                {
                    LoadingProgress.Value = service.DownloadProgress;
                    LoadingText.Text = service.LoadingStatusMessage;
                });
            }
            else if (args.PropertyName == nameof(service.LoadingStatusMessage))
            {
                DispatcherQueue.TryEnqueue(() =>
                    LoadingText.Text = service.LoadingStatusMessage);
            }
        };
        service.PropertyChanged += handler;

        try
        {
            await service.SelectAndLoadModelAsync(model);

            if (service.ModelState == ASRModelState.Loaded)
            {
                App.Evidence.LogEvent("model_setup_loaded", new { modelId = model.Id });
                App.Evidence.CaptureModelEvidence(model);
                _ = App.Evidence.CaptureScreenshotAsync($"model_setup_loaded_{model.Id}");

                // Navigate to transcription page
                Frame.Navigate(typeof(TranscriptionPage));
            }
            else
            {
                LoadingOverlay.Visibility = Visibility.Collapsed;
                var dialog = new ContentDialog
                {
                    Title = "Error",
                    Content = $"Failed to load {model.DisplayName}. Please try another model.",
                    CloseButtonText = "OK",
                    XamlRoot = this.XamlRoot
                };
                await dialog.ShowAsync();
            }
        }
        catch (Exception ex)
        {
            App.Evidence.LogEvent("model_setup_error", new { modelId = model.Id, error = ex.Message }, level: "error");
            _ = App.Evidence.CaptureScreenshotAsync($"model_setup_error_{model.Id}");

            LoadingOverlay.Visibility = Visibility.Collapsed;
            var dialog = new ContentDialog
            {
                Title = "Error",
                Content = $"Error: {ex.Message}",
                CloseButtonText = "OK",
                XamlRoot = this.XamlRoot
            };
            await dialog.ShowAsync();
        }
        finally
        {
            service.PropertyChanged -= handler;
            ModelList.IsEnabled = true;
        }
    }
}
