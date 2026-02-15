using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using OfflineSpeechTranslation.Models;
using OfflineSpeechTranslation.Utilities;

namespace OfflineSpeechTranslation.Services;

/// <summary>
/// High-level coordinator for evidence capture (logs, model manifests, screenshots, ZIP export).
/// Evidence is collected on real Windows devices so we can debug issues we can't reproduce locally.
/// </summary>
public sealed class EvidenceService
{
    private readonly AppPreferences _prefs;
    private EvidenceSession? _session;
    private bool _serviceAttached;
    private readonly object _lock = new();

    public EvidenceService(AppPreferences prefs)
    {
        _prefs = prefs;
    }

    public bool IsEnabled => _prefs.EvidenceMode;

    public string? ActiveSessionId => _session?.SessionId ?? _prefs.EvidenceSessionFolder;

    public string? ActiveSessionDir =>
        _session?.SessionDir
        ?? (_prefs.EvidenceSessionFolder != null
            ? Path.Combine(EvidenceSession.EvidenceBaseDir, _prefs.EvidenceSessionFolder)
            : null);

    public void TryAutoStart()
    {
        if (!IsEnabled) return;

        // Prefer continuing an existing session across restarts.
        // Users can always start a new session from Settings when needed.
        var session = EnsureSession("auto_launch");
        session.AppendEvent("app_launch", GetRuntimeInfo());
        CaptureBaseline();
    }

    public EvidenceSession StartNewSession(string? label = null)
    {
        lock (_lock)
        {
            _session = EvidenceSession.CreateNew(label);
            _prefs.EvidenceSessionFolder = _session.SessionId;
        }

        _session.AppendEvent("evidence_session_started", new { label });
        CaptureBaseline();
        return _session;
    }

    public EvidenceSession EnsureSession(string? labelIfNew = null)
    {
        lock (_lock)
        {
            if (_session != null) return _session;

            if (_prefs.EvidenceSessionFolder != null
                && EvidenceSession.TryOpenExisting(_prefs.EvidenceSessionFolder, out var existing)
                && existing != null)
            {
                _session = existing;
                return _session;
            }

            _session = EvidenceSession.CreateNew(labelIfNew);
            _prefs.EvidenceSessionFolder = _session.SessionId;
            return _session;
        }
    }

    public void AttachTranscriptionService(SpeechTranslationService service)
    {
        if (_serviceAttached) return;
        _serviceAttached = true;

        service.PropertyChanged += (_, e) =>
        {
            if (!IsEnabled) return;

            try
            {
                switch (e.PropertyName)
                {
                    case nameof(SpeechTranslationService.ModelState):
                        LogEvent("model_state", new
                        {
                            state = service.ModelState.ToString(),
                            modelId = service.CurrentModel?.Id
                        });

                        if (service.CurrentModel != null && service.ModelState is ASRModelState.Loaded or ASRModelState.Error)
                            CaptureModelEvidence(service.CurrentModel);

                        // Screenshot each model lifecycle step (Downloading/Loading/Loaded/Error).
                        _ = CaptureScreenshotAsync($"model_{service.ModelState}");
                        break;

                    case nameof(SpeechTranslationService.SessionState):
                        LogEvent("session_state", new { state = service.SessionState.ToString() });
                        // Screenshot each recording lifecycle step.
                        _ = CaptureScreenshotAsync($"session_{service.SessionState}");
                        break;
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[Evidence] Failed to handle service state change: {ex.Message}");
            }
        };
    }

    public void LogEvent(string name, object? data = null, string level = "info")
    {
        if (!IsEnabled) return;
        try
        {
            EnsureSession().AppendEvent(name, data, level);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[Evidence] LogEvent failed: {ex.Message}");
        }
    }

    public void CaptureBaseline()
    {
        if (!IsEnabled) return;

        try
        {
            var s = EnsureSession("baseline");

            s.WriteJson("manifest.json", new
            {
                evidenceVersion = 1,
                sessionId = s.SessionId,
                createdAtUtc = s.CreatedAtUtc.ToString("O"),
                runtime = GetRuntimeInfo()
            });

            s.WriteJson("device.json", GetRuntimeInfo());

            // Copy settings.json (best-effort)
            s.CopyFileIntoSession(AppPreferences.SettingsFilePath, "settings.json");

            // Models evidence (installed / downloaded)
            var models = ModelEvidence.CaptureAll(ModelInfo.AvailableModels);
            s.WriteJson("models/installed_models.json", models);

            // Native DLL inventory (best-effort)
            s.WriteJson("native/dll_inventory.json", new
            {
                baseDirectory = AppContext.BaseDirectory,
                root = GetDirectoryInventory(AppContext.BaseDirectory, "*.dll"),
                runtimesWinX64 = GetDirectoryInventory(
                    Path.Combine(AppContext.BaseDirectory, "runtimes", "win-x64"),
                    "*.dll")
            });

            // Audio devices (best-effort; very useful for loopback/multi-channel debugging)
            s.WriteJson("audio/devices.json", GetAudioDevicesEvidence());

            s.AppendEvent("baseline_captured", new { modelsCount = models.Models.Count });
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[Evidence] CaptureBaseline failed: {ex.Message}");
        }
    }

    public void CaptureModelEvidence(ModelInfo model, string? provider = null)
    {
        if (!IsEnabled) return;

        try
        {
            var s = EnsureSession("model");
            var snapshot = ModelEvidence.Capture(model);

            s.WriteJson($"models/model_{model.Id}.json", new
            {
                provider,
                snapshot
            });

            s.AppendEvent("model_evidence", new { modelId = model.Id, provider });
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[Evidence] CaptureModelEvidence failed: {ex.Message}");
        }
    }

    public async Task<string?> CaptureScreenshotAsync(string label)
    {
        if (!IsEnabled) return null;

        var window = OfflineSpeechTranslation.App.MainWindow;
        if (window == null) return null;

        try
        {
            if (window.DispatcherQueue.HasThreadAccess)
                return await CaptureScreenshotOnUIThreadAsync(label);

            var tcs = new TaskCompletionSource<string?>();
            // Use synchronous TryEnqueue to avoid async void lambda (which would crash on unhandled exceptions).
            if (!window.DispatcherQueue.TryEnqueue(() =>
            {
                _ = SafeCaptureScreenshotAsync(tcs, label);
            }))
            {
                tcs.TrySetResult(null);
            }
            return await tcs.Task;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[Evidence] CaptureScreenshotAsync failed: {ex.Message}");
            return null;
        }
    }

    /// <summary>Wrapper to bridge async screenshot capture into a TCS without async void.</summary>
    private async Task SafeCaptureScreenshotAsync(TaskCompletionSource<string?> tcs, string label)
    {
        try
        {
            var path = await CaptureScreenshotOnUIThreadAsync(label);
            tcs.TrySetResult(path);
        }
        catch (Exception ex)
        {
            tcs.TrySetException(ex);
        }
    }

    private async Task<string?> CaptureScreenshotOnUIThreadAsync(string label)
    {
        var s = EnsureSession("screenshot");
        var dir = Path.Combine(s.SessionDir, "screenshots");
        var fileName = EvidenceSession.MakeFileName("png", label);

        // Give WinUI a moment to apply visual updates before rendering.
        await Task.Delay(120);

        var path = await ScreenCapture.SaveMainWindowScreenshotAsync(dir, fileName);
        if (path != null)
        {
            s.AppendEvent("screenshot", new
            {
                label,
                file = Path.GetFileName(path)
            });
        }
        return path;
    }

    public string? ExportZip(string outputDir)
    {
        if (!IsEnabled) return null;

        try
        {
            CaptureBaseline(); // refresh before exporting
            var s = EnsureSession("export");
            s.AppendEvent("export_zip", new { outputDir });
            return s.ExportZip(outputDir);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[Evidence] ExportZip failed: {ex.Message}");
            return null;
        }
    }

    private static object GetRuntimeInfo()
    {
        var asm = typeof(OfflineSpeechTranslation.App).Assembly;
        var name = asm.GetName();

        return new
        {
            app = new
            {
                assembly = name.Name,
                version = name.Version?.ToString() ?? ""
            },
            os = new
            {
                description = RuntimeInformation.OSDescription,
                architecture = RuntimeInformation.OSArchitecture.ToString(),
                processArchitecture = RuntimeInformation.ProcessArchitecture.ToString(),
                versionString = Environment.OSVersion.VersionString
            },
            dotnet = new
            {
                framework = RuntimeInformation.FrameworkDescription
            },
            locale = new
            {
                currentCulture = System.Globalization.CultureInfo.CurrentCulture.Name,
                uiCulture = System.Globalization.CultureInfo.CurrentUICulture.Name,
                timeZone = TimeZoneInfo.Local.Id
            }
        };
    }

    private static object GetDirectoryInventory(string dir, string pattern)
    {
        try
        {
            if (!Directory.Exists(dir))
                return new { dir, exists = false, files = Array.Empty<object>() };

            var files = Directory
                .GetFiles(dir, pattern, SearchOption.TopDirectoryOnly)
                .Select(p =>
                {
                    var info = new FileInfo(p);
                    return new
                    {
                        name = Path.GetFileName(p),
                        sizeBytes = info.Length,
                        lastWriteTimeUtc = info.LastWriteTimeUtc.ToString("O")
                    };
                })
                .OrderBy(x => x.name, StringComparer.OrdinalIgnoreCase)
                .ToArray();

            return new { dir, exists = true, files };
        }
        catch (Exception ex)
        {
            return new { dir, exists = false, error = ex.Message, files = Array.Empty<object>() };
        }
    }

    private static object GetAudioDevicesEvidence()
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();

            object DeviceInfo(MMDevice d)
            {
                string? mix = null;
                try { mix = d.AudioClient?.MixFormat?.ToString(); } catch { /* best-effort */ }

                return new
                {
                    id = d.ID,
                    name = d.FriendlyName,
                    state = d.State.ToString(),
                    dataFlow = d.DataFlow.ToString(),
                    mixFormat = mix
                };
            }

            string? defaultRenderId = null;
            string? defaultCaptureId = null;
            try { defaultRenderId = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia)?.ID; } catch { }
            try { defaultCaptureId = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Multimedia)?.ID; } catch { }

            var render = enumerator
                .EnumerateAudioEndPoints(DataFlow.Render, DeviceState.All)
                .Select(DeviceInfo)
                .ToArray();

            var capture = enumerator
                .EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.All)
                .Select(DeviceInfo)
                .ToArray();

            return new
            {
                defaultRenderId,
                defaultCaptureId,
                renderDevices = render,
                captureDevices = capture
            };
        }
        catch (Exception ex)
        {
            return new { error = ex.ToString() };
        }
    }
}
