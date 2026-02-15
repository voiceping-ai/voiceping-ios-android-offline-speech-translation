using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using NAudio.Wave;

namespace OfflineSpeechTranslation.Controls;

/// <summary>
/// Waveform display with audio playback and scrubbing.
/// Port of iOS WaveformPlaybackView.swift.
/// </summary>
public sealed partial class WaveformPlaybackControl : UserControl
{
    private const int BarCount = 200;
    private readonly Rectangle[] _bars = new Rectangle[BarCount];
    private float[] _waveformData = [];
    private WaveOutEvent? _player;
    private AudioFileReader? _audioReader;
    private readonly DispatcherTimer _positionTimer;
    private string? _audioPath;
    private double _totalDuration;

    public WaveformPlaybackControl()
    {
        this.InitializeComponent();
        InitializeBars();
        _positionTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(50) };
        _positionTimer.Tick += PositionTimer_Tick;
        Unloaded += (_, _) => CleanupPlayback();
    }

    private void InitializeBars()
    {
        for (int i = 0; i < BarCount; i++)
        {
            _bars[i] = new Rectangle
            {
                Fill = new SolidColorBrush(Colors.DodgerBlue),
                Width = 2,
                Height = 2
            };
            WaveformCanvas.Children.Add(_bars[i]);
        }
    }

    public void LoadAudio(string path)
    {
        CleanupPlayback();
        _audioPath = path;
        _waveformData = GenerateWaveform(path, BarCount);
        UpdateWaveformDisplay();

        try
        {
            _audioReader = new AudioFileReader(path);
            _totalDuration = _audioReader.TotalTime.TotalSeconds;
            UpdatePositionText(0);
        }
        catch { }
    }

    private void UpdateWaveformDisplay()
    {
        double canvasWidth = WaveformCanvas.ActualWidth;
        double canvasHeight = WaveformCanvas.ActualHeight;
        if (canvasWidth <= 0 || canvasHeight <= 0) return;

        double barWidth = canvasWidth / BarCount - 1;
        if (barWidth < 1) barWidth = 1;

        for (int i = 0; i < BarCount; i++)
        {
            float value = i < _waveformData.Length ? _waveformData[i] : 0;
            double barHeight = Math.Max(2, value * canvasHeight);

            _bars[i].Width = barWidth;
            _bars[i].Height = barHeight;
            Canvas.SetLeft(_bars[i], i * (barWidth + 1));
            Canvas.SetTop(_bars[i], (canvasHeight - barHeight) / 2);
        }
    }

    private void PlayPause_Click(object sender, RoutedEventArgs e)
    {
        if (_player?.PlaybackState == PlaybackState.Playing)
        {
            _player.Pause();
            PlayPauseIcon.Symbol = Symbol.Play;
            _positionTimer.Stop();
        }
        else
        {
            if (_audioPath == null) return;

            if (_player == null || _player.PlaybackState == PlaybackState.Stopped)
            {
                _audioReader?.Dispose();
                _player?.Dispose(); // Dispose old player to avoid audio device handle leak
                _audioReader = new AudioFileReader(_audioPath);
                _player = new WaveOutEvent();
                _player.Init(_audioReader);
                _player.PlaybackStopped += (s, args) =>
                {
                    DispatcherQueue.TryEnqueue(() =>
                    {
                        PlayPauseIcon.Symbol = Symbol.Play;
                        _positionTimer.Stop();
                    });
                };
            }

            _player.Play();
            PlayPauseIcon.Symbol = Symbol.Pause;
            StartPositionTimer();
        }
    }

    private void StartPositionTimer()
    {
        _positionTimer.Start();
    }

    private void PositionTimer_Tick(object? sender, object e)
    {
        if (_audioReader != null)
            UpdatePositionText(_audioReader.CurrentTime.TotalSeconds);
    }

    private void UpdatePositionText(double currentSeconds)
    {
        var current = TimeSpan.FromSeconds(currentSeconds);
        var total = TimeSpan.FromSeconds(_totalDuration);
        PositionText.Text = $"{current:m\\:ss} / {total:m\\:ss}";
    }

    private void Canvas_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (_audioReader == null || _totalDuration <= 0) return;

        var pos = e.GetCurrentPoint(WaveformCanvas).Position;
        double fraction = pos.X / WaveformCanvas.ActualWidth;
        fraction = Math.Clamp(fraction, 0, 1);

        _audioReader.CurrentTime = TimeSpan.FromSeconds(fraction * _totalDuration);
        UpdatePositionText(_audioReader.CurrentTime.TotalSeconds);
    }

    private void Canvas_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        UpdateWaveformDisplay();
    }

    private void CleanupPlayback()
    {
        try { _positionTimer.Stop(); } catch { }

        try
        {
            if (_player != null && _player.PlaybackState != PlaybackState.Stopped)
                _player.Stop();
        }
        catch { }

        try { _player?.Dispose(); } catch { }
        _player = null;

        try { _audioReader?.Dispose(); } catch { }
        _audioReader = null;

        _totalDuration = 0;
        PlayPauseIcon.Symbol = Symbol.Play;
        UpdatePositionText(0);
    }

    /// <summary>Generate normalized RMS waveform data from a WAV file.</summary>
    private static float[] GenerateWaveform(string path, int barCount)
    {
        try
        {
            using var reader = new AudioFileReader(path);
            // Use TotalTime to correctly compute samples (AudioFileReader decodes to IEEE float)
            int totalSamples = (int)(reader.TotalTime.TotalSeconds * reader.WaveFormat.SampleRate * reader.WaveFormat.Channels);
            int samplesPerBar = Math.Max(1, totalSamples / barCount);
            var bars = new float[barCount];

            var buffer = new float[samplesPerBar];
            float maxRms = float.MinValue;

            for (int i = 0; i < barCount; i++)
            {
                int read = reader.Read(buffer, 0, buffer.Length);
                if (read == 0) break;

                float sumSq = 0;
                for (int j = 0; j < read; j++) sumSq += buffer[j] * buffer[j];
                float rms = MathF.Sqrt(sumSq / read);
                bars[i] = rms;
                if (rms > maxRms) maxRms = rms;
            }

            // Normalize
            if (maxRms > 0)
            {
                for (int i = 0; i < bars.Length; i++)
                    bars[i] /= maxRms;
            }

            return bars;
        }
        catch
        {
            return new float[barCount];
        }
    }
}
