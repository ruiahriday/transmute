using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Transmute.Desktop;

namespace Transmute.App;

/// A big 3-2-1 in the middle of a display before a timed capture or a recording. Esc cancels.
sealed class Countdown : Window
{
    readonly TextBlock number = new() { FontSize = 64, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    readonly TaskCompletionSource<bool> done = new();
    int left;

    Countdown(int seconds, string caption)
    {
        CaptureKit.Floating(this);
        ShowActivated = true;
        left = seconds;
        number.Text = left.ToString();
        var stack = new StackPanel();
        stack.Children.Add(new Grid
        {
            Width = 132, Height = 132,
            Children =
            {
                new System.Windows.Shapes.Ellipse { Fill = new SolidColorBrush(Color.FromArgb(0xE0, 0x20, 0x20, 0x20)) },
                new System.Windows.Shapes.Ellipse { Stroke = ThemeManager.OverlayAccent, StrokeThickness = 4, Margin = new Thickness(3) },
                number,
            },
        });
        stack.Children.Add(new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0xE0, 0x20, 0x20, 0x20)), CornerRadius = new CornerRadius(6), Padding = new Thickness(10, 4, 10, 5),
            Margin = new Thickness(0, 10, 0, 0), HorizontalAlignment = HorizontalAlignment.Center,
            Child = new TextBlock { Text = caption, Foreground = Brushes.White, FontSize = 12 },
        });
        Content = stack;
        CaptureKit.KeepOutOfCaptures(this);
        KeyDown += (_, e) => { if (e.Key == Key.Escape) { done.TrySetResult(false); Close(); } };
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        timer.Tick += (_, _) =>
        {
            left--;
            if (left <= 0) { timer.Stop(); done.TrySetResult(true); Close(); return; }
            number.Text = left.ToString();
            Theme.To(number, OpacityProperty, 1, 0.3, from: 0.2);
        };
        Loaded += (_, _) => timer.Start();
        Closed += (_, _) => { timer.Stop(); done.TrySetResult(false); };
    }

    public static async Task<bool> Run(int seconds, MonitorInfo monitor, string caption = "Esc to cancel")
    {
        if (seconds <= 0) return true;
        var window = new Countdown(seconds, caption);
        window.Show();
        CaptureKit.Place(window, monitor, (w, h) => (monitor.Bounds.X + (monitor.Bounds.Width - w) / 2, monitor.Bounds.Y + (monitor.Bounds.Height - h) / 2));
        window.Activate();
        var go = await window.done.Task;
        if (go) await Task.Delay(150); // let it fade off the screen
        return go;
    }
}
