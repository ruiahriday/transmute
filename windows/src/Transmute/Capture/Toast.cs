using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Transmute.Desktop;

namespace Transmute.App;

/// A short message card in the corner ("Copied 42 words"), with an optional button.
sealed class Toast : Window
{
    static Toast? current;
    readonly DispatcherTimer timer = new();

    Toast(string title, string? detail, string glyph, Brush tint, (string Label, Action Run)? action)
    {
        CaptureKit.Floating(this);
        ShowActivated = false;
        var icon = Icons.Make(glyph, 22, tint, 2);
        icon.VerticalAlignment = VerticalAlignment.Top;
        icon.Margin = new Thickness(0, 1, 12, 0);
        var text = new StackPanel { Width = 300 };
        text.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, Foreground = CaptureKit.Brush("Ink"), TextWrapping = TextWrapping.Wrap });
        if (!string.IsNullOrWhiteSpace(detail))
            text.Children.Add(new TextBlock { Text = detail, Foreground = CaptureKit.Brush("Secondary"), FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 3, 0, 0), MaxHeight = 120, TextTrimming = TextTrimming.CharacterEllipsis });
        if (action is { } a)
        {
            var button = new Button { Content = a.Label, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 0), Padding = new Thickness(10, 3, 10, 3) };
            button.Click += (_, _) => { a.Run(); Close(); };
            text.Children.Add(button);
        }
        var row = new DockPanel();
        DockPanel.SetDock(icon, Dock.Left);
        row.Children.Add(icon);
        var close = CaptureKit.IconButton("close", "Close", Close, 11, CaptureKit.Brush("Tertiary"));
        close.VerticalAlignment = VerticalAlignment.Top;
        close.Margin = new Thickness(6, -4, -6, 0);
        DockPanel.SetDock(close, Dock.Right);
        row.Children.Add(close);
        row.Children.Add(text);
        Content = CaptureKit.Card(row, new Thickness(14, 12, 14, 12));
        MouseEnter += (_, _) => timer.Stop();
        MouseLeave += (_, _) => timer.Start();
        timer.Tick += (_, _) => Close();
        Closed += (_, _) => { timer.Stop(); if (current == this) current = null; };
    }

    public static Toast Show(string title, string? detail = null, bool ok = true, (string Label, Action Run)? action = null, double seconds = 4.5, string? glyph = null)
    {
        current?.Close();
        var toast = new Toast(title, detail, glyph ?? (ok ? "check" : "warning"), CaptureKit.Brush(ok ? "Success" : "Warning"), action);
        current = toast;
        CaptureKit.MakeToolWindow(toast);
        toast.Show();
        CaptureKit.PlaceAtCorner(toast, Screens.MonitorUnderCursor(), right: true, margin: 6);
        toast.timer.Interval = TimeSpan.FromSeconds(seconds);
        toast.timer.Start();
        return toast;
    }
}
