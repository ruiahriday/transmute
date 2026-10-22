using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace Transmute.App;

/// The video editor: trim, split, speed, crop to a shape, turn, flip and sound. Scrubbing shows
/// frames from the video itself, so every format ffmpeg reads works, not only what Windows plays.
sealed class VideoEditorWindow : Window
{
    readonly Job job;
    VideoEdit edit = new();
    double duration;
    double position;
    readonly Image frame = new() { Stretch = Stretch.Uniform, Margin = new Thickness(16) };
    readonly TextBlock status = new() { Foreground = Brushes.White, Margin = new Thickness(12), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Bottom };
    readonly Slider scrub = new() { Minimum = 0, Maximum = 1, Margin = new Thickness(16, 0, 16, 4), IsEnabled = false };
    readonly TextBlock timeLabel = new() { Foreground = Brushes.White, Margin = new Thickness(16, 0, 16, 10) };
    readonly Border trimBand = new() { Height = 6, Background = new SolidColorBrush(Color.FromRgb(0x4C, 0xA0, 0xFF)), HorizontalAlignment = HorizontalAlignment.Left, CornerRadius = new CornerRadius(3) };
    readonly Grid trimTrack = new() { Height = 6, Margin = new Thickness(21, 0, 21, 6), Background = new SolidColorBrush(Color.FromRgb(0x50, 0x50, 0x50)) };
    readonly TextBlock trimLabel = new();
    readonly CheckBox splitBox = new() { Content = "Split into two files at the playhead" };
    readonly TextBlock splitLabel;
    readonly DispatcherTimer frameTimer = new() { Interval = TimeSpan.FromMilliseconds(160) };
    readonly Button saveButton;
    int frameGeneration;

    public VideoEditorWindow(Job job)
    {
        this.job = job;
        Ui.SetUpEditorWindow(this, $"Edit {job.Name}");

        trimTrack.Children.Add(trimBand);
        var preview = new DockPanel();
        var timeline = new StackPanel();
        timeline.Children.Add(trimTrack);
        timeline.Children.Add(scrub);
        timeline.Children.Add(timeLabel);
        DockPanel.SetDock(timeline, Dock.Bottom);
        preview.Children.Add(timeline);
        var picture = new Grid();
        picture.Children.Add(frame);
        picture.Children.Add(status);
        preview.Children.Add(picture);
        scrub.ValueChanged += (_, e) =>
        {
            position = e.NewValue;
            if (splitBox.IsChecked == true) SetSplit(); else ShowTime();
            frameTimer.Stop();
            frameTimer.Start();
        };
        trimTrack.SizeChanged += (_, _) => Refresh();
        frameTimer.Tick += (_, _) => { frameTimer.Stop(); _ = LoadFrame(); };

        var controls = new StackPanel();
        controls.Children.Add(Ui.Heading("Trim"));
        controls.Children.Add(Ui.Row(
            Ui.Button("Start here", (_, _) => SetTrim(position, edit.TrimEnd), tip: "Cut everything before the playhead"),
            Ui.Button("End here", (_, _) => SetTrim(edit.TrimStart, position), tip: "Cut everything after the playhead"),
            Ui.Button("Reset", (_, _) => SetTrim(0, null))));
        controls.Children.Add(trimLabel);
        splitLabel = Ui.Caption("");
        splitBox.Checked += (_, _) => SetSplit();
        splitBox.Unchecked += (_, _) => SetSplit();
        controls.Children.Add(splitBox);
        controls.Children.Add(splitLabel);

        controls.Children.Add(Ui.Heading("Picture"));
        controls.Children.Add(Ui.Labelled("Shape", Ui.Combo(Enum.GetValues<CropAspect>().Select(a => (a.Label(), a)), edit.Crop, a => { edit = edit with { Crop = a }; Refresh(); })));
        controls.Children.Add(Ui.Row(
            Ui.Button("⟲ Left", (_, _) => { edit = edit with { QuarterTurns = edit.QuarterTurns - 1 }; Refresh(); }),
            Ui.Button("⟳ Right", (_, _) => { edit = edit with { QuarterTurns = edit.QuarterTurns + 1 }; Refresh(); }),
            Ui.Button("⇋ Flip", (_, _) => { edit = edit with { FlipHorizontal = !edit.FlipHorizontal }; Refresh(); })));
        controls.Children.Add(Ui.Labelled("Speed", Ui.Combo([("0.25×", 0.25), ("0.5×", 0.5), ("0.75×", 0.75), ("Normal", 1.0), ("1.25×", 1.25), ("1.5×", 1.5), ("2×", 2.0), ("4×", 4.0)], 1.0, s => { edit = edit with { Speed = s }; Refresh(); })));

        controls.Children.Add(Ui.Heading("Sound"));
        var (volumeView, volumeSlider) = Ui.Slider("Volume", 0, 2, 1, Ui.Percent, v => edit = edit with { Volume = Math.Round(v, 2) });
        var mute = new CheckBox { Content = "Remove the sound" };
        mute.Click += (_, _) => { edit = edit with { Mute = mute.IsChecked == true }; volumeSlider.IsEnabled = !edit.Mute; };
        controls.Children.Add(mute);
        controls.Children.Add(volumeView);

        controls.Children.Add(Ui.Heading("Still picture"));
        controls.Children.Add(Ui.Row(Ui.Button("Save frame as PNG", (_, _) => Editors.Run(job, new JobOperation.Snapshot(position)), tip: "Saves the frame at the playhead next to the video")));

        controls.Children.Add(Ui.Heading("Save as"));
        controls.Children.Add(Ui.Combo(VideoEditEngine.Formats.Select(f => (f.Label(), f)), VideoEditEngine.FormatFor(edit, job.Path), f => edit = edit with { OutputFormat = f }));
        controls.Children.Add(Ui.Caption("The edited copy is saved next to the original with “edited” in its name."));

        var cancel = Ui.Button("Cancel", (_, _) => Close());
        saveButton = Ui.Button("Save Copy", (_, _) => { Editors.Run(job, new JobOperation.EditVideo(edit)); Close(); }, primary: true);
        Content = Ui.EditorLayout(preview, controls, cancel, saveButton);
        Loaded += async (_, _) => await Load();
        KeyDown += OnKey;
        Refresh();
    }

    async Task Load()
    {
        status.Text = "Loading…";
        try
        {
            if (Tools.Ffmpeg is null) throw new ConversionException("ffmpeg is missing, so videos can't be edited. Reinstalling Spinform brings it back.");
            duration = await MediaInfo.Duration(job.Path);
            if (duration <= 0) throw new ConversionException("Couldn't tell how long this video is.");
            scrub.Maximum = duration;
            scrub.SmallChange = Math.Min(1, duration / 100);
            scrub.LargeChange = Math.Max(1, duration / 20);
            scrub.IsEnabled = true;
            Refresh();
            await LoadFrame();
        }
        catch (Exception e)
        {
            status.Text = JobQueue.Describe(e);
            saveButton.IsEnabled = false;
        }
    }

    async Task LoadFrame()
    {
        var generation = ++frameGeneration;
        var at = position;
        try
        {
            var bytes = await VideoEditEngine.PreviewFrame(job.Path, Math.Min(at, Math.Max(0, duration - 0.05)), 960, default);
            if (generation != frameGeneration || bytes is null) return;
            frame.Source = Editors.Bitmap(bytes);
            ApplyPreviewTransform();
            status.Text = "";
        }
        catch (Exception e)
        {
            if (generation == frameGeneration) status.Text = JobQueue.Describe(e);
        }
    }

    void ApplyPreviewTransform()
    {
        var group = new TransformGroup();
        group.Children.Add(new ScaleTransform(edit.FlipHorizontal ? -1 : 1, 1));
        group.Children.Add(new RotateTransform(((edit.QuarterTurns % 4) + 4) % 4 * 90));
        frame.LayoutTransform = group;
    }

    void OnKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape) Close();
        if (Keyboard.FocusedElement is TextBox) return;
        var step = Keyboard.Modifiers == ModifierKeys.Shift ? 1.0 : 1.0 / 25;
        if (e.Key == Key.Left) { scrub.Value = Math.Max(0, scrub.Value - step); e.Handled = true; }
        if (e.Key == Key.Right) { scrub.Value = Math.Min(duration, scrub.Value + step); e.Handled = true; }
        if (e.Key == Key.I) SetTrim(position, edit.TrimEnd);
        if (e.Key == Key.O) SetTrim(edit.TrimStart, position);
    }

    void SetTrim(double start, double? end)
    {
        if (end is { } e && e <= start + 0.1)
        {
            if (start == edit.TrimStart) end = null; else start = 0;
        }
        edit = edit with { TrimStart = Math.Max(0, start), TrimEnd = end is { } x && x >= duration - 0.01 ? null : end };
        SetSplit();
    }

    void SetSplit()
    {
        var end = edit.TrimEnd ?? duration;
        var inside = position > edit.TrimStart + 0.1 && position < end - 0.1;
        edit = edit with { SplitAt = splitBox.IsChecked == true && inside ? position : null };
        Refresh();
    }

    void ShowTime() => timeLabel.Text = $"{Editors.Time(position)} / {Editors.Time(duration)}   ←/→ step a frame, Shift for a second · I and O set start and end";

    void Refresh()
    {
        var end = edit.TrimEnd ?? duration;
        var length = Math.Max(0, end - edit.TrimStart) / Math.Max(edit.Speed, 0.01);
        trimLabel.Text = duration > 0
            ? $"Keeps {Editors.Time(edit.TrimStart)} to {Editors.Time(end)}, {Editors.Time(length)} long{(edit.Speed != 1 ? " at this speed" : "")}."
            : "";
        splitLabel.Text = splitBox.IsChecked == true
            ? edit.SplitAt is { } at ? $"Two files: before and after {Editors.Time(at)}." : "Move the playhead inside the trimmed part to split there."
            : "";
        if (trimTrack.ActualWidth > 0 && duration > 0)
        {
            trimBand.Margin = new Thickness(trimTrack.ActualWidth * edit.TrimStart / duration, 0, 0, 0);
            trimBand.Width = Math.Max(2, trimTrack.ActualWidth * (end - edit.TrimStart) / duration);
        }
        ShowTime();
        ApplyPreviewTransform();
    }
}
