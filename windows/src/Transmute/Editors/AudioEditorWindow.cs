using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using Path = System.Windows.Shapes.Path;
using System.Windows.Threading;

namespace Transmute.App;

/// The audio editor: trim, fades, volume, loudness, channels and bleeps over words, with a
/// waveform to aim at. Drag on the waveform to choose a range.
sealed class AudioEditorWindow : Window
{
    readonly Job job;
    AudioEdit edit = new();
    double duration;
    float[] levels = [];
    (double Start, double End)? selection;
    double? dragFrom;
    readonly Canvas wave = new() { Background = Brushes.Transparent, ClipToBounds = true, Cursor = Cursors.IBeam, Margin = new Thickness(16, 24, 16, 8) };
    readonly TextBlock status = new() { Foreground = Brushes.White, Margin = new Thickness(16, 8, 16, 4) };
    readonly TextBlock selectionLabel = new() { Foreground = Brushes.White, Margin = new Thickness(16, 0, 16, 12) };
    readonly TextBlock trimLabel = new();
    readonly StackPanel bleepList = new();
    readonly MediaPlayer player = new();
    readonly DispatcherTimer playhead = new() { Interval = TimeSpan.FromMilliseconds(50) };
    readonly Line playLine = new() { Stroke = Brushes.White, StrokeThickness = 1.5, Visibility = Visibility.Collapsed, IsHitTestVisible = false };
    readonly Button playButton, saveButton;
    double? stopAt;

    public AudioEditorWindow(Job job)
    {
        this.job = job;
        Ui.SetUpEditorWindow(this, $"Edit {job.Name}");

        var preview = new DockPanel();
        var bottom = new StackPanel();
        bottom.Children.Add(selectionLabel);
        DockPanel.SetDock(status, Dock.Top);
        DockPanel.SetDock(bottom, Dock.Bottom);
        preview.Children.Add(status);
        preview.Children.Add(bottom);
        preview.Children.Add(wave);
        wave.SizeChanged += (_, _) => Draw();
        wave.MouseLeftButtonDown += (_, e) => { dragFrom = TimeAt(e.GetPosition(wave).X); selection = null; wave.CaptureMouse(); Draw(); };
        wave.MouseMove += (_, e) =>
        {
            if (dragFrom is not { } from) return;
            var t = TimeAt(e.GetPosition(wave).X);
            selection = (Math.Min(from, t), Math.Max(from, t));
            Draw();
        };
        wave.MouseLeftButtonUp += (_, e) =>
        {
            if (dragFrom is not { } from) return;
            dragFrom = null;
            wave.ReleaseMouseCapture();
            var t = TimeAt(e.GetPosition(wave).X);
            selection = Math.Abs(t - from) < duration / 400 ? null : (Math.Min(from, t), Math.Max(from, t));
            Draw();
        };

        var controls = new StackPanel();
        playButton = Ui.Button("▶ Play", (_, _) => TogglePlay(), tip: "Plays the selection, or the whole file");
        controls.Children.Add(Ui.Heading("Listen"));
        controls.Children.Add(Ui.Row(playButton));
        controls.Children.Add(Ui.Caption("Plays the original. Drag on the waveform to select a part."));

        controls.Children.Add(Ui.Heading("Trim"));
        controls.Children.Add(Ui.Row(
            Ui.Button("Keep selection", (_, _) => { if (selection is { } s) SetEdit(edit with { TrimStart = s.Start, TrimEnd = s.End >= duration - 0.01 ? null : s.End }); }),
            Ui.Button("Reset", (_, _) => SetEdit(edit with { TrimStart = 0, TrimEnd = null }))));
        controls.Children.Add(trimLabel);

        controls.Children.Add(Ui.Heading("Fades and volume"));
        controls.Children.Add(Ui.Slider("Fade in", 0, 10, 0, v => $"{v:0.0} s", v => SetEdit(edit with { FadeIn = Math.Round(v, 1) }), 0.5).View);
        controls.Children.Add(Ui.Slider("Fade out", 0, 10, 0, v => $"{v:0.0} s", v => SetEdit(edit with { FadeOut = Math.Round(v, 1) }), 0.5).View);
        var (volumeView, volumeSlider) = Ui.Slider("Volume", -20, 20, 0, v => Ui.Signed(v, " dB"), v => SetEdit(edit with { VolumeDb = Math.Round(v, 1) }), 0.5);
        var normalize = new CheckBox { Content = "Even out loudness (−16 LUFS, like podcasts)" };
        normalize.Click += (_, _) => { SetEdit(edit with { Normalize = normalize.IsChecked == true }); volumeSlider.IsEnabled = !edit.Normalize; };
        controls.Children.Add(volumeView);
        controls.Children.Add(normalize);
        controls.Children.Add(Ui.Labelled("Channels", Ui.Combo(Enum.GetValues<ChannelMode>().Select(m => (m.Label(), m)), edit.Channels, m => SetEdit(edit with { Channels = m }))));

        controls.Children.Add(Ui.Heading("Bleep"));
        controls.Children.Add(Ui.Row(Ui.Button("Bleep selection", (_, _) =>
        {
            if (selection is not { } s) return;
            SetEdit(edit with { Bleeps = [.. edit.Bleeps, new BleepRange(s.Start, s.End)] });
        })));
        controls.Children.Add(bleepList);

        controls.Children.Add(Ui.Heading("Save as"));
        controls.Children.Add(Ui.Combo(AudioEditEngine.Formats.Select(f => (f.Label(), f)), AudioEditEngine.FormatFor(edit, job.Path), f => edit = edit with { OutputFormat = f }));
        controls.Children.Add(Ui.Caption("The edited copy is saved next to the original with “edited” in its name."));

        var cancel = Ui.Button("Cancel", (_, _) => Close());
        saveButton = Ui.Button("Save Copy", (_, _) => { Editors.Run(job, new JobOperation.EditAudio(edit)); Close(); }, primary: true);
        Content = Ui.EditorLayout(preview, controls, cancel, saveButton);

        player.MediaFailed += (_, e) => { StopPlaying(); status.Text = "Windows can't play this format, but it can still be edited."; };
        player.MediaEnded += (_, _) => StopPlaying();
        playhead.Tick += (_, _) =>
        {
            var t = player.Position.TotalSeconds;
            if (stopAt is { } end && t >= end) { StopPlaying(); return; }
            ShowPlayhead(t);
        };
        Loaded += async (_, _) => await Load();
        Closed += (_, _) => { player.Stop(); player.Close(); };
        KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) Close();
            if (e.Key == Key.Space && Keyboard.FocusedElement is not TextBox) { TogglePlay(); e.Handled = true; }
        };
        Refresh();
    }

    async Task Load()
    {
        status.Text = "Reading the sound…";
        try
        {
            if (Tools.Ffmpeg is null) throw new ConversionException("ffmpeg is missing, so audio can't be edited. Reinstalling Spinform brings it back.");
            duration = await MediaInfo.Duration(job.Path);
            if (duration <= 0) throw new ConversionException("Couldn't tell how long this recording is.");
            levels = await AudioEditEngine.Waveform(job.Path, 600, default);
            status.Text = $"{Editors.Time(duration)} long";
            Refresh();
        }
        catch (Exception e)
        {
            status.Text = JobQueue.Describe(e);
            saveButton.IsEnabled = false;
        }
    }

    double TimeAt(double x) => wave.ActualWidth <= 0 ? 0 : Math.Clamp(x / wave.ActualWidth, 0, 1) * duration;
    double XAt(double t) => duration <= 0 ? 0 : t / duration * wave.ActualWidth;

    void SetEdit(AudioEdit next)
    {
        edit = next;
        Refresh();
    }

    void Refresh()
    {
        var end = edit.TrimEnd ?? duration;
        trimLabel.Text = duration > 0 ? $"Keeps {Editors.Time(edit.TrimStart)} to {Editors.Time(end)}." : "";
        bleepList.Children.Clear();
        foreach (var bleep in edit.Bleeps)
        {
            var row = new DockPanel { Margin = new Thickness(0, 2, 0, 2) };
            var remove = new Button { Content = "✕", Style = Ui.Res("Flat"), ToolTip = "Remove this bleep" };
            remove.Click += (_, _) => SetEdit(edit with { Bleeps = edit.Bleeps.Where(b => !ReferenceEquals(b, bleep)).ToList() });
            DockPanel.SetDock(remove, Dock.Right);
            row.Children.Add(remove);
            row.Children.Add(Ui.Label($"Bleep {Editors.Time(bleep.Start)} – {Editors.Time(bleep.End)}"));
            bleepList.Children.Add(row);
        }
        if (edit.Bleeps.Count == 0) bleepList.Children.Add(Ui.Caption("Select a word on the waveform, then press Bleep selection."));
        Draw();
    }

    void Draw()
    {
        wave.Children.Clear();
        double w = wave.ActualWidth, h = wave.ActualHeight;
        if (w <= 0 || h <= 0) return;
        var mid = h / 2;
        // Trimmed-away parts are dimmed.
        var keepStart = XAt(edit.TrimStart);
        var keepEnd = XAt(edit.TrimEnd ?? duration);
        if (levels.Length > 0)
        {
            var bar = w / levels.Length;
            var kept = new StreamGeometry();
            var cut = new StreamGeometry();
            using (var k = kept.Open())
            using (var c = cut.Open())
            {
                for (var i = 0; i < levels.Length; i++)
                {
                    var x = i * bar;
                    var half = Math.Max(0.5, levels[i] * mid * 0.95);
                    var ctx = x >= keepStart && x <= keepEnd ? k : c;
                    ctx.BeginFigure(new Point(x, mid - half), true, true);
                    ctx.LineTo(new Point(x + Math.Max(1, bar * 0.7), mid - half), false, false);
                    ctx.LineTo(new Point(x + Math.Max(1, bar * 0.7), mid + half), false, false);
                    ctx.LineTo(new Point(x, mid + half), false, false);
                }
            }
            wave.Children.Add(new Path { Data = kept, Fill = new SolidColorBrush(Color.FromRgb(0x4C, 0xA0, 0xFF)) });
            wave.Children.Add(new Path { Data = cut, Fill = new SolidColorBrush(Color.FromRgb(0x60, 0x60, 0x60)) });
        }
        foreach (var bleep in edit.Bleeps) AddBand(bleep.Start, bleep.End, Color.FromArgb(0x70, 0xFF, 0x3B, 0x30));
        if (selection is { } s) AddBand(s.Start, s.End, Color.FromArgb(0x50, 0xFF, 0xFF, 0xFF));
        if (edit.FadeIn > 0) AddFade(edit.TrimStart, edit.TrimStart + edit.FadeIn, true);
        if (edit.FadeOut > 0) AddFade((edit.TrimEnd ?? duration) - edit.FadeOut, edit.TrimEnd ?? duration, false);
        playLine.Y1 = 0;
        playLine.Y2 = h;
        wave.Children.Add(playLine);
        selectionLabel.Text = selection is { } sel
            ? $"Selected {Editors.Time(sel.Start)} – {Editors.Time(sel.End)} ({Editors.Time(sel.End - sel.Start)})"
            : "Drag on the waveform to select a part.";
    }

    void AddBand(double start, double end, Color color)
    {
        var rect = new Rectangle { Width = Math.Max(1, XAt(end) - XAt(start)), Height = wave.ActualHeight, Fill = new SolidColorBrush(color), IsHitTestVisible = false };
        Canvas.SetLeft(rect, XAt(start));
        wave.Children.Add(rect);
    }

    void AddFade(double start, double end, bool rising)
    {
        double x0 = XAt(start), x1 = XAt(end), h = wave.ActualHeight;
        var line = new Line { X1 = x0, X2 = x1, Y1 = rising ? h : 0, Y2 = rising ? 0 : h, Stroke = Brushes.Orange, StrokeThickness = 2, IsHitTestVisible = false };
        wave.Children.Add(line);
    }

    void ShowPlayhead(double t)
    {
        playLine.X1 = playLine.X2 = XAt(t);
        playLine.Visibility = Visibility.Visible;
    }

    void TogglePlay()
    {
        if (playhead.IsEnabled) { StopPlaying(); return; }
        try
        {
            var (start, end) = selection ?? (edit.TrimStart, edit.TrimEnd ?? duration);
            if (player.Source is null) player.Open(new Uri(job.Path));
            player.Position = TimeSpan.FromSeconds(start);
            stopAt = end;
            player.Play();
            playhead.Start();
            playButton.Content = "■ Stop";
        }
        catch
        {
            status.Text = "Windows can't play this format, but it can still be edited.";
        }
    }

    void StopPlaying()
    {
        player.Pause();
        playhead.Stop();
        playLine.Visibility = Visibility.Collapsed;
        playButton.Content = "▶ Play";
    }
}
