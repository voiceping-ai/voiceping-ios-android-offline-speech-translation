using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace OfflineSpeechTranslation.Controls;

public sealed partial class RecordButton : UserControl
{
    public static readonly DependencyProperty IsRecordingProperty =
        DependencyProperty.Register(nameof(IsRecording), typeof(bool),
            typeof(RecordButton), new PropertyMetadata(false, OnIsRecordingChanged));

    public bool IsRecording
    {
        get => (bool)GetValue(IsRecordingProperty);
        set => SetValue(IsRecordingProperty, value);
    }

    public event RoutedEventHandler? Click;

    public RecordButton()
    {
        this.InitializeComponent();
    }

    private void MainButton_Click(object sender, RoutedEventArgs e)
    {
        Click?.Invoke(this, e);
    }

    private static void OnIsRecordingChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var control = (RecordButton)d;
        bool recording = (bool)e.NewValue;
        control.RecordCircle.Visibility = recording ? Visibility.Collapsed : Visibility.Visible;
        control.StopSquare.Visibility = recording ? Visibility.Visible : Visibility.Collapsed;
    }
}
