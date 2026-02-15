using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using System.IO;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using OfflineSpeechTranslation.Models;
using OfflineSpeechTranslation.Services;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage.Pickers;

namespace OfflineSpeechTranslation.ViewModels;

/// <summary>
/// ViewModel for the transcription page. Wraps TranscriptionService
/// and exposes commands for the UI.
/// </summary>
public sealed partial class TranscriptionViewModel : ObservableObject
{
    private readonly TranscriptionService _service;
    private readonly AppPreferences _prefs;

    [ObservableProperty] private bool _isRecording;
    [ObservableProperty] private string _currentModelName = "No model loaded";
    [ObservableProperty] private string _inferenceLabel = "";

    public TranscriptionService Service => _service;

    public TranscriptionViewModel(TranscriptionService service, AppPreferences prefs)
    {
        _service = service;
        _prefs = prefs;

        // Keep UI state in sync with service state.
        IsRecording = _service.SessionState == SessionState.Recording;
        _service.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(TranscriptionService.SessionState))
                IsRecording = _service.SessionState == SessionState.Recording;
        };
    }

    [RelayCommand]
    private void ToggleRecording()
    {
        if (_service.SessionState == SessionState.Recording)
        {
            App.Evidence.LogEvent("ui_record_toggle", new { action = "stop" });
            _service.StopRecording();
        }
        else if (_service.ModelState == ASRModelState.Loaded)
        {
            App.Evidence.LogEvent("ui_record_toggle", new { action = "start", source = _prefs.CaptureSource.ToString() });
            _service.StartRecording(_prefs.CaptureSource);
        }
    }

    [RelayCommand]
    private async Task TranscribeFileAsync()
    {
        if (_service.ModelState != ASRModelState.Loaded) return;

        try
        {
            var picker = new FileOpenPicker();
            picker.FileTypeFilter.Add(".wav");
            picker.FileTypeFilter.Add(".mp3");
            picker.SuggestedStartLocation = PickerLocationId.MusicLibrary;

            // WinUI 3 picker needs window handle
            if (App.MainWindow == null)
                throw new InvalidOperationException("Main window is not available.");

            var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow);
            WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);

            var file = await picker.PickSingleFileAsync();
            if (file == null) return;

            try
            {
                var info = new FileInfo(file.Path);
                App.Evidence.LogEvent("file_transcribe_selected", new
                {
                    name = Path.GetFileName(file.Path),
                    sizeBytes = info.Exists ? info.Length : (long?)null
                });
                _ = App.Evidence.CaptureScreenshotAsync("file_transcribe_selected");
            }
            catch
            {
                App.Evidence.LogEvent("file_transcribe_selected", new { name = Path.GetFileName(file.Path) });
            }

            // Decode audio file to 16kHz mono float samples.
            var samples = await ReadAudioFileAsync(file.Path);
            if (samples == null || samples.Length == 0)
            {
                App.Evidence.LogEvent("file_transcribe_decode_failed", new
                {
                    name = Path.GetFileName(file.Path)
                });
                return;
            }

            var result = await _service.TranscribeFileAsync(samples);

            // Log evidence with or without full transcript text based on preference.
            if (_prefs.EvidenceIncludeTranscriptText)
            {
                App.Evidence.LogEvent("file_transcribe_done", new
                {
                    text = result.Text,
                    detectedLanguage = result.DetectedLanguage,
                    inferenceTimeMs = result.InferenceTimeMs
                });
            }
            else
            {
                App.Evidence.LogEvent("file_transcribe_done", new
                {
                    textLength = result.Text?.Length ?? 0,
                    detectedLanguage = result.DetectedLanguage,
                    inferenceTimeMs = result.InferenceTimeMs
                });
            }
            _ = App.Evidence.CaptureScreenshotAsync("file_transcribe_done");
        }
        catch (Exception ex)
        {
            App.Evidence.LogEvent("file_transcribe_exception", new { error = ex.ToString() }, level: "error");
        }
    }

    /// <summary>
    /// Transcribe the embedded test audio file (test-english-30s.wav) placed alongside the exe.
    /// Used for automated E2E testing without microphone input.
    /// </summary>
    [RelayCommand]
    public async Task TranscribeTestAudioAsync()
    {
        if (_service.ModelState != ASRModelState.Loaded) return;

        try
        {
            var basePath = AppContext.BaseDirectory;
            var testAudioPath = Path.Combine(basePath, "test-english-30s.wav");
            if (!File.Exists(testAudioPath))
            {
                App.Evidence.LogEvent("test_audio_not_found", new { path = testAudioPath }, level: "error");
                return;
            }

            App.Evidence.LogEvent("test_audio_transcribe_start", new { path = testAudioPath });

            var samples = await ReadAudioFileAsync(testAudioPath);
            if (samples == null || samples.Length == 0)
            {
                App.Evidence.LogEvent("test_audio_decode_failed", new { path = testAudioPath }, level: "error");
                return;
            }

            var result = await _service.TranscribeFileAsync(samples);

            App.Evidence.LogEvent("test_audio_transcribe_done", new
            {
                text = result.Text,
                detectedLanguage = result.DetectedLanguage,
                inferenceTimeMs = result.InferenceTimeMs
            });
            _ = App.Evidence.CaptureScreenshotAsync("test_audio_transcribe_done");
        }
        catch (Exception ex)
        {
            App.Evidence.LogEvent("test_audio_exception", new { error = ex.ToString() }, level: "error");
        }
    }

    [RelayCommand]
    private void CopyText()
    {
        var text = $"{_service.ConfirmedText} {_service.HypothesisText}".Trim();
        if (string.IsNullOrEmpty(text)) return;

        var dp = new DataPackage();
        dp.SetText(text);
        Clipboard.SetContent(dp);
    }

    [RelayCommand]
    private void ClearTranscription()
    {
        _service.ClearTranscription();
    }

    public async Task LoadSavedModelAsync()
    {
        var modelId = _prefs.SelectedModelId;
        if (modelId == null) return;

        var model = ModelInfo.AvailableModels.FirstOrDefault(m => m.Id == modelId);
        if (model != null && ModelDownloader.IsModelDownloaded(model))
        {
            await _service.SelectAndLoadModelAsync(model);
            CurrentModelName = model.DisplayName;
            InferenceLabel = model.InferenceMethod;
        }
    }

    /// <summary>Read an audio file (wav/mp3/...) into float[] samples at 16kHz mono.</summary>
    private static async Task<float[]?> ReadAudioFileAsync(string path)
    {
        return await Task.Run(() =>
        {
            try
            {
                using var reader = new AudioFileReader(path);
                ISampleProvider provider = reader;

                // Convert to mono if needed
                if (provider.WaveFormat.Channels > 1)
                {
                    provider = provider.WaveFormat.Channels == 2
                        ? new StereoToMonoSampleProvider(provider)
                        {
                            LeftVolume = 0.5f,
                            RightVolume = 0.5f
                        }
                        : new MultiChannelToMonoSampleProvider(provider);
                }

                // Resample if needed
                if (provider.WaveFormat.SampleRate != 16000)
                    provider = new WdlResamplingSampleProvider(provider, 16000);

                var samples = new List<float>();
                var buffer = new float[4096];
                int read;
                while ((read = provider.Read(buffer, 0, buffer.Length)) > 0)
                {
                    for (int i = 0; i < read; i++)
                        samples.Add(buffer[i]);
                }
                return samples.ToArray();
            }
            catch
            {
                return null;
            }
        });
    }

    /// <summary>
    /// Down-mix N-channel sample provider to mono by averaging channels.
    /// Used for multi-channel files where StereoToMono doesn't apply.
    /// </summary>
    private sealed class MultiChannelToMonoSampleProvider : ISampleProvider
    {
        private readonly ISampleProvider _source;
        private readonly int _channels;
        private float[] _sourceBuffer = [];

        public WaveFormat WaveFormat { get; }

        public MultiChannelToMonoSampleProvider(ISampleProvider source)
        {
            _source = source;
            _channels = source.WaveFormat.Channels;
            if (_channels < 2) throw new ArgumentOutOfRangeException(nameof(source));

            WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(source.WaveFormat.SampleRate, 1);
        }

        public int Read(float[] buffer, int offset, int count)
        {
            if (count <= 0) return 0;

            int neededSourceSamples = count * _channels;
            if (_sourceBuffer.Length < neededSourceSamples)
                _sourceBuffer = new float[neededSourceSamples];

            int sourceRead = _source.Read(_sourceBuffer, 0, neededSourceSamples);
            int framesRead = sourceRead / _channels;

            for (int frame = 0; frame < framesRead; frame++)
            {
                float sum = 0;
                int baseIndex = frame * _channels;
                for (int ch = 0; ch < _channels; ch++)
                    sum += _sourceBuffer[baseIndex + ch];
                buffer[offset + frame] = sum / _channels;
            }

            return framesRead;
        }
    }
}
