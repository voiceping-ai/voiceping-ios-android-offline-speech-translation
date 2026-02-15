using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using OfflineSpeechTranslation.Models;

namespace OfflineSpeechTranslation.Services;

/// <summary>
/// WASAPI audio capture → 16kHz mono Float32 with energy metering.
/// Port of iOS AudioRecorder.swift using NAudio.
/// </summary>
public sealed class AudioRecorder : IDisposable
{
    private WasapiCapture? _capture;
    private WaveFormat? _captureFormat;
    private WdlResamplingSampleProvider? _resampler;
    private BufferedWaveProvider? _bufferedWaveProvider;
    private ISampleProvider? _finalPipeline;

    private readonly object _lock = new();
    private readonly List<float> _audioSamples = new(16000 * 60); // pre-alloc ~1 min
    private readonly List<float> _relativeEnergy = new(600);       // ~10 min at ~1/s
    private int _bufferStartSampleIndex;

    /// <summary>Cap audio at ~30 minutes (16kHz × 1800s = 28.8M samples ≈ 115 MB).</summary>
    private const int MaxAudioSamples = 28_800_000;

    /// <summary>Cap energy at ~10 min of visualization data.</summary>
    private const int MaxEnergyFrames = 60_000;

    private const int TargetSampleRate = 16_000;
    private const int EnergyChunkSize = 1600; // 100ms at 16kHz

    public bool IsRecording { get; private set; }

    public CaptureSource CurrentSource { get; private set; } = CaptureSource.Microphone;

    /// <summary>Best-effort diagnostics about the last started capture session.</summary>
    public CaptureDiagnostics? LastCaptureDiagnostics { get; private set; }

    public sealed record CaptureDiagnostics(
        CaptureSource Source,
        int SampleRate,
        int Channels,
        int BitsPerSample,
        string Encoding);

    /// <summary>Thread-safe snapshot of accumulated audio samples.</summary>
    public float[] GetAudioSamples()
    {
        lock (_lock) return [.. _audioSamples];
    }

    /// <summary>
    /// Copy a slice of buffered audio samples without cloning the entire buffer.
    /// </summary>
    public bool TryGetAudioSlice(int startSample, int endSample, out float[] slice)
    {
        if (startSample < 0 || endSample < startSample)
        {
            slice = [];
            return false;
        }

        lock (_lock)
        {
            // start/end are absolute indices since recording start.
            int bufferEndSampleIndex = _bufferStartSampleIndex + _audioSamples.Count;
            if (startSample < _bufferStartSampleIndex || endSample > bufferEndSampleIndex)
            {
                slice = [];
                return false;
            }

            int localStart = startSample - _bufferStartSampleIndex;
            int count = endSample - startSample;
            slice = new float[count];
            _audioSamples.CopyTo(localStart, slice, 0, count);
            return true;
        }
    }

    /// <summary>Thread-safe snapshot of energy values.</summary>
    public float[] GetRelativeEnergy()
    {
        lock (_lock) return [.. _relativeEnergy];
    }

    /// <summary>Current sample count (thread-safe).</summary>
    public int SampleCount
    {
        get { lock (_lock) return _bufferStartSampleIndex + _audioSamples.Count; }
    }

    /// <summary>Buffer duration in seconds.</summary>
    public double BufferSeconds => SampleCount / (double)TargetSampleRate;

    /// <summary>Fires on the capture thread when new audio arrives. Arg = total sample count.</summary>
    public event Action<int>? AudioReceived;

    /// <summary>
    /// Start capturing audio from microphone or system loopback.
    /// </summary>
    public void StartRecording(CaptureSource source = CaptureSource.Microphone)
    {
        if (IsRecording) return;

        lock (_lock)
        {
            _audioSamples.Clear();
            _relativeEnergy.Clear();
            _bufferStartSampleIndex = 0;
        }

        CurrentSource = source;

        _capture = source switch
        {
            CaptureSource.SystemLoopback => new WasapiLoopbackCapture(),
            _ => new WasapiCapture()
        };

        _captureFormat = _capture.WaveFormat;
        LastCaptureDiagnostics = new CaptureDiagnostics(
            Source: source,
            SampleRate: _captureFormat.SampleRate,
            Channels: _captureFormat.Channels,
            BitsPerSample: _captureFormat.BitsPerSample,
            Encoding: _captureFormat.Encoding.ToString());

        // Set up resampling pipeline: capture format → 16kHz mono Float32
        _bufferedWaveProvider = new BufferedWaveProvider(_captureFormat)
        {
            BufferLength = _captureFormat.AverageBytesPerSecond * 2,
            DiscardOnBufferOverflow = true
        };

        ISampleProvider pipeline = _bufferedWaveProvider.ToSampleProvider();

        // Convert to mono if stereo+
        if (_captureFormat.Channels > 1)
        {
            pipeline = _captureFormat.Channels == 2
                ? pipeline.ToMono()
                : new MultiChannelToMonoSampleProvider(pipeline);
        }

        // Resample to 16kHz if needed
        if (_captureFormat.SampleRate != TargetSampleRate)
        {
            _resampler = new WdlResamplingSampleProvider(pipeline, TargetSampleRate);
            pipeline = _resampler;
        }

        _finalPipeline = pipeline;

        _capture.DataAvailable += OnCaptureDataAvailable;
        _capture.RecordingStopped += OnCaptureRecordingStopped;

        _capture.StartRecording();
        IsRecording = true;
    }

    /// <summary>Stop recording and release capture device.</summary>
    public void StopRecording()
    {
        if (!IsRecording) return;

        if (_capture != null)
        {
            _capture.DataAvailable -= OnCaptureDataAvailable;
            _capture.RecordingStopped -= OnCaptureRecordingStopped;

            try { _capture.StopRecording(); } catch { /* best-effort */ }
            try { _capture.Dispose(); } catch { /* best-effort */ }
            _capture = null;
        }

        _bufferedWaveProvider = null;
        _resampler = null;
        _finalPipeline = null;
        _captureFormat = null;
        IsRecording = false;
    }

    /// <summary>Clear all buffered audio and energy data.</summary>
    public void ClearBuffers()
    {
        lock (_lock)
        {
            _audioSamples.Clear();
            _relativeEnergy.Clear();
            _bufferStartSampleIndex = 0;
        }
    }

    public void Dispose()
    {
        StopRecording();
    }

    private void OnCaptureDataAvailable(object? sender, WaveInEventArgs args)
    {
        var buffered = _bufferedWaveProvider;
        var pipeline = _finalPipeline;
        if (buffered == null || pipeline == null) return;

        // Feed raw bytes into the resampling pipeline
        buffered.AddSamples(args.Buffer, 0, args.BytesRecorded);

        // Read resampled 16kHz mono float samples
        var buffer = new float[4096];
        int samplesRead;
        var newSamples = new List<float>();

        while ((samplesRead = pipeline.Read(buffer, 0, buffer.Length)) > 0)
        {
            for (int i = 0; i < samplesRead; i++)
                newSamples.Add(buffer[i]);
        }

        if (newSamples.Count == 0) return;

        // Compute energy: dBFS normalized to 0–1 (−60 dB → 0, 0 dB → 1)
        float sumSquares = 0;
        foreach (var s in newSamples) sumSquares += s * s;
        float rms = MathF.Sqrt(sumSquares / newSamples.Count);
        float dbFS = 20 * MathF.Log10(MathF.Max(rms, 1e-10f));
        float normalizedEnergy = Math.Clamp((dbFS + 60) / 60f, 0f, 1f);

        int totalSamples;
        lock (_lock)
        {
            _audioSamples.AddRange(newSamples);

            // Hard cap to avoid unbounded memory growth. Keep the newest half.
            if (_audioSamples.Count > MaxAudioSamples)
            {
                int removeCount = _audioSamples.Count - MaxAudioSamples / 2;
                _audioSamples.RemoveRange(0, removeCount);
                _bufferStartSampleIndex += removeCount;
            }

            totalSamples = _bufferStartSampleIndex + _audioSamples.Count;

            // Cap energy
            _relativeEnergy.Add(normalizedEnergy);
            if (_relativeEnergy.Count > MaxEnergyFrames)
            {
                int removeCount = _relativeEnergy.Count - MaxEnergyFrames / 2;
                _relativeEnergy.RemoveRange(0, removeCount);
            }
        }

        AudioReceived?.Invoke(totalSamples);
    }

    private void OnCaptureRecordingStopped(object? sender, StoppedEventArgs args)
    {
        IsRecording = false;
    }

    /// <summary>
    /// Down-mix N-channel float audio to mono by averaging channels.
    /// Used for unusual system audio configs (e.g. 5.1/7.1 loopback).
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
