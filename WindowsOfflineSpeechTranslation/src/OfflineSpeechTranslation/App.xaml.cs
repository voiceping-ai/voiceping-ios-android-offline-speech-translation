using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using OfflineSpeechTranslation.Data;
using OfflineSpeechTranslation.Interop;
using OfflineSpeechTranslation.Services;
using OfflineSpeechTranslation.ViewModels;

namespace OfflineSpeechTranslation;

public partial class App : Application
{
    public static Window? MainWindow { get; private set; }

    // ── Shared services (poor man's DI) ──
    public static AppPreferences Preferences { get; } = new();
    public static EvidenceService Evidence { get; private set; } = null!;
    public static SpeechTranslationService SpeechTranslationService { get; private set; } = null!;
    public static TranscriptionViewModel TranscriptionVM { get; private set; } = null!;

    public App()
    {
        this.InitializeComponent();
        SetupNativeLibraryResolvers();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Evidence = new EvidenceService(Preferences);
        SpeechTranslationService = new SpeechTranslationService(Preferences);
        TranscriptionVM = new TranscriptionViewModel(SpeechTranslationService, Preferences);
        Evidence.AttachTranscriptionService(SpeechTranslationService);

        try
        {
            AppDbContext.EnsureCreated();
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"[App] Failed to initialize database: {ex.Message}");
        }

        MainWindow = new MainWindow();
        MainWindow.Activate();

        // Start evidence capture if enabled (real-device diagnostics).
        Evidence.TryAutoStart();
        _ = Evidence.CaptureScreenshotAsync("app_launch");
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int AddDllDirectory(string newDirectory);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetDefaultDllDirectories(uint directoryFlags);

    /// <summary>
    /// Configure DLL import resolver for native libraries (whisper.dll, sherpa-onnx).
    /// Native DLLs are placed alongside the exe in the output directory.
    /// </summary>
    private static void SetupNativeLibraryResolvers()
    {
        var basePath = AppContext.BaseDirectory;

        // Pre-load ggml dependency DLLs so the Windows loader can find them
        // when whisper.dll is loaded (whisper.dll imports ggml.dll and ggml-base.dll).
        foreach (var dep in new[] { "ggml-base", "ggml-cpu", "ggml" })
        {
            var depPath = Path.Combine(basePath, $"{dep}.dll");
            if (File.Exists(depPath))
                NativeLibrary.Load(depPath);
        }

        NativeLibrary.SetDllImportResolver(typeof(WhisperNative).Assembly, (name, assembly, searchPath) =>
        {
            // Check runtimes/win-x64/ subfolder
            var runtimePath = Path.Combine(basePath, "runtimes", "win-x64", $"{name}.dll");
            if (File.Exists(runtimePath))
                return NativeLibrary.Load(runtimePath);

            // Check app base directory directly
            var directPath = Path.Combine(basePath, $"{name}.dll");
            if (File.Exists(directPath))
                return NativeLibrary.Load(directPath);

            // Fallback to default resolution
            return IntPtr.Zero;
        });
    }
}
