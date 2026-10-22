using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Transmute.Desktop;

namespace Transmute.App;

/// Scrolling capture: a frame marks the chosen area and a small bar sits beside it. While it runs,
/// Spinform keeps photographing the area; scroll the page (or press Auto scroll) and each new part
/// is joined on. Done makes one tall (or wide) picture. The frame and bar never appear in it.
sealed class ScrollCapture
{
    public static ScrollCapture? Current { get; private set; }

    readonly PixelRect area;
    readonly Window border;
    readonly Window bar;
    readonly TextBlock status = new() { Foreground = Brushes.White, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 8, 0), MinWidth = 120 };
    readonly ToggleButton auto;
    readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(110) };
    readonly TaskCompletionSource<bool> finished = new();
    ScrollStitcher stitcher;
    ScrollDirection direction = ScrollDirection.Vertical;
    bool grabbing;
    int still;
    int lost;

    /// For the self-test and smoke test: scroll without moving the pointer.
    public Action? Scroller { get; set; }
    /// For the smoke test: where to keep the frames it saw, and what happened to each.
    public static string? DebugFolder { get; set; }
    readonly Dictionary<StitchStep, int> steps = [];
    string? lastError;
    public string Diagnostics => $"{stitcher.Frames} frames joined, {stitcher.Length} px long; " + string.Join(", ", steps.Select(kv => $"{kv.Key} {kv.Value}")) + (lastError is null ? "" : $"; last error: {lastError}");

    ScrollCapture(PixelRect area)
    {
        this.area = area;
        stitcher = new ScrollStitcher(direction);
        var monitor = Screens.MonitorAt(area.X + area.Width / 2, area.Y + area.Height / 2);

        // The frame around the area: click-through, so scrolling reaches the page under it.
        border = new Window();
        CaptureKit.Floating(border);
        border.SizeToContent = SizeToContent.Manual;
        border.ShowActivated = false;
        border.Title = "Spinform scrolling capture";
        border.Content = new Border { BorderBrush = Theme.Brand, BorderThickness = new Thickness(2), Background = Brushes.Transparent, Margin = new Thickness(0) };
        CaptureKit.MakeToolWindow(border, clickThrough: true);
        CaptureKit.KeepOutOfCaptures(border);

        bar = new Window();
        CaptureKit.Floating(bar);
        bar.ShowActivated = false;
        bar.Title = "Spinform scrolling capture";
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        var icon = Icons.Make("scroll", 16, Brushes.White);
        icon.Margin = new Thickness(4, 0, 0, 0);
        row.Children.Add(icon);
        row.Children.Add(status);
        var vertical = Toggle("Down", "Scroll down", true);
        var horizontal = Toggle("Sideways", "Scroll sideways", false);
        vertical.Checked += (_, _) => { horizontal.IsChecked = false; SetDirection(ScrollDirection.Vertical); };
        horizontal.Checked += (_, _) => { vertical.IsChecked = false; SetDirection(ScrollDirection.Horizontal); };
        vertical.Unchecked += (_, _) => { if (horizontal.IsChecked != true) vertical.IsChecked = true; };
        horizontal.Unchecked += (_, _) => { if (vertical.IsChecked != true) horizontal.IsChecked = true; };
        row.Children.Add(vertical);
        row.Children.Add(horizontal);
        auto = Toggle("Auto scroll", "Spinform scrolls the page for you", false);
        auto.Margin = new Thickness(8, 0, 0, 0);
        row.Children.Add(auto);
        var done = new Button { Content = "Done", Style = CaptureKit.Style("Primary"), Margin = new Thickness(10, 0, 0, 0), Padding = new Thickness(14, 3, 14, 4), Focusable = false };
        done.Click += (_, _) => _ = Finish(true);
        row.Children.Add(done);
        var cancel = CaptureKit.IconButton("close", "Cancel", () => _ = Finish(false), 12, Brushes.White);
        cancel.Margin = new Thickness(4, 0, 0, 0);
        row.Children.Add(cancel);
        bar.Content = new Border { Background = new SolidColorBrush(Color.FromArgb(0xEE, 0x16, 0x15, 0x1F)), CornerRadius = new CornerRadius(10), Padding = new Thickness(8, 6, 8, 6), Child = row, Margin = new Thickness(6) };
        CaptureKit.MakeToolWindow(bar);
        CaptureKit.KeepOutOfCaptures(bar);
        bar.KeyDown += (_, e) => { if (e.Key == Key.Escape) _ = Finish(false); };

        border.Show();
        var t = (int)Math.Round(2 * monitor.Scale);
        CaptureKit.SetBounds(border, new PixelRect(area.X - t, area.Y - t, area.Width + 2 * t, area.Height + 2 * t));
        bar.Show();
        CaptureKit.Place(bar, monitor, (w, h) =>
        {
            var x = Math.Clamp(area.X + (area.Width - w) / 2, monitor.WorkArea.X, Math.Max(monitor.WorkArea.X, monitor.WorkArea.Right - w));
            var below = area.Bottom + t + 4;
            var y = below + h <= monitor.WorkArea.Bottom ? below : area.Y - t - h - 4 >= monitor.WorkArea.Y ? area.Y - t - h - 4 : area.Bottom - h - 8;
            return (x, y);
        });
        timer.Tick += async (_, _) => await Tick();
        Update();
    }

    static ToggleButton Toggle(string text, string tip, bool on) => new()
    {
        Content = text, ToolTip = tip, IsChecked = on, Focusable = false, Padding = new Thickness(9, 3, 9, 4), Margin = new Thickness(2, 0, 0, 0),
        Style = BarToggle(),
    };

    static Style? barToggle;
    static Style BarToggle()
    {
        if (barToggle is not null) return barToggle;
        var style = new Style(typeof(ToggleButton));
        var template = new ControlTemplate(typeof(ToggleButton));
        var back = new FrameworkElementFactory(typeof(Border)) { Name = "Back" };
        back.SetValue(Border.CornerRadiusProperty, new CornerRadius(6));
        back.SetValue(Border.BackgroundProperty, new SolidColorBrush(Color.FromArgb(0x26, 0xFF, 0xFF, 0xFF)));
        back.SetValue(Border.PaddingProperty, new TemplateBindingExtension(Control.PaddingProperty));
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
        back.AppendChild(presenter);
        template.VisualTree = back;
        var on = new Trigger { Property = ToggleButton.IsCheckedProperty, Value = true };
        on.Setters.Add(new Setter(Border.BackgroundProperty, Theme.Brand, "Back"));
        template.Triggers.Add(on);
        style.Setters.Add(new Setter(Control.TemplateProperty, template));
        style.Setters.Add(new Setter(Control.ForegroundProperty, Brushes.White));
        style.Setters.Add(new Setter(FrameworkElement.CursorProperty, Cursors.Hand));
        return barToggle = style;
    }

    /// Starts a scrolling capture of an area and waits until it's done or cancelled.
    public static async Task Start(PixelRect area, Action? scroller = null)
    {
        if (Current is not null) return;
        if (area.Width < 40 || area.Height < 40)
        {
            Toast.Show("That area is too small", "Choose at least 40 × 40 pixels of the part that scrolls.", ok: false);
            return;
        }
        var capture = new ScrollCapture(area) { Scroller = scroller };
        Current = capture;
        capture.timer.Start();
        try { await capture.finished.Task; }
        finally { Current = null; }
    }

    void SetDirection(ScrollDirection next)
    {
        if (next == direction) return;
        direction = next;
        stitcher = new ScrollStitcher(direction);
        still = 0;
        Update();
    }

    async Task Tick()
    {
        if (grabbing) return;
        grabbing = true;
        try
        {
            var s = stitcher;
            var index = steps.Values.Sum();
            var step = await Task.Run(() =>
            {
                var frame = ScreenGrab.Area(area);
                if (DebugFolder is { } debug && index < 8) frame.Save(Path.Combine(debug, $"scroll-frame-{index:00}.png"));
                return s.Add(frame);
            });
            steps[step] = steps.GetValueOrDefault(step) + 1;
            if (s != stitcher) return;
            switch (step)
            {
                case StitchStep.Unchanged: still++; break;
                case StitchStep.Lost: lost++; still = 0; break;
                case StitchStep.Full: Update("Longest it can get"); await Finish(true); return;
                default: still = 0; break;
            }
            if (auto.IsChecked == true || Scroller is not null)
            {
                if (still >= 6) { auto.IsChecked = false; if (Scroller is not null) { await Finish(true); return; } }
                else if (step != StitchStep.Lost || lost % 3 == 0) Scroll(); // after a miss, look again before moving on
            }
            Update();
        }
        catch (Exception e)
        {
            lastError = e.Message;
            Update(e.Message);
        }
        finally { grabbing = false; }
    }

    void Update(string? note = null)
    {
        var size = direction == ScrollDirection.Vertical ? $"{area.Width} × {stitcher.Length}" : $"{stitcher.Length} × {area.Height}";
        status.Text = note ?? (stitcher.Frames <= 1 ? (direction == ScrollDirection.Vertical ? "Scroll down slowly…" : "Scroll sideways slowly…") : size);
    }

    /// Turns the wheel over the middle of the area.
    void Scroll()
    {
        if (Scroller is not null) { Scroller(); return; }
        var (cx, cy) = (area.X + area.Width / 2, area.Y + area.Height / 2);
        var (ox, oy) = Screens.Cursor;
        if (!area.Contains(ox, oy)) SetCursorPos(cx, cy);
        var input = new INPUT { type = 0 };
        input.mi.dwFlags = direction == ScrollDirection.Vertical ? 0x0800u : 0x1000u; // wheel / horizontal wheel
        input.mi.mouseData = direction == ScrollDirection.Vertical ? unchecked((uint)-120) : 120u;
        SendInput(1, [input], Marshal.SizeOf<INPUT>());
    }

    async Task Finish(bool keep)
    {
        if (finished.Task.IsCompleted) return;
        timer.Stop();
        border.Close();
        bar.Close();
        try
        {
            if (keep && stitcher.Frames > 0)
            {
                while (grabbing) await Task.Delay(20);
                var image = await Task.Run(stitcher.Result);
                await Capture.Deliver(image, area, "Scrolling capture");
            }
        }
        catch (Exception e) { Toast.Show("Couldn't join the pictures", e.Message, ok: false); }
        finally { finished.TrySetResult(keep); }
    }

    public Task Done() => Finish(true);

    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)]
    struct INPUT
    {
        [FieldOffset(0)] public uint type;
        [FieldOffset(8)] public MOUSEINPUT mi;
    }
    [DllImport("user32.dll")] static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
}
