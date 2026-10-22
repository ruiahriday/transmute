using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Transmute.Desktop;

namespace Transmute.App;

/// The video studio: turns a screen recording into a polished clip. Zooms follow the clicks on
/// their own (or are placed by hand), the pointer glides and can be drawn bigger, the video sits
/// on a background with padding and a shadow, and it exports landscape, square or vertical.
sealed class StudioWindow : Window
{
    readonly string video;
    readonly PointerTrack? track;
    StudioOptions options;
    double duration, position;
    BgraImage? source;
    readonly Image preview = new() { Stretch = Stretch.Uniform, Margin = new Thickness(18), Cursor = Cursors.Cross };
    readonly TextBlock status = new() { Foreground = Brushes.White, Margin = new Thickness(12), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Bottom };
    readonly Slider scrub = new() { Minimum = 0, Maximum = 1, Margin = new Thickness(16, 6, 16, 4) };
    readonly TextBlock timeLabel = new() { Foreground = Brushes.White, Margin = new Thickness(16, 0, 16, 10) };
    readonly DispatcherTimer frameTimer = new() { Interval = TimeSpan.FromMilliseconds(150) };
    readonly DispatcherTimer drawTimer = new() { Interval = TimeSpan.FromMilliseconds(60) };
    readonly StackPanel zoomList = new();
    readonly TextBlock trimLabel = new() { Style = (Style)Application.Current.FindResource("Caption") };
    readonly Button exportButton;
    (double X, double Y) focus = (0.5, 0.5);
    int frameGeneration;
    CancellationTokenSource? exporting;

    public bool Drawn { get; private set; }

    StudioWindow(string video, PointerTrack? track)
    {
        this.video = video;
        this.track = track;
        options = new StudioOptions
        {
            Shape = StudioShape.Landscape,
            Background = Frames.BuiltIn[0].Style with { Padding = 0.07 },
            AutoZoom = track is not null,
            DrawCursor = track is { CursorDrawn: false },
        };
        Ui.SetUpEditorWindow(this, "Video Studio · " + Path.GetFileName(video));
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        var picture = new Grid { Background = BackgroundPanel.Checkerboard(10) };
        picture.Children.Add(preview);
        picture.Children.Add(status);
        var timeline = new StackPanel();
        timeline.Children.Add(scrub);
        timeline.Children.Add(timeLabel);
        var left = new DockPanel();
        DockPanel.SetDock(timeline, Dock.Bottom);
        left.Children.Add(timeline);
        left.Children.Add(picture);
        scrub.ValueChanged += (_, e) => { position = e.NewValue; ShowTime(); frameTimer.Stop(); frameTimer.Start(); };
        frameTimer.Tick += (_, _) => { frameTimer.Stop(); _ = LoadFrame(); };
        drawTimer.Tick += (_, _) => { drawTimer.Stop(); _ = Draw(); };
        preview.MouseLeftButtonDown += (_, e) =>
        {
            // Clicking the preview picks where a manual zoom looks.
            var p = e.GetPosition(preview);
            if (preview.ActualWidth < 1) return;
            focus = (Math.Clamp(p.X / preview.ActualWidth, 0, 1), Math.Clamp(p.Y / preview.ActualHeight, 0, 1));
            status.Text = $"Zoom centre set to {focus.X:P0} across, {focus.Y:P0} down";
        };

        var c = new StackPanel();
        c.Children.Add(Ui.Heading("Zoom"));
        var auto = new CheckBox { Content = "Zoom in on clicks automatically", IsChecked = options.AutoZoom, IsEnabled = track is not null };
        auto.Click += (_, _) => Change(options with { AutoZoom = auto.IsChecked == true });
        c.Children.Add(auto);
        if (track is null) c.Children.Add(Ui.Caption("This video has no saved pointer movements, so zooms are placed by hand. Recordings made with Spinform have them."));
        c.Children.Add(Ui.Slider("Closer", 1.2, 3, options.ZoomLevel, v => $"{v:0.0}×", v => Change(options with { ZoomLevel = v }), 0.1).View);
        c.Children.Add(Ui.Row(Ui.Button("Add zoom here", (_, _) => AddZoom(), tip: "Zooms in for two seconds from the playhead, centred where you last clicked the preview")));
        c.Children.Add(zoomList);

        c.Children.Add(Ui.Heading("Pointer"));
        var draw = new CheckBox { Content = "Draw the pointer", IsChecked = options.DrawCursor, IsEnabled = track is { CursorDrawn: false } };
        draw.Click += (_, _) => Change(options with { DrawCursor = draw.IsChecked == true });
        c.Children.Add(draw);
        var smooth = new CheckBox { Content = "Smooth its movement", IsChecked = options.SmoothCursor, IsEnabled = track is { CursorDrawn: false } };
        smooth.Click += (_, _) => Change(options with { SmoothCursor = smooth.IsChecked == true });
        c.Children.Add(smooth);
        c.Children.Add(Ui.Slider("Size", 0.6, 3, options.CursorSize, v => $"{v:0.0}×", v => Change(options with { CursorSize = v }), 0.1).View);
        if (track is not { CursorDrawn: false })
            c.Children.Add(Ui.Caption("The pointer is already in this video. To restyle it here, record with Settings › Capture › Show the pointer turned off."));

        c.Children.Add(Ui.Heading("Look"));
        c.Children.Add(Ui.Labelled("Shape", Ui.Combo(Enum.GetValues<StudioShape>().Select(s => (StudioOptions.Label(s), s)), options.Shape, s => Change(options with { Shape = s }))));
        var backgrounds = new List<(string, int)> { ("None", -1) };
        backgrounds.AddRange(Frames.BuiltIn.Select((p, i) => (p.Name, i)));
        c.Children.Add(Ui.Labelled("Background", Ui.Combo(backgrounds, 0, i => Change(options with { Background = i < 0 ? null : Frames.BuiltIn[i].Style with { Padding = options.Background?.Padding ?? 0.07, Shadow = options.Background?.Shadow ?? 0.6 } }))));
        c.Children.Add(Ui.Slider("Padding", 0, 0.2, 0.07, Ui.Percent, v => { if (options.Background is { } b) Change(options with { Background = b with { Padding = v } }); }, 0.01).View);
        c.Children.Add(Ui.Slider("Shadow", 0, 1, 0.6, Ui.Percent, v => { if (options.Background is { } b) Change(options with { Background = b with { Shadow = v } }); }, 0.05).View);
        var blur = new CheckBox { Content = "Motion blur while the camera moves", IsChecked = options.MotionBlur };
        blur.Click += (_, _) => Change(options with { MotionBlur = blur.IsChecked == true });
        c.Children.Add(blur);

        c.Children.Add(Ui.Heading("Trim"));
        c.Children.Add(Ui.Row(
            Ui.Button("Start here", (_, _) => { options = options with { TrimStart = position }; ShowTrim(); }),
            Ui.Button("End here", (_, _) => { options = options with { TrimEnd = position }; ShowTrim(); }),
            Ui.Button("Reset", (_, _) => { options = options with { TrimStart = 0, TrimEnd = null }; ShowTrim(); })));
        c.Children.Add(trimLabel);
        c.Children.Add(Ui.Caption("Exports use the graphics card's video encoder when it works, otherwise the processor."));

        exportButton = Ui.Button("Export", (_, _) => _ = Export(), primary: true);
        var cancel = Ui.Button("Close", (_, _) => Close());
        Content = Ui.EditorLayout(left, c, cancel, exportButton);
        Loaded += async (_, _) => await Load();
        Closed += (_, _) => exporting?.Cancel();
        KeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); };
        RefreshZooms();
    }

    /// Opens the studio for a recording, with its pointer movements when Spinform saved them.
    public static StudioWindow? Open(string video)
    {
        try
        {
            var window = new StudioWindow(video, FindTrack(video));
            window.Show();
            window.Activate();
            return window;
        }
        catch (Exception e)
        {
            Toast.Show("Couldn't open the studio", e.Message, ok: false);
            return null;
        }
    }

    static PointerTrack? FindTrack(string video)
    {
        var beside = RecordingSession.PointerFileFor(video);
        if (File.Exists(beside)) return PointerTrack.Load(beside);
        try
        {
            var history = CaptureKit.History;
            var item = history.Items.FirstOrDefault(i => string.Equals(history.PathOf(i), video, StringComparison.OrdinalIgnoreCase)
                || string.Equals(i.SavedPath, video, StringComparison.OrdinalIgnoreCase));
            var file = item is null ? null : Path.Combine(history.Folder, item.Id + ".pointer.json");
            return file is not null && File.Exists(file) ? PointerTrack.Load(file) : null;
        }
        catch { return null; }
    }

    async Task Load()
    {
        status.Text = "Loading…";
        try
        {
            duration = await MediaInfo.Duration(video);
            scrub.Maximum = Math.Max(0.1, duration);
            // Start where something happens: the first click, or a second in.
            var first = track?.Samples.FirstOrDefault(s => s.Click)?.Time;
            scrub.Value = Math.Min(duration, first is { } f ? f + 0.6 : Math.Min(1, duration / 2));
            ShowTrim();
            await LoadFrame();
        }
        catch (Exception e) { status.Text = JobQueue.Describe(e); }
    }

    void ShowTime() => timeLabel.Text = $"{Editors.Time(position)} / {Editors.Time(duration)}";

    void ShowTrim()
    {
        var end = options.TrimEnd ?? duration;
        trimLabel.Text = options.TrimStart <= 0 && options.TrimEnd is null ? "The whole recording." : $"From {Editors.Time(options.TrimStart)} to {Editors.Time(end)} ({Editors.Time(Math.Max(0, end - options.TrimStart))}).";
    }

    async Task LoadFrame()
    {
        var generation = ++frameGeneration;
        try
        {
            var bytes = await VideoEditEngine.PreviewFrame(video, Math.Min(position, Math.Max(0, duration - 0.05)), 960, default);
            if (generation != frameGeneration || bytes is null) return;
            source = CaptureKit.FromBitmap(Editors.Bitmap(bytes));
            await Draw();
        }
        catch (Exception e) { status.Text = JobQueue.Describe(e); }
    }

    void Change(StudioOptions next)
    {
        options = next;
        drawTimer.Stop();
        drawTimer.Start();
    }

    async Task Draw()
    {
        if (source is not { } frame) return;
        var o = options;
        var t = position;
        var bitmap = await Task.Run(() =>
        {
            var renderer = new StudioRenderer(frame.Width, frame.Height, o with { Shape = o.Shape }, track, duration);
            var output = new BgraImage(renderer.Width, renderer.Height);
            renderer.Render(frame, t, output);
            var cam = renderer.CameraAt(t);
            return (CaptureKit.ToBitmap(output), cam);
        });
        preview.Source = bitmap.Item1;
        status.Text = bitmap.cam.Zoom > 1.01 ? $"Zoomed {bitmap.cam.Zoom:0.0}×" : "";
        Drawn = true;
    }

    void AddZoom()
    {
        var zoom = new StudioZoom(position, Math.Min(duration, position + 2), options.ZoomLevel, focus.X, focus.Y);
        options = options with { Zooms = [.. options.Zooms, zoom] };
        RefreshZooms();
        Change(options);
    }

    void RefreshZooms()
    {
        zoomList.Children.Clear();
        foreach (var z in options.Zooms)
        {
            var row = new DockPanel { Margin = new Thickness(0, 2, 0, 2) };
            var remove = CaptureKit.IconButton("close", "Remove this zoom", () => { options = options with { Zooms = options.Zooms.Where(x => x != z).ToList() }; RefreshZooms(); Change(options); }, 11);
            DockPanel.SetDock(remove, Dock.Right);
            row.Children.Add(remove);
            row.Children.Add(new TextBlock { Text = $"{Editors.Time(z.Start)} – {Editors.Time(z.End)} · {z.Zoom:0.0}×", VerticalAlignment = VerticalAlignment.Center });
            zoomList.Children.Add(row);
        }
    }

    async Task Export()
    {
        if (exporting is not null) { exporting.Cancel(); return; }
        exporting = new CancellationTokenSource();
        exportButton.Content = "Cancel";
        try
        {
            var encoder = await ScreenRecorder.PickEncoder(Settings.Current.RecordEncoder);
            var folder = video.StartsWith(CaptureKit.HistoryFolder, StringComparison.OrdinalIgnoreCase) ? CaptureKit.RecordingFolder : Path.GetDirectoryName(video)!;
            Directory.CreateDirectory(folder);
            var output = OutputPaths.Destination(video, "mp4", "studio", folder);
            var o = options with { Encoder = encoder };
            await VideoStudio.Export(video, track, o, output, p => Dispatcher.BeginInvoke(() => status.Text = $"Exporting… {p:P0}"), exporting.Token);
            status.Text = "Exported";
            var (w, h) = await MediaInfo.FrameSize(output) ?? (0, 0);
            var seconds = (o.TrimEnd ?? duration) - o.TrimStart;
            QuickAccess.Show(new CaptureItem(output, CaptureKind.Recording, w, h, seconds));
        }
        catch (OperationCanceledException) { status.Text = "Export cancelled"; }
        catch (Exception e) { status.Text = JobQueue.Describe(e); }
        finally
        {
            exporting = null;
            exportButton.Content = "Export";
        }
    }
}
