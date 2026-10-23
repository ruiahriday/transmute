using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ImageMagick;
using Microsoft.Win32;

namespace Transmute.App;

/// The Background controls, shared by the photo editor and the Change Background window:
/// keep, remove, or put a colour, gradient, blur or picture behind the subject.
sealed class BackgroundPanel : StackPanel
{
    BackgroundEdit edit;
    BackgroundMode mode;
    readonly bool offerKeep;
    readonly StackPanel options = new();
    readonly Action<BackgroundEdit?> changed;
    readonly Dictionary<BackgroundMode, RadioButton> tiles = [];

    public BackgroundMode Mode => mode;

    /// The current choice, or null when the background is kept.
    public BackgroundEdit? Current => mode == BackgroundMode.Keep ? null : edit with { Mode = mode };

    public BackgroundPanel(BackgroundMode initial, bool offerKeep, Action<BackgroundEdit?> changed)
    {
        this.offerKeep = offerKeep;
        this.changed = changed;
        mode = initial;
        edit = new BackgroundEdit { Mode = initial == BackgroundMode.Keep ? BackgroundMode.Remove : initial };

        var tiles = new UniformGrid { Columns = 3, Margin = new Thickness(0, 2, -6, 0) };
        var choices = new List<(BackgroundMode Mode, string Icon, string Label)>();
        if (offerKeep) choices.Add((BackgroundMode.Keep, "image", "Keep"));
        choices.AddRange([(BackgroundMode.Remove, "cutout", "Remove"), (BackgroundMode.Color, "palette", "Colour"),
            (BackgroundMode.Gradient, "layers", "Gradient"), (BackgroundMode.Blur, "search", "Blur"), (BackgroundMode.Picture, "image", "Picture")]);
        var group = "background" + Guid.NewGuid().ToString("N");
        foreach (var (m, icon, label) in choices)
        {
            var content = new StackPanel();
            var glyph = Icons.Make(icon, 18);
            glyph.HorizontalAlignment = HorizontalAlignment.Center;
            glyph.Margin = new Thickness(0, 0, 0, 3);
            content.Children.Add(glyph);
            content.Children.Add(new TextBlock { Text = label, FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center });
            var tile = new RadioButton { Style = Ui.Res("Tile"), GroupName = group, Content = content, IsChecked = m == mode, ToolTip = Describe(m) };
            tile.Checked += (_, _) => { mode = m; BuildOptions(); Notify(); };
            this.tiles[m] = tile;
            tiles.Children.Add(tile);
        }
        Children.Add(tiles);
        Children.Add(options);
        if (!Backgrounds.IsAvailable)
            Children.Add(new TextBlock { Text = "The background model is missing from this copy of Spinform. Reinstalling brings it back.", Style = Ui.Res("Caption"), Foreground = Ui.Brush("Danger"), Margin = new Thickness(0, 6, 0, 0) });
        BuildOptions();
        // Load the network while the person chooses, so the first preview comes sooner.
        Task.Run(Backgrounds.Warm);
    }

    /// Picks a mode as if its tile was clicked; a gradient preset or colour can come with it.
    public void Choose(BackgroundMode next, GradientPreset? gradient = null, Rgba? color = null)
    {
        if (gradient is { } g) edit = edit with { GradientFrom = g.From, GradientTo = g.To, GradientAngle = g.Angle };
        if (color is { } c) edit = edit with { Color = c };
        if (tiles.TryGetValue(next, out var tile))
        {
            if (tile.IsChecked == true) { BuildOptions(); Notify(); }
            else tile.IsChecked = true;
        }
    }

    static string Describe(BackgroundMode m) => m switch
    {
        BackgroundMode.Keep => "Leave the background as it is",
        BackgroundMode.Remove => "Cut out the subject; the background becomes see-through (saved as PNG)",
        BackgroundMode.Color => "Put a plain colour behind the subject",
        BackgroundMode.Gradient => "Put a gradient behind the subject",
        BackgroundMode.Blur => "Blur the original background, like a portrait photo",
        _ => "Put another picture behind the subject",
    };

    void Notify() => changed(Current);

    void Set(BackgroundEdit next, bool rebuild = false)
    {
        edit = next;
        if (rebuild) BuildOptions();
        Notify();
    }

    void BuildOptions()
    {
        options.Children.Clear();
        options.Margin = new Thickness(0, 4, 0, 0);
        switch (mode)
        {
            case BackgroundMode.Keep:
                options.Children.Add(Ui.Caption("Choose Remove to cut out the subject, or put something new behind it."));
                return;
            case BackgroundMode.Remove:
                options.Children.Add(Ui.Caption("Spinform finds the subject on this PC (nothing is uploaded) and makes everything else see-through."));
                break;
            case BackgroundMode.Color:
            {
                var swatches = new WrapPanel { Margin = new Thickness(0, 2, 0, 4) };
                foreach (var (name, color) in Backgrounds.Colors)
                    swatches.Children.Add(Swatch(new SolidColorBrush(ToColor(color)), name, edit.Color == color, () => Set(edit with { Color = color }, true)));
                var isCustom = !Backgrounds.Colors.Any(c => c.Color == edit.Color);
                swatches.Children.Add(Swatch(new SolidColorBrush(ToColor(edit.Color)), "Custom colour…", isCustom, () =>
                {
                    if (PickColor(edit.Color) is { } picked) Set(edit with { Color = picked }, true);
                }, custom: true));
                options.Children.Add(swatches);
                break;
            }
            case BackgroundMode.Gradient:
            {
                var presets = new WrapPanel { Margin = new Thickness(0, 2, 0, 4) };
                foreach (var preset in Backgrounds.Gradients)
                {
                    var selected = edit.GradientFrom == preset.From && edit.GradientTo == preset.To;
                    presets.Children.Add(Swatch(GradientBrush(preset.From, preset.To, preset.Angle), preset.Name, selected,
                        () => Set(edit with { GradientFrom = preset.From, GradientTo = preset.To, GradientAngle = preset.Angle }, true)));
                }
                options.Children.Add(presets);
                var from = ColorButton("From", edit.GradientFrom, c => Set(edit with { GradientFrom = c }, true));
                var to = ColorButton("To", edit.GradientTo, c => Set(edit with { GradientTo = c }, true));
                options.Children.Add(Ui.Row(from, to));
                options.Children.Add(Ui.Slider("Angle", 0, 360, edit.GradientAngle, v => $"{v:0}°", v => Set(edit with { GradientAngle = Math.Round(v) }), 15).View);
                break;
            }
            case BackgroundMode.Blur:
                options.Children.Add(Ui.Slider("Strength", 0.1, 1, edit.BlurAmount, Ui.Percent, v => Set(edit with { BlurAmount = Math.Round(v, 2) })).View);
                break;
            case BackgroundMode.Picture:
            {
                var name = edit.PicturePath is { } p ? System.IO.Path.GetFileName(p) : "No picture chosen";
                options.Children.Add(Ui.Row(Ui.Button("Choose Picture…", (_, _) =>
                {
                    var dialog = new OpenFileDialog { Title = "Picture to put behind the subject", Filter = "Pictures|*.jpg;*.jpeg;*.png;*.webp;*.bmp;*.tif;*.tiff;*.gif;*.heic;*.heif;*.avif|All files|*.*" };
                    if (dialog.ShowDialog(Window.GetWindow(this)) == true) Set(edit with { PicturePath = dialog.FileName }, true);
                })));
                options.Children.Add(Ui.Caption($"{name}. It's scaled to fill the frame."));
                break;
            }
        }
        options.Children.Add(Ui.Slider("Edge", 0, 1, edit.Softness, v => v < 0.15 ? "Sharp" : v > 0.7 ? "Soft" : "Medium", v => Set(edit with { Softness = Math.Round(v, 2) })).View);
    }

    static Color ToColor(Rgba c) => Color.FromRgb((byte)Math.Round(c.R * 255), (byte)Math.Round(c.G * 255), (byte)Math.Round(c.B * 255));
    static Rgba FromColor(System.Drawing.Color c) => new(c.R / 255.0, c.G / 255.0, c.B / 255.0);

    static LinearGradientBrush GradientBrush(Rgba from, Rgba to, double angle)
    {
        var r = angle * Math.PI / 180;
        double dx = Math.Cos(r) / 2, dy = Math.Sin(r) / 2;
        return new LinearGradientBrush(ToColor(from), ToColor(to), new Point(0.5 - dx, 0.5 - dy), new Point(0.5 + dx, 0.5 + dy));
    }

    static Rgba? PickColor(Rgba start)
    {
        using var dialog = new System.Windows.Forms.ColorDialog { FullOpen = true, Color = System.Drawing.Color.FromArgb(ToColor(start).R, ToColor(start).G, ToColor(start).B) };
        return dialog.ShowDialog() == System.Windows.Forms.DialogResult.OK ? FromColor(dialog.Color) : null;
    }

    static FrameworkElement Swatch(Brush fill, string name, bool selected, Action pick, bool custom = false)
    {
        var inner = new Border { CornerRadius = new CornerRadius(4), Background = fill, BorderBrush = new SolidColorBrush(Color.FromArgb(0x30, 0, 0, 0)), BorderThickness = new Thickness(1) };
        if (custom)
        {
            // Custom: the chosen colour on the left, a + on a light tile on the right.
            var split = new Grid();
            split.ColumnDefinitions.Add(new ColumnDefinition());
            split.ColumnDefinitions.Add(new ColumnDefinition());
            var plus = new Border { Background = Ui.Brush("Subtle"), CornerRadius = new CornerRadius(0, 3, 3, 0), Child = Icons.Make("add", 10, Ui.Brush("Ink"), 2.4) };
            Grid.SetColumn(plus, 1);
            split.Children.Add(new Border { Background = fill, CornerRadius = new CornerRadius(3, 0, 0, 3) });
            split.Children.Add(plus);
            inner.Background = Brushes.Transparent;
            inner.Child = split;
        }
        var chip = new Border
        {
            Width = 32, Height = 32, Padding = new Thickness(2), CornerRadius = new CornerRadius(6), Margin = new Thickness(0, 0, 6, 6), Cursor = Cursors.Hand,
            BorderBrush = selected ? Ui.Brush("Accent") : Brushes.Transparent, BorderThickness = new Thickness(2), Child = inner, ToolTip = name,
            Background = Brushes.Transparent, SnapsToDevicePixels = true,
        };
        chip.MouseEnter += (_, _) => { if (!selected) chip.BorderBrush = Ui.Brush("LineStrong"); };
        chip.MouseLeave += (_, _) => { if (!selected) chip.BorderBrush = Brushes.Transparent; };
        chip.MouseLeftButtonUp += (_, _) => pick();
        return chip;
    }

    static Button ColorButton(string label, Rgba color, Action<Rgba> picked)
    {
        var dot = new Border { Width = 14, Height = 14, CornerRadius = new CornerRadius(3), Background = new SolidColorBrush(ToColor(color)), BorderBrush = new SolidColorBrush(Color.FromArgb(0x40, 0, 0, 0)), BorderThickness = new Thickness(1), Margin = new Thickness(0, 0, 7, 0) };
        var content = new StackPanel { Orientation = Orientation.Horizontal };
        content.Children.Add(dot);
        content.Children.Add(new TextBlock { Text = $"{label}…", VerticalAlignment = VerticalAlignment.Center });
        return Ui.Button("", (_, _) => { if (PickColor(color) is { } c) picked(c); }, contentOverride: content);
    }

    /// A light checkerboard to show see-through parts, tiles `size` units wide.
    public static DrawingBrush Checkerboard(double size)
    {
        var group = new DrawingGroup();
        group.Children.Add(new GeometryDrawing(Brushes.White, null, new RectangleGeometry(new Rect(0, 0, 2, 2))));
        var grey = new SolidColorBrush(Color.FromRgb(0xE2, 0xE2, 0xE2));
        group.Children.Add(new GeometryDrawing(grey, null, new RectangleGeometry(new Rect(0, 0, 1, 1))));
        group.Children.Add(new GeometryDrawing(grey, null, new RectangleGeometry(new Rect(1, 1, 1, 1))));
        var brush = new DrawingBrush(group) { TileMode = TileMode.Tile, Viewport = new Rect(0, 0, size * 2, size * 2), ViewportUnits = BrushMappingMode.Absolute, Stretch = Stretch.Fill };
        brush.Freeze();
        return brush;
    }
}

/// Change Background for many pictures at once: a preview of the first one, the Background
/// controls, and Apply, which saves a copy of each picture.
sealed class BackgroundWindow : Window
{
    readonly List<Job> jobs;
    readonly Image picture = new() { Stretch = Stretch.Uniform };
    readonly Border checker = new();
    readonly TextBlock status = new() { Foreground = Brushes.White, Margin = new Thickness(14, 10, 14, 12), VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Left };
    readonly System.Windows.Threading.DispatcherTimer renderTimer = new() { Interval = TimeSpan.FromMilliseconds(150) };
    readonly BackgroundPanel panel;
    string? previewSource;
    int generation;
    public bool Rendered { get; private set; }

    public static BackgroundWindow Open(List<Job> jobs, Window? owner)
    {
        var window = new BackgroundWindow(jobs);
        if (owner is not null) window.Owner = owner;
        else window.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        window.Show();
        window.Activate();
        return window;
    }

    BackgroundWindow(List<Job> jobs)
    {
        this.jobs = jobs;
        Ui.SetUpEditorWindow(this, jobs.Count == 1 ? $"Background of {jobs[0].Name}" : $"Background of {jobs.Count} pictures");
        Width = 980;
        Height = 680;
        panel = new BackgroundPanel(BackgroundMode.Color, false, _ => { renderTimer.Stop(); renderTimer.Start(); });

        var stage = new Grid { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        stage.Children.Add(checker);
        stage.Children.Add(picture);
        var previewArea = new Grid();
        previewArea.Children.Add(new Viewbox { Child = stage, Stretch = Stretch.Uniform, StretchDirection = StretchDirection.DownOnly, Margin = new Thickness(24) });
        previewArea.Children.Add(status);

        var controls = new StackPanel();
        controls.Children.Add(Ui.Heading("Background"));
        controls.Children.Add(panel);
        controls.Children.Add(Ui.Heading("Pictures"));
        controls.Children.Add(Ui.Caption(jobs.Count == 1
            ? $"{jobs[0].Name} is saved as a copy with “background” in its name."
            : $"All {jobs.Count} pictures get the same background; the preview shows the first. Each is saved as a copy with “background” in its name."));

        var cancel = Ui.Button("Cancel", (_, _) => Close());
        var apply = Ui.Button(jobs.Count == 1 ? "Save Copy" : $"Apply to {jobs.Count} Pictures", (_, _) => Apply(), primary: true);
        apply.IsDefault = true;
        Content = Ui.EditorLayout(previewArea, controls, cancel, apply);
        renderTimer.Tick += (_, _) => { renderTimer.Stop(); _ = Render(); };
        Loaded += async (_, _) => await Load();
        Closed += (_, _) => OutputPaths.TryDelete(previewSource);
        KeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); };
    }

    async Task Load()
    {
        status.Text = "Loading…";
        try
        {
            var path = jobs[0].Path;
            var (temp, w, h) = await Task.Run(() =>
            {
                using var image = ImageConverter.LoadFirst(path);
                if (Math.Max(image.Width, image.Height) > 1400) image.Resize(new MagickGeometry(1400, 1400) { Greater = true });
                var file = OutputPaths.TempFile("png");
                image.Write(file, MagickFormat.Png);
                return (file, (int)image.Width, (int)image.Height);
            });
            previewSource = temp;
            checker.Width = picture.Width = w;
            checker.Height = picture.Height = h;
            checker.Background = BackgroundPanel.Checkerboard(Math.Max(8, Math.Max(w, h) / 50.0));
            await Render();
        }
        catch (Exception e)
        {
            status.Text = $"Couldn't open the picture: {JobQueue.Describe(e)}";
        }
    }

    async Task Render()
    {
        if (previewSource is null || panel.Current is not { } edit) return;
        var mine = ++generation;
        var source = previewSource;
        status.Text = "Finding the subject…";
        try
        {
            var bitmap = await Task.Run(() =>
            {
                using var original = new MagickImage(source);
                using var result = Backgrounds.Apply(original, source, edit);
                return Editors.Pixels(result);
            });
            if (mine != generation) return;
            picture.Source = bitmap;
            status.Text = jobs.Count == 1 ? jobs[0].Name : $"{jobs[0].Name} (1 of {jobs.Count})";
            Rendered = true;
        }
        catch (Exception e)
        {
            if (mine == generation) status.Text = JobQueue.Describe(e);
        }
    }

    void Apply()
    {
        if (panel.Current is not { } edit) return;
        _ = JobQueue.Shared.Start(jobs.Select(j => (j, (JobOperation)new JobOperation.Background(edit))).ToList(), Settings.Current.RevealWhenDone);
        Close();
    }
}
