using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace OfflineSpeechTranslation.Controls;

/// <summary>
/// Audio energy visualizer with vertical bars.
/// Port of iOS AudioVisualizerView.swift.
/// </summary>
public sealed partial class AudioVisualizerControl : UserControl
{
    private const int BarCount = 50;
    private const double BarSpacing = 2;
    private readonly Rectangle[] _bars = new Rectangle[BarCount];
    private DispatcherTimer? _timer;

    private readonly SolidColorBrush _highBrush = new(Colors.DodgerBlue);
    private readonly SolidColorBrush _midBrush = new(Colors.CornflowerBlue);
    private readonly SolidColorBrush _lowBrush = new(Colors.LightSteelBlue);

    public AudioVisualizerControl()
    {
        this.InitializeComponent();
        InitializeBars();
        StartTimer();
        Unloaded += (_, _) => StopTimer();
    }

    private void InitializeBars()
    {
        for (int i = 0; i < BarCount; i++)
        {
            _bars[i] = new Rectangle
            {
                Fill = _highBrush,
                RadiusX = 1,
                RadiusY = 1,
                Height = 2 // minimum height
            };
            VisualizerCanvas.Children.Add(_bars[i]);
        }
    }

    private void StartTimer()
    {
        if (_timer != null) return;
        _timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(100) };
        _timer.Tick += Timer_Tick;
        _timer.Start();
    }

    private void StopTimer()
    {
        if (_timer == null) return;
        _timer.Stop();
        _timer.Tick -= Timer_Tick;
        _timer = null;
    }

    private void Timer_Tick(object? sender, object e)
    {
        var service = App.SpeechTranslationService;
        if (service == null) return;

        // Only poll audio energy when actually recording to save CPU
        if (!service.Recorder.IsRecording)
            return;

        var energy = service.Recorder.GetRelativeEnergy();
        UpdateBars(energy);
    }

    private void UpdateBars(float[] energy)
    {
        double canvasWidth = VisualizerCanvas.ActualWidth;
        double canvasHeight = VisualizerCanvas.ActualHeight;
        if (canvasWidth <= 0 || canvasHeight <= 0) return;

        double barWidth = (canvasWidth - (BarCount - 1) * BarSpacing) / BarCount;
        if (barWidth < 1) barWidth = 1;

        int energyLen = energy.Length;

        for (int i = 0; i < BarCount; i++)
        {
            // Map bar index to energy array (show most recent values)
            float value = 0;
            if (energyLen > 0)
            {
                int idx = energyLen - BarCount + i;
                if (idx >= 0 && idx < energyLen)
                    value = energy[idx];
            }

            double barHeight = Math.Max(2, value * canvasHeight);

            _bars[i].Width = barWidth;
            _bars[i].Height = barHeight;
            Canvas.SetLeft(_bars[i], i * (barWidth + BarSpacing));
            Canvas.SetTop(_bars[i], canvasHeight - barHeight);

            // Color based on energy level
            _bars[i].Fill = value > 0.3f ? _highBrush
                : value > 0.1f ? _midBrush
                : _lowBrush;
        }
    }

    private void Canvas_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        // Redraw on resize
        var service = App.SpeechTranslationService;
        if (service == null) return;
        var energy = service.Recorder.GetRelativeEnergy();
        UpdateBars(energy);
    }
}
