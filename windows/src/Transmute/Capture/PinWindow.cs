using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Transmute.Desktop;

namespace Transmute.App;

/// A screenshot floating above every window, for keeping a reference in view. Drag to move,
/// wheel to resize, Ctrl+wheel for see-through, arrow keys to nudge, Esc or double-click to close.
/// Locked pins let clicks pass through to whatever is underneath.
sealed class PinWindow : Window
{
    static readonly List<PinWindow> open = [];
    public static IReadOnlyList<PinWindow> Open => open;

    readonly Image picture = new() { Stretch = Stretch.Fill };
    readonly Border frame;
    readonly Border badge;
    readonly int pixelWidth, pixelHeight;
    double zoom = 1;
    bool locked;

    public string Path { get; }

    PinWindow(string path, PixelRect? where)
    {
        Path = path;
        CaptureKit.Floating(this);
        SizeToContent = SizeToContent.Manual;
        Title = "Spinform pin";
        ShowActivated = true;
        var bitmap = CaptureKit.Load(path);
        pixelWidth = bitmap.PixelWidth;
        pixelHeight = bitmap.PixelHeight;
        picture.Source = bitmap;
        RenderOptions.SetBitmapScalingMode(picture, BitmapScalingMode.HighQuality);
        frame = new Border
        {
            Child = picture, BorderThickness = new Thickness(1), BorderBrush = new SolidColorBrush(Color.FromArgb(0x50, 0, 0, 0)),
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 14, ShadowDepth = 2, Direction = 270, Opacity = 0.35 },
            Margin = new Thickness(12),
        };
        badge = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0xD8, 0x16, 0x15, 0x1F)), CornerRadius = new CornerRadius(4), Padding = new Thickness(6, 2, 6, 3),
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 18, 0, 0), Visibility = Visibility.Collapsed,
            Child = new TextBlock { Foreground = Brushes.White, FontSize = 11 },
        };
        Content = new Grid { Children = { frame, badge } };
        CaptureKit.MakeToolWindow(this);
        CaptureKit.KeepOutOfCaptures(this);

        MouseLeftButtonDown += (_, e) =>
        {
            if (e.ClickCount == 2) { Close(); return; }
            try { DragMove(); } catch { }
        };
        MouseWheel += (_, e) =>
        {
            if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control))
            {
                Opacity = Math.Clamp(Opacity + (e.Delta > 0 ? 0.1 : -0.1), 0.2, 1);
                Tell($"{Math.Round(Opacity * 100)}% visible");
            }
            else Zoom(e.Delta > 0 ? 1.1 : 1 / 1.1);
        };
        KeyDown += (_, e) => Key(e);
        ContextMenu = Menu();
        Closed += (_, _) => open.Remove(this);
        Loaded += (_, _) =>
        {
            var monitor = where is { } r ? Screens.MonitorAt(r.X + r.Width / 2, r.Y + r.Height / 2) : Screens.MonitorUnderCursor();
            Resize();
            var margin = (int)Math.Round(12 * monitor.Scale);
            if (where is { } at) CaptureKit.Place(this, monitor, (_, _) => (at.X - margin, at.Y - margin));
            else CaptureKit.Place(this, monitor, (w, h) => (monitor.WorkArea.X + (monitor.WorkArea.Width - w) / 2, monitor.WorkArea.Y + (monitor.WorkArea.Height - h) / 2));
        };
    }

    public static PinWindow? Show(string path, PixelRect? where = null)
    {
        try
        {
            var pin = new PinWindow(path, where);
            open.Add(pin);
            pin.Show();
            pin.Activate();
            return pin;
        }
        catch (Exception e)
        {
            Toast.Show("Couldn't pin that picture", e.Message, ok: false);
            return null;
        }
    }

    /// Makes every locked pin clickable again (from the tray).
    public static void UnlockAll()
    {
        foreach (var pin in open) pin.SetLocked(false);
    }

    public static void CloseAll()
    {
        foreach (var pin in open.ToList()) pin.Close();
    }

    /// The picture at its real pixel size on this display, times the zoom.
    void Resize()
    {
        var dpi = VisualTreeHelper.GetDpi(this);
        picture.Width = Math.Max(24, pixelWidth / dpi.DpiScaleX * zoom);
        picture.Height = Math.Max(24, pixelHeight / dpi.DpiScaleY * zoom);
        Width = picture.Width + 26;
        Height = picture.Height + 26;
    }

    protected override void OnDpiChanged(DpiScale oldDpi, DpiScale newDpi)
    {
        base.OnDpiChanged(oldDpi, newDpi);
        Resize();
    }

    void Zoom(double factor)
    {
        var oldW = Width;
        var oldH = Height;
        zoom = Math.Clamp(zoom * factor, 0.1, 6);
        Resize();
        Left -= (Width - oldW) / 2;
        Top -= (Height - oldH) / 2;
        Tell($"{Math.Round(zoom * 100)}%");
    }

    void Key(KeyEventArgs e)
    {
        var step = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift) ? 10 : 1;
        switch (e.Key)
        {
            case System.Windows.Input.Key.Escape: Close(); break;
            case System.Windows.Input.Key.Left: Left -= step; break;
            case System.Windows.Input.Key.Right: Left += step; break;
            case System.Windows.Input.Key.Up: Top -= step; break;
            case System.Windows.Input.Key.Down: Top += step; break;
            case System.Windows.Input.Key.OemPlus or System.Windows.Input.Key.Add: Zoom(1.1); break;
            case System.Windows.Input.Key.OemMinus or System.Windows.Input.Key.Subtract: Zoom(1 / 1.1); break;
            case System.Windows.Input.Key.D0 or System.Windows.Input.Key.NumPad0: zoom = 1; Resize(); Tell("100%"); break;
            case System.Windows.Input.Key.C when Keyboard.Modifiers.HasFlag(ModifierKeys.Control): Copy(); break;
            default: return;
        }
        e.Handled = true;
    }

    void Copy()
    {
        try { CaptureKit.CopyImage(Path); Tell("Copied"); } catch (Exception ex) { Toast.Show("Couldn't copy", ex.Message, ok: false); }
    }

    System.Windows.Threading.DispatcherTimer? badgeTimer;

    void Tell(string text)
    {
        ((TextBlock)badge.Child).Text = text;
        badge.Visibility = Visibility.Visible;
        badgeTimer?.Stop();
        badgeTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(1.2) };
        badgeTimer.Tick += (_, _) => { badge.Visibility = locked ? Visibility.Visible : Visibility.Collapsed; if (locked) ((TextBlock)badge.Child).Text = "Locked · unlock from the tray"; badgeTimer.Stop(); };
        badgeTimer.Start();
    }

    void SetLocked(bool on)
    {
        locked = on;
        CaptureKit.SetClickThrough(this, on);
        frame.BorderBrush = on ? new SolidColorBrush(Color.FromArgb(0x90, 0x43, 0x38, 0xCA)) : new SolidColorBrush(Color.FromArgb(0x50, 0, 0, 0));
        if (on && Opacity > 0.85) Opacity = 0.8;
        Tell(on ? "Locked: clicks go through. Unlock from the tray." : "Unlocked");
    }

    ContextMenu Menu()
    {
        var menu = new ContextMenu();
        void Item(string header, Action run) { var item = new MenuItem { Header = header }; item.Click += (_, _) => run(); menu.Items.Add(item); }
        Item("Copy", Copy);
        Item("Mark up", () => Editors.Open(new Job(Path), null));
        Item("Show in folder", () => Native.RevealInExplorer([Path]));
        menu.Items.Add(new Separator());
        var opacity = new MenuItem { Header = "See-through" };
        foreach (var value in new[] { 1.0, 0.8, 0.6, 0.4 })
        {
            var item = new MenuItem { Header = $"{value * 100:0}% visible" };
            item.Click += (_, _) => Opacity = value;
            opacity.Items.Add(item);
        }
        menu.Items.Add(opacity);
        Item("Actual size", () => { zoom = 1; Resize(); });
        Item("Lock (clicks pass through)", () => SetLocked(true));
        menu.Items.Add(new Separator());
        Item("Close", Close);
        return menu;
    }
}
