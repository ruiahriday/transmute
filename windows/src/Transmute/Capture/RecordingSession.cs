using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Transmute.Desktop;

namespace Transmute.App;

/// One screen recording, from choosing what to include to the finished file. A dashed frame marks
/// the area; a small bar offers sound, camera, clicks and keys, then Start. While recording the
/// bar shows the time and a Stop button (Stop is also in the tray and on the record shortcut).
/// None of Spinform's own windows appear in the video.
sealed class RecordingSession
{
    public static RecordingSession? Current { get; private set; }
    public static event Action? StateChanged;

    static Settings Prefs => Settings.Current;

    readonly PixelRect area;
    readonly MonitorInfo monitor;
    readonly Window border;
    readonly Window bar;
    readonly StackPanel setup = new() { Orientation = Orientation.Horizontal };
    readonly StackPanel live = new() { Orientation = Orientation.Horizontal, Visibility = Visibility.Collapsed };
    readonly TextBlock clock = new() { Foreground = Brushes.White, FontSize = 13, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 10, 0), FontFamily = new FontFamily("Segoe UI Variable Display, Segoe UI"), MinWidth = 44 };
    readonly DispatcherTimer ticker = new() { Interval = TimeSpan.FromMilliseconds(250) };
    readonly TaskCompletionSource<bool> finished = new();
    ScreenRecorder? recorder;
    CameraBubble? bubble;
    IDisposable? icons;
    bool stopping;

    /// For the smoke test and self-checks: start without waiting for a click and stop after this long.
    public TimeSpan? AutoStop { get; set; }

    RecordingSession(PixelRect area)
    {
        this.area = area;
        monitor = Screens.MonitorAt(area.X + area.Width / 2, area.Y + area.Height / 2);

        border = new Window();
        CaptureKit.Floating(border);
        border.SizeToContent = SizeToContent.Manual;
        border.ShowActivated = false;
        border.Title = "Spinform recording area";
        border.Content = new System.Windows.Shapes.Rectangle { Stroke = new SolidColorBrush(Color.FromRgb(0xEF, 0x44, 0x44)), StrokeThickness = 2, StrokeDashArray = [4, 3] };
        CaptureKit.MakeToolWindow(border, clickThrough: true);
        CaptureKit.KeepOutOfCaptures(border);

        bar = new Window();
        CaptureKit.Floating(bar);
        bar.Title = "Spinform recording";
        BuildSetup();
        BuildLive();
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(setup);
        row.Children.Add(live);
        bar.Content = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0xF0, 0x20, 0x20, 0x20)), CornerRadius = new CornerRadius(8), Padding = new Thickness(8, 6, 8, 6), Child = row, Margin = new Thickness(6),
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 14, ShadowDepth = 2, Direction = 270, Opacity = 0.3 },
        };
        CaptureKit.MakeToolWindow(bar);
        CaptureKit.KeepOutOfCaptures(bar);
        bar.KeyDown += (_, e) => { if (e.Key == Key.Escape && recorder is null) _ = Cancel(); };
        bar.MouseLeftButtonDown += (_, e) => { if (e.OriginalSource is Border) try { bar.DragMove(); } catch { } };
        ticker.Tick += (_, _) => Tick();
    }

    // The bar before recording: what to include.

    void BuildSetup()
    {
        ToggleButton Option(string glyph, string tip, bool on, Action<bool> changed)
        {
            var b = new ToggleButton { Content = Icons.Make(glyph, 16), ToolTip = tip, IsChecked = on, Style = BarToggle(), Padding = new Thickness(7, 5, 7, 5), Margin = new Thickness(0, 0, 3, 0), Focusable = false };
            b.Checked += (_, _) => { changed(true); Prefs.Save(); };
            b.Unchecked += (_, _) => { changed(false); Prefs.Save(); };
            setup.Children.Add(b);
            return b;
        }
        Option("mic", "Record the microphone", Prefs.RecordMicrophone, v => Prefs.RecordMicrophone = v);
        Option("speaker", "Record the sound the PC plays", Prefs.RecordSystemAudio, v => Prefs.RecordSystemAudio = v);
        Option("camera", "Show the camera in a bubble", Prefs.RecordCamera, v => { Prefs.RecordCamera = v; _ = ShowCamera(v); });
        Option("click", "Show clicks", Prefs.RecordClicks, v => Prefs.RecordClicks = v);
        Option("keyboard", "Show the keys pressed", Prefs.RecordKeystrokes, v => Prefs.RecordKeystrokes = v);
        Option("cursor", "Show the pointer", Prefs.RecordCursor, v => Prefs.RecordCursor = v);
        setup.Children.Add(new System.Windows.Shapes.Rectangle { Width = 1, Fill = new SolidColorBrush(Color.FromArgb(0x50, 0xFF, 0xFF, 0xFF)), Margin = new Thickness(5, 3, 7, 3) });
        var gif = new ToggleButton { Content = "GIF", ToolTip = "Make an animated GIF instead of an MP4 video", IsChecked = Prefs.RecordFormat == "gif", Style = BarToggle(), Padding = new Thickness(8, 4, 8, 5), Focusable = false, FontWeight = FontWeights.SemiBold };
        gif.Checked += (_, _) => { Prefs.RecordFormat = "gif"; Prefs.Save(); };
        gif.Unchecked += (_, _) => { Prefs.RecordFormat = "mp4"; Prefs.Save(); };
        setup.Children.Add(gif);
        var size = new TextBlock { Text = $"{area.Width} × {area.Height}", Foreground = new SolidColorBrush(Color.FromArgb(0xB0, 0xFF, 0xFF, 0xFF)), FontSize = 11, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 4, 0) };
        setup.Children.Add(size);
        var start = new Button { Content = Icons.WithText("record", "Start recording", 14), Style = CaptureKit.Style("Primary"), Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(12, 4, 12, 5), Focusable = false };
        start.Click += (_, _) => _ = Begin();
        setup.Children.Add(start);
        var cancel = CaptureKit.IconButton("close", "Cancel (Esc)", () => _ = Cancel(), 12, Brushes.White);
        cancel.Margin = new Thickness(4, 0, 0, 0);
        setup.Children.Add(cancel);
    }

    void BuildLive()
    {
        var dot = new System.Windows.Shapes.Ellipse { Width = 10, Height = 10, Fill = new SolidColorBrush(Color.FromRgb(0xEF, 0x44, 0x44)), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4, 0, 0, 0) };
        Theme.Loop(dot, UIElement.OpacityProperty, 1, 0.35, 0.8);
        live.Children.Add(dot);
        live.Children.Add(clock);
        var stop = new Button { Content = Icons.WithText("stop", "Stop", 14), Style = CaptureKit.Style("Primary"), Padding = new Thickness(12, 4, 12, 5), Focusable = false, ToolTip = "Stop and save" };
        stop.Click += (_, _) => _ = Stop();
        live.Children.Add(stop);
        var discard = CaptureKit.IconButton("trash", "Stop and throw away", () => _ = Cancel(), 14, Brushes.White);
        discard.Margin = new Thickness(4, 0, 0, 0);
        live.Children.Add(discard);
    }

    static Style? barToggle;
    static Style BarToggle()
    {
        if (barToggle is not null) return barToggle;
        var style = new Style(typeof(ToggleButton));
        var template = new ControlTemplate(typeof(ToggleButton));
        var back = new FrameworkElementFactory(typeof(Border)) { Name = "Back" };
        back.SetValue(Border.CornerRadiusProperty, new CornerRadius(6));
        back.SetValue(Border.BackgroundProperty, Brushes.Transparent);
        back.SetValue(Border.PaddingProperty, new TemplateBindingExtension(Control.PaddingProperty));
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
        back.AppendChild(presenter);
        template.VisualTree = back;
        var off = new Trigger { Property = ToggleButton.IsCheckedProperty, Value = false };
        off.Setters.Add(new Setter(UIElement.OpacityProperty, 0.55));
        var on = new Trigger { Property = ToggleButton.IsCheckedProperty, Value = true };
        on.Setters.Add(new Setter(Border.BackgroundProperty, new SolidColorBrush(Color.FromArgb(0x40, 0xFF, 0xFF, 0xFF)), "Back"));
        template.Triggers.Add(off);
        template.Triggers.Add(on);
        style.Setters.Add(new Setter(Control.TemplateProperty, template));
        style.Setters.Add(new Setter(Control.ForegroundProperty, Brushes.White));
        style.Setters.Add(new Setter(FrameworkElement.CursorProperty, Cursors.Hand));
        return barToggle = style;
    }

    /// Shows the frame and the bar for an area (or a window's bounds) and waits until the
    /// recording is saved or cancelled.
    public static async Task Prepare(PixelRect rect, IntPtr window, TimeSpan? autoStop = null)
    {
        if (Current is not null) return;
        if (window != IntPtr.Zero) rect = Screens.WindowBounds(window);
        var area = Screens.VirtualScreen.Intersect(rect).Even();
        if (area.Width < 32 || area.Height < 32)
        {
            Toast.Show("That area is too small to record", "Choose at least 32 × 32 pixels.", ok: false);
            return;
        }
        if (Tools.Ffmpeg is null)
        {
            Toast.Show("Recording needs ffmpeg", "Spinform's ffmpeg is missing. Reinstall Spinform to get it back.", ok: false);
            return;
        }
        var session = new RecordingSession(area) { AutoStop = autoStop };
        Current = session;
        StateChanged?.Invoke();
        try
        {
            session.ShowFrame();
            if (Prefs.RecordCamera) await session.ShowCamera(true);
            if (autoStop is not null) _ = session.Begin();
            await session.finished.Task;
        }
        finally
        {
            Current = null;
            StateChanged?.Invoke();
        }
    }

    void ShowFrame()
    {
        border.Show();
        var t = (int)Math.Round(2 * monitor.Scale);
        CaptureKit.SetBounds(border, new PixelRect(area.X - t, area.Y - t, area.Width + 2 * t, area.Height + 2 * t));
        bar.Show();
        PlaceBar();
        bar.Activate();
    }

    void PlaceBar()
    {
        var wa = monitor.WorkArea;
        CaptureKit.Place(bar, monitor, (w, h) =>
        {
            var x = Math.Clamp(area.X + (area.Width - w) / 2, wa.X, Math.Max(wa.X, wa.Right - w));
            var gap = (int)Math.Round(6 * monitor.Scale);
            int y;
            if (area.Bottom + gap + h <= wa.Bottom) y = area.Bottom + gap;
            else if (area.Y - gap - h >= wa.Y) y = area.Y - gap - h;
            else y = wa.Bottom - h - gap; // full screen: it sits inside, but never shows in the video
            return (x, y);
        });
    }

    async Task ShowCamera(bool on)
    {
        if (!on) { bubble?.Close(); bubble = null; return; }
        if (bubble is not null) return;
        try
        {
            bubble = await CameraBubble.Open(area, monitor);
        }
        catch (Exception e)
        {
            Prefs.RecordCamera = false;
            Toast.Show("Couldn't start the camera", JobQueue.Describe(e), ok: false, seconds: 8);
        }
    }

    // Recording

    async Task Begin()
    {
        if (recorder is not null || stopping) return;
        setup.IsEnabled = false;
        var countdown = AutoStop is null ? Prefs.RecordCountdown : 0;
        if (countdown > 0)
        {
            bar.Hide();
            var go = await Countdown.Run(countdown, monitor, "Recording starts · Esc to cancel");
            bar.Show();
            if (!go) { setup.IsEnabled = true; return; }
        }
        try
        {
            if (Prefs.HideDesktopIcons) icons = DesktopIcons.Hide();
            var gif = Prefs.RecordFormat == "gif";
            var encoder = await ScreenRecorder.PickEncoder(gif ? "libx264" : Prefs.RecordEncoder);
            var format = new RecordingFormat
            {
                Fps = gif ? Math.Min(Prefs.RecordFps, 15) : Prefs.RecordFps,
                Quality = Prefs.RecordQuality == "Standard" ? RecordingQuality.Standard : RecordingQuality.High,
                MaxSide = gif && Prefs.RecordMaxSide == 0 ? 960 : Prefs.RecordMaxSide,
                Encoder = encoder,
            };
            var look = new RecordingLook
            {
                Cursor = Prefs.RecordCursor,
                Clicks = Prefs.RecordClicks,
                ClickColor = int.TryParse(Prefs.ClickColor.TrimStart('#'), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var c) ? c : 0xF59E0B,
                ClickSize = Prefs.ClickSize,
                ClickFilled = Prefs.ClickFilled,
                ClickAnimated = Prefs.ClickAnimated,
                Keystrokes = Prefs.RecordKeystrokes,
                KeystrokesShortcutsOnly = Prefs.KeystrokesShortcutsOnly,
                KeystrokePosition = Prefs.KeystrokePosition,
                KeystrokeSize = Prefs.KeystrokeSize,
                KeystrokesDark = Prefs.KeystrokesDark,
            };
            var output = OutputPaths.TempFile("mp4");
            recorder = new ScreenRecorder(area, format, look, output, Prefs.RecordMicrophone, Prefs.RecordSystemAudio) { Scale = monitor.Scale };
            if (bubble is not null) recorder.Camera = bubble.Frame;
            recorder.Start();
        }
        catch (Exception e)
        {
            recorder?.Cancel();
            recorder?.CleanUp();
            recorder = null;
            icons?.Dispose();
            Toast.Show("Couldn't start recording", JobQueue.Describe(e), ok: false, seconds: 8);
            Close();
            finished.TrySetResult(false);
            return;
        }
        setup.Visibility = Visibility.Collapsed;
        live.Visibility = Visibility.Visible;
        bar.UpdateLayout();
        PlaceBar();
        ticker.Start();
        StateChanged?.Invoke();
        if (recorder.Notes.Count > 0) Toast.Show("Recording without some sound", string.Join(" ", recorder.Notes), ok: false, seconds: 8);
        if (AutoStop is { } after) { await Task.Delay(after); await Stop(); }
    }

    public TimeSpan Elapsed => recorder?.Elapsed ?? TimeSpan.Zero;
    public bool IsRecording => recorder is not null && !stopping;

    void Tick()
    {
        var text = CaptureHistory.Duration(Elapsed.TotalSeconds);
        clock.Text = text;
        App.Current.SetTrayStatus($"Spinform · recording {text}");
    }

    /// The record shortcut pressed again, or Stop in the tray.
    public async Task StopFromShortcut()
    {
        if (recorder is null) await Begin();
        else await Stop();
    }

    public async Task Stop()
    {
        if (recorder is null || stopping) return;
        stopping = true;
        ticker.Stop();
        App.Current.SetTrayStatus(null);
        clock.Text = "Saving…";
        RecordingResult result;
        try
        {
            result = await recorder.Stop();
        }
        catch (Exception e)
        {
            Toast.Show("Couldn't save the recording", JobQueue.Describe(e), ok: false, seconds: 10);
            recorder.CleanUp();
            Close();
            finished.TrySetResult(false);
            return;
        }
        Close();
        try
        {
            await Save(result);
        }
        catch (Exception e)
        {
            Toast.Show("Couldn't save the recording", JobQueue.Describe(e), ok: false, seconds: 10);
        }
        finally
        {
            recorder.CleanUp();
            finished.TrySetResult(true);
        }
    }

    async Task Save(RecordingResult result)
    {
        var file = result.Path;
        var width = result.Width;
        var height = result.Height;
        string ext = "mp4";
        if (Prefs.RecordFormat == "gif")
        {
            Toast.Show("Making the GIF…", null, glyph: "film", seconds: 30);
            var folder = OutputPaths.TempDir();
            var converted = await Engine.Perform(new JobOperation.Convert(OutputFormat.Gif), file, new ConversionOptions { OutputFolder = folder }, _ => { }, default);
            OutputPaths.TryDelete(file);
            file = converted.Outputs[0];
            ext = "gif";
        }
        string? saved = null;
        if (Prefs.CaptureAutoSave)
        {
            Directory.CreateDirectory(CaptureKit.RecordingFolder);
            saved = OutputPaths.Unique(CaptureKit.RecordingFolder, CaptureKit.NewName("Recording"), ext);
            File.Copy(file, saved);
        }
        var item = Capture.Remember(file, CaptureKind.Recording, width, height, result.Seconds, saved, area);
        // Where the pointer went, for automatic zooms in the video studio.
        try
        {
            if (item.HistoryId is { } id && File.Exists(result.EventsPath))
                File.Copy(result.EventsPath, Path.Combine(CaptureKit.HistoryFolder, id + ".pointer.json"), true);
            if (saved is not null && File.Exists(result.EventsPath))
                File.Copy(result.EventsPath, PointerFileFor(saved), true);
        }
        catch { }
        if (Prefs.CaptureOverlay) QuickAccess.Show(item);
        else Toast.Show("Recording saved", saved is null ? null : Path.GetFileName(saved), action: saved is null ? null : ("Show in folder", () => Native.RevealInExplorer([saved])));
        if (Prefs.OpenEditorAfterRecording && ext == "mp4") Editors.Open(new Job(item.Path), null);
    }

    /// The pointer movements saved next to a recording, kept in Spinform's own folder.
    public static string PointerFileFor(string video)
    {
        var folder = Path.Combine(CaptureKit.HistoryFolder, "pointer");
        Directory.CreateDirectory(folder);
        var key = Convert.ToHexString(System.Security.Cryptography.SHA1.HashData(System.Text.Encoding.UTF8.GetBytes(Path.GetFullPath(video).ToLowerInvariant())))[..16];
        return Path.Combine(folder, key + ".json");
    }

    public async Task Cancel()
    {
        if (stopping) return;
        stopping = true;
        ticker.Stop();
        App.Current.SetTrayStatus(null);
        if (recorder is not null)
        {
            await Task.Run(recorder.Cancel);
            recorder.CleanUp();
        }
        Close();
        finished.TrySetResult(false);
    }

    void Close()
    {
        icons?.Dispose();
        icons = null;
        bubble?.Close();
        bubble = null;
        border.Close();
        bar.Close();
    }

    /// For the smoke test: the bar as it looks while recording.
    public Window Bar => bar;
}

/// The round (or rounded) camera picture shown on screen while recording; drag it anywhere. The
/// video gets the same picture drawn into each frame, so the bubble window itself stays out of it.
sealed class CameraBubble : Window
{
    readonly CameraFeed feed;
    readonly Image view = new() { Stretch = Stretch.UniformToFill };
    readonly CameraShape shape;
    readonly int size;
    volatile int left, top;
    BgraImage? shaped;
    readonly object gate = new();
    readonly PixelRect area;

    CameraBubble(CameraFeed feed, PixelRect area, MonitorInfo monitor)
    {
        this.feed = feed;
        this.area = area;
        shape = Enum.TryParse<CameraShape>(Settings.Current.CameraShape, out var s) ? s : CameraShape.Circle;
        size = (int)Math.Round(Math.Clamp(Settings.Current.CameraSize, 80, 480) * monitor.Scale);
        CaptureKit.Floating(this);
        SizeToContent = SizeToContent.Manual;
        ShowActivated = false;
        Title = "Spinform camera";
        RenderOptions.SetBitmapScalingMode(view, BitmapScalingMode.HighQuality);
        var clip = new Border { Child = view, ClipToBounds = true, Cursor = Cursors.SizeAll, ToolTip = "Drag to move the camera" };
        Content = clip;
        CaptureKit.MakeToolWindow(this);
        CaptureKit.KeepOutOfCaptures(this);
        MouseLeftButtonDown += (_, _) => { try { DragMove(); } catch { } Track(); };
        LocationChanged += (_, _) => Track();
        SizeChanged += (_, _) =>
        {
            clip.CornerRadius = shape switch { CameraShape.Circle => new CornerRadius(ActualWidth / 2), CameraShape.Rounded => new CornerRadius(ActualWidth * 0.14), _ => new CornerRadius(0) };
        };
        feed.FrameArrived += () => Dispatcher.BeginInvoke(Refresh, DispatcherPriority.Render);
    }

    public static async Task<CameraBubble> Open(PixelRect area, MonitorInfo monitor)
    {
        var feed = await CameraFeed.Start();
        var bubble = new CameraBubble(feed, area, monitor);
        bubble.Show();
        var margin = (int)Math.Round(24 * monitor.Scale);
        PixelRect bounds;
        if (bubble.shape == CameraShape.Full) bounds = area;
        else
        {
            var w = bubble.size;
            var h = bubble.shape == CameraShape.Circle ? w : w * 3 / 4;
            var position = Settings.Current.CameraPosition ?? "bottom-right";
            var x = position.EndsWith("left") ? area.X + margin : area.Right - w - margin;
            var y = position.StartsWith("top") ? area.Y + margin : area.Bottom - h - margin;
            bounds = new PixelRect(x, y, w, h);
        }
        CaptureKit.SetBounds(bubble, bounds);
        bubble.Track();
        return bubble;
    }

    void Track()
    {
        try
        {
            var r = Screens.WindowBounds(CaptureKit.Handle(this));
            left = r.X;
            top = r.Y;
            if (r.Width > 0 && (shapedWidth != r.Width || shapedHeight != r.Height)) { shapedWidth = r.Width; shapedHeight = r.Height; }
        }
        catch { }
    }

    volatile int shapedWidth, shapedHeight;

    void Refresh()
    {
        if (feed.Latest is not { } frame) return;
        view.Source = CaptureKit.ToBitmap(frame);
        view.RenderTransform = new ScaleTransform(-1, 1, ActualWidth / 2, 0); // a mirror, like every camera app
        if (shapedWidth <= 0) return;
        var picture = CameraFeed.Shape(frame, shapedWidth, shapedHeight, shape);
        lock (gate) shaped = picture;
    }

    /// The picture to draw into the current video frame, and where on screen.
    public (BgraImage Image, int X, int Y)? Frame()
    {
        BgraImage? picture;
        lock (gate) picture = shaped;
        return picture is null ? null : (picture, left, top);
    }

    protected override void OnClosed(EventArgs e)
    {
        base.OnClosed(e);
        feed.Dispose();
    }
}
