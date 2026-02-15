using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace OfflineSpeechTranslation.Utilities;

public static class ScreenCapture
{
    /// <summary>
     /// Capture the current main window content and save it as a PNG under:
     /// %LOCALAPPDATA%\OfflineSpeechTranslation\Diagnostics\
     /// </summary>
    public static async Task<string?> SaveMainWindowScreenshotAsync(
        string? outputDirectory = null,
        string? fileName = null)
    {
        var window = OfflineSpeechTranslation.App.MainWindow;
        if (window == null) return null;
        if (window.Content is not UIElement root) return null;

        // RenderTargetBitmap must run on the UI thread.
        var rtb = new RenderTargetBitmap();
        await rtb.RenderAsync(root);

        var pixelBuffer = await rtb.GetPixelsAsync();
        var pixels = pixelBuffer.ToArray();

        var dir = outputDirectory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OfflineSpeechTranslation",
            "Diagnostics");
        Directory.CreateDirectory(dir);

        var finalName = string.IsNullOrWhiteSpace(fileName)
            ? $"screenshot_{DateTime.Now:yyyyMMdd_HHmmss}.png"
            : fileName;

        var filePath = Path.Combine(dir, finalName);

        await using var fs = new FileStream(filePath, FileMode.Create, FileAccess.Write, FileShare.Read);
        using IRandomAccessStream stream = fs.AsRandomAccessStream();

        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(
            BitmapPixelFormat.Bgra8,
            BitmapAlphaMode.Premultiplied,
            (uint)rtb.PixelWidth,
            (uint)rtb.PixelHeight,
            96,
            96,
            pixels);
        await encoder.FlushAsync();

        return filePath;
    }
}
