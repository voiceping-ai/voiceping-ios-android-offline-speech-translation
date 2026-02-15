using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OfflineSpeechTranslation.Views;

namespace OfflineSpeechTranslation;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        this.InitializeComponent();
        SetWindowIcon();
        ContentFrame.Navigated += ContentFrame_Navigated;

        // Navigate to model setup or transcription on launch
        if (App.Preferences.SelectedModelId != null
            && Services.ModelDownloader.IsModelDownloaded(
                Models.ModelInfo.AvailableModels.FirstOrDefault(
                    m => m.Id == App.Preferences.SelectedModelId)
                ?? Models.ModelInfo.DefaultModel))
        {
            ContentFrame.Navigate(typeof(TranscriptionPage));
        }
        else
        {
            ContentFrame.Navigate(typeof(ModelSetupPage));
        }
    }

    private void NavView_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is NavigationViewItem item)
        {
            var tag = item.Tag?.ToString();
            switch (tag)
            {
                case "Transcription":
                    ContentFrame.Navigate(typeof(TranscriptionPage));
                    break;
                case "History":
                    ContentFrame.Navigate(typeof(HistoryPage));
                    break;
                case "Settings":
                    ContentFrame.Navigate(typeof(SettingsPage));
                    break;
            }
        }
    }

    private void SetWindowIcon()
    {
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var windowId = Microsoft.UI.Win32Interop.GetWindowIdFromWindow(hwnd);
        var appWindow = Microsoft.UI.Windowing.AppWindow.GetFromWindowId(windowId);
        var iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico");
        if (appWindow is not null && File.Exists(iconPath))
        {
            appWindow.SetIcon(iconPath);
        }
    }

    private void ContentFrame_Navigated(object sender, NavigationEventArgs e)
    {
        var page = e.SourcePageType?.Name ?? "Unknown";
        App.Evidence.LogEvent("navigate", new { page });
        _ = App.Evidence.CaptureScreenshotAsync($"nav_{page}");
    }
}
