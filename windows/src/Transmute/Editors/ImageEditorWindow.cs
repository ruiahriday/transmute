using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using Path = System.Windows.Shapes.Path;
using System.Windows.Threading;
using ImageMagick;

namespace Transmute.App;

/// The photo editor: crop, turn, flip, colour, remove or replace the background, blur or black out
/// parts, and draw arrows, boxes, highlights and text. Saves an edited copy next to the original.
sealed class ImageEditorWindow : Window
{
    enum Tool { Crop, Redact, Annotate }

    readonly Job job;
    ImageEdit edit = new();
    string? previewSource;
    Tool tool = Tool.Annotate;
    RedactionStyle redactionStyle = RedactionStyle.Blackout;
    AnnotationKind annotationKind = AnnotationKind.Arrow;
    Rgba color = Rgba.Red;
    double sizeLevel = 4; // 1…10, as on the Mac: text 1.2% of the picture's height per step, lines 0.2%
    string annotationText = "Text";
    readonly List<object> history = []; // redactions and annotations, newest last, for Undo

    // Preview: the picture with marks and colours applied; crop, turns and flips are shown with
    // WPF transforms so the marks keep the original's coordinates.
    readonly Image picture = new() { Stretch = Stretch.Fill };
    readonly Border checker = new() { Visibility = Visibility.Collapsed };
    readonly Canvas overlay = new() { Background = Brushes.Transparent, ClipToBounds = true };
    readonly Grid stage = new();
    readonly Viewbox viewbox = new() { Stretch = Stretch.Uniform, Margin = new Thickness(20) };
    readonly TextBlock status = new() { Foreground = Brushes.White, Margin = new Thickness(12), VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Left };
    readonly Rectangle rubber = new() { Stroke = Brushes.White, StrokeDashArray = [4, 3], StrokeThickness = 1.5, Visibility = Visibility.Collapsed, Fill = new SolidColorBrush(Color.FromArgb(0x30, 0xFF, 0xFF, 0xFF)) };
    readonly Path cropShade = new() { Fill = new SolidColorBrush(Color.FromArgb(0x99, 0, 0, 0)), IsHitTestVisible = false };
    readonly DispatcherTimer renderTimer = new() { Interval = TimeSpan.FromMilliseconds(120) };
    Point? dragFrom;
    int pixelWidth = 1, pixelHeight = 1;
    int renderGeneration;
    /// Whether the last preview had the background changed (for the smoke test).
    public bool RenderedBackground { get; private set; }
    public int RenderCount { get; private set; }

    public void BringIntoViewBackground() => backgroundPanel.BringIntoView();
    readonly StackPanel toolOptions = new();
    readonly ComboBox formatBox;
    readonly BackgroundPanel backgroundPanel;
    readonly Button undoButton;

    public ImageEditorWindow(Job job)
    {
        this.job = job;
        Ui.SetUpEditorWindow(this, $"Edit {job.Name}");

        stage.Children.Add(checker);
        stage.Children.Add(picture);
        stage.Children.Add(overlay);
        overlay.Children.Add(cropShade);
        overlay.Children.Add(rubber);
        viewbox.Child = stage;
        var previewArea = new Grid();
        previewArea.Children.Add(viewbox);
        previewArea.Children.Add(status);
        overlay.MouseLeftButtonDown += OnDown;
        overlay.MouseMove += OnMove;
        overlay.MouseLeftButtonUp += OnUp;
        overlay.Cursor = Cursors.Cross;

        var controls = new StackPanel();
        controls.Children.Add(Ui.Heading("Turn and flip"));
        controls.Children.Add(Ui.Row(
            Ui.Button("Left", (_, _) => Update(edit with { QuarterTurns = edit.QuarterTurns - 1 }), icon: "rotateleft", tip: "Turn left"),
            Ui.Button("Right", (_, _) => Update(edit with { QuarterTurns = edit.QuarterTurns + 1 }), icon: "rotateright", tip: "Turn right"),
            Ui.Button("Flip", (_, _) => Update(edit with { FlipHorizontal = !edit.FlipHorizontal }), icon: "fliph", tip: "Flip left to right"),
            Ui.Button("Flip", (_, _) => Update(edit with { FlipVertical = !edit.FlipVertical }), icon: "flipv", tip: "Flip upside down")));

        controls.Children.Add(Ui.Heading("Colour"));
        var sliders = new List<Slider>();
        void AddSlider(string title, double min, double max, double value, Func<double, string> format, Func<double, ImageEdit> apply)
        {
            var (view, slider) = Ui.Slider(title, min, max, value, format, v => Update(apply(v)));
            sliders.Add(slider);
            controls.Children.Add(view);
        }
        AddSlider("Exposure", -2, 2, 0, v => Ui.Signed(v), v => edit with { Exposure = Math.Round(v, 2) });
        AddSlider("Brightness", -0.5, 0.5, 0, v => Ui.Signed(v * 100, "%").Replace(".0", ""), v => edit with { Brightness = Math.Round(v, 3) });
        AddSlider("Contrast", 0.5, 2, 1, Ui.Percent, v => edit with { Contrast = Math.Round(v, 3) });
        AddSlider("Saturation", 0, 2, 1, Ui.Percent, v => edit with { Saturation = Math.Round(v, 3) });
        controls.Children.Add(Ui.Row(Ui.Button("Reset colours", (_, _) =>
        {
            sliders[0].Value = 0; sliders[1].Value = 0; sliders[2].Value = 1; sliders[3].Value = 1;
        })));

        controls.Children.Add(Ui.Heading("Background"));
        backgroundPanel = new BackgroundPanel(BackgroundMode.Keep, true, background =>
        {
            Update(edit with { Background = background });
            // A see-through background needs a format that keeps it.
            if (background is { KeepsTransparency: true } && formatBox?.SelectedItem is ComboBoxItem { Tag: OutputFormat f } && !Backgrounds.HoldsTransparency(f))
                SelectFormat(OutputFormat.Png);
        });
        controls.Children.Add(backgroundPanel);

        controls.Children.Add(Ui.Heading("Draw on the picture"));
        var toolBox = Ui.Combo([("Arrows, boxes and text", Tool.Annotate), ("Hide something", Tool.Redact), ("Crop", Tool.Crop)], tool, t => { tool = t; BuildToolOptions(); });
        controls.Children.Add(toolBox);
        controls.Children.Add(toolOptions);
        undoButton = Ui.Button("Undo last mark", (_, _) => Undo());
        controls.Children.Add(Ui.Row(undoButton, Ui.Button("Clear marks", (_, _) => { history.Clear(); Update(edit with { Redactions = [], Annotations = [] }); })));

        controls.Children.Add(Ui.Heading("Save as"));
        var current = ImageEditEngine.FormatFor(edit, job.Path);
        var formats = ImageEditEngine.Formats.Where(f => f != OutputFormat.Heic || ImageConverter.CanWriteHeic).ToList();
        formatBox = Ui.Combo(formats.Select(f => (f.Label(), f)), current, f => edit = edit with { OutputFormat = f });
        controls.Children.Add(formatBox);
        controls.Children.Add(Ui.Caption("The edited copy is saved next to the original with “edited” in its name."));

        var cancel = Ui.Button("Cancel", (_, _) => Close());
        var save = Ui.Button("Save Copy", (_, _) => Save(), primary: true);
        save.IsDefault = true;
        Content = Ui.EditorLayout(previewArea, controls, cancel, save);
        BuildToolOptions();
        renderTimer.Tick += (_, _) => { renderTimer.Stop(); _ = Render(); };
        Loaded += async (_, _) => await LoadPreview();
        Closed += (_, _) => OutputPaths.TryDelete(previewSource);
        KeyDown += (_, e) =>
        {
            if (e.Key == Key.Z && Keyboard.Modifiers == ModifierKeys.Control) Undo();
            if (e.Key == Key.Escape) Close();
        };
    }

    void SelectFormat(OutputFormat format)
    {
        foreach (ComboBoxItem item in formatBox.Items)
            if (item.Tag is OutputFormat f && f == format) { formatBox.SelectedItem = item; break; }
    }

    /// Shows the Background section with a choice made (for the smoke test).
    public BackgroundPanel BackgroundControls => backgroundPanel;

    void BuildToolOptions()
    {
        toolOptions.Children.Clear();
        toolOptions.Margin = new Thickness(0, 6, 0, 6);
        switch (tool)
        {
            case Tool.Crop:
                toolOptions.Children.Add(Ui.Caption("Drag across the picture to choose what to keep."));
                toolOptions.Children.Add(Ui.Row(Ui.Button("Reset crop", (_, _) => Update(edit with { Crop = null }))));
                break;
            case Tool.Redact:
                toolOptions.Children.Add(Ui.Labelled("Style", Ui.Combo([("Black box", RedactionStyle.Blackout), ("Pixelate", RedactionStyle.Pixelate), ("Blur", RedactionStyle.Blur)], redactionStyle, s => redactionStyle = s)));
                toolOptions.Children.Add(Ui.Caption("Drag across faces, names or numbers to hide them."));
                break;
            case Tool.Annotate:
                toolOptions.Children.Add(Ui.Labelled("Mark", Ui.Combo([("Arrow", AnnotationKind.Arrow), ("Box", AnnotationKind.Rectangle), ("Highlight", AnnotationKind.Highlight), ("Text", AnnotationKind.Text)], annotationKind, k => { annotationKind = k; BuildToolOptions(); })));
                var swatches = new WrapPanel { Margin = new Thickness(92, 4, 0, 4) };
                foreach (var swatch in Rgba.Swatches)
                {
                    var chip = new Border
                    {
                        Width = 22, Height = 22, CornerRadius = new CornerRadius(11), Margin = new Thickness(0, 0, 6, 0), Cursor = Cursors.Hand,
                        Background = new SolidColorBrush(Color.FromRgb((byte)(swatch.R * 255), (byte)(swatch.G * 255), (byte)(swatch.B * 255))),
                        BorderBrush = swatch == color ? Ui.Brush("Accent") : Brushes.Gray,
                        BorderThickness = new Thickness(swatch == color ? 3 : 1),
                    };
                    chip.MouseLeftButtonUp += (_, _) => { color = swatch; BuildToolOptions(); };
                    swatches.Children.Add(chip);
                }
                toolOptions.Children.Add(swatches);
                toolOptions.Children.Add(Ui.Slider("Size", 1, 10, sizeLevel, v => $"{v:0}", v => sizeLevel = v, 1).View);
                if (annotationKind == AnnotationKind.Text)
                {
                    var text = new TextBox { Text = annotationText };
                    text.TextChanged += (_, _) => annotationText = text.Text;
                    toolOptions.Children.Add(Ui.Labelled("Text", text));
                    toolOptions.Children.Add(Ui.Caption("Click where the text should go."));
                }
                else toolOptions.Children.Add(Ui.Caption("Drag on the picture to draw."));
                break;
        }
    }

    async Task LoadPreview()
    {
        status.Text = "Loading…";
        try
        {
            // Edit a smaller copy for the preview so sliders stay quick on big photos.
            var (path, width, height) = await Task.Run(() =>
            {
                using var image = ImageConverter.LoadFirst(job.Path);
                var (w, h) = ((int)image.Width, (int)image.Height);
                if (Math.Max(w, h) > 1600) image.Resize(new MagickGeometry(1600, 1600) { Greater = true });
                var temp = OutputPaths.TempFile("png");
                image.Write(temp, MagickFormat.Png);
                return (temp, w, h);
            });
            previewSource = path;
            (pixelWidth, pixelHeight) = (width, height);
            stage.Width = width > height ? 1600 : 1600.0 * width / height;
            stage.Height = width > height ? 1600.0 * height / width : 1600;
            checker.Background = BackgroundPanel.Checkerboard(32);
            await Render();
        }
        catch (Exception e)
        {
            status.Text = $"Couldn't open the picture: {JobQueue.Describe(e)}";
        }
    }

    void Update(ImageEdit next)
    {
        edit = next;
        ApplyTransforms();
        DrawCrop();
        undoButton.IsEnabled = history.Count > 0;
        renderTimer.Stop();
        renderTimer.Start();
    }

    void Undo()
    {
        if (history.Count == 0) return;
        var last = history[^1];
        history.RemoveAt(history.Count - 1);
        Update(last switch
        {
            Redaction r => edit with { Redactions = edit.Redactions.Where(x => !ReferenceEquals(x, r)).ToList() },
            Annotation a => edit with { Annotations = edit.Annotations.Where(x => !ReferenceEquals(x, a)).ToList() },
            _ => edit,
        });
    }

    async Task Render()
    {
        if (previewSource is null) return;
        var generation = ++renderGeneration;
        // Marks and colours only; the crop and turns are shown by the preview itself.
        var previewEdit = edit with { Crop = null, QuarterTurns = 0, FlipHorizontal = false, FlipVertical = false };
        var source = previewSource;
        var background = previewEdit.Background is { Mode: not BackgroundMode.Keep };
        if (background) status.Text = "Finding the subject…";
        try
        {
            var bitmap = await Task.Run(() =>
            {
                using var image = ImageEditEngine.Render(source, previewEdit);
                return Editors.Pixels(image);
            });
            if (generation != renderGeneration) return;
            picture.Source = bitmap;
            checker.Visibility = previewEdit.Background is { KeepsTransparency: true } ? Visibility.Visible : Visibility.Collapsed;
            status.Text = $"{pixelWidth} × {pixelHeight}";
            RenderedBackground = background;
            RenderCount++;
        }
        catch (Exception e)
        {
            status.Text = JobQueue.Describe(e);
        }
    }

    void ApplyTransforms()
    {
        var group = new TransformGroup();
        group.Children.Add(new ScaleTransform(edit.FlipHorizontal ? -1 : 1, edit.FlipVertical ? -1 : 1));
        group.Children.Add(new RotateTransform(edit.Turns * 90));
        stage.LayoutTransform = group;
        stage.RenderTransformOrigin = new Point(0.5, 0.5);
    }

    void DrawCrop()
    {
        if (edit.Crop is not { } crop || crop.IsFull) { cropShade.Data = null; return; }
        double w = stage.Width, h = stage.Height;
        var outside = new RectangleGeometry(new Rect(0, 0, w, h));
        var inside = new RectangleGeometry(new Rect(crop.X * w, crop.Y * h, crop.Width * w, crop.Height * h));
        cropShade.Data = new CombinedGeometry(GeometryCombineMode.Exclude, outside, inside);
    }

    NormPoint Norm(Point p) => new NormPoint(p.X / stage.Width, p.Y / stage.Height).Clamped;

    void OnDown(object sender, MouseButtonEventArgs e)
    {
        var p = e.GetPosition(overlay);
        if (tool == Tool.Annotate && annotationKind == AnnotationKind.Text)
        {
            if (string.IsNullOrWhiteSpace(annotationText)) return;
            var at = Norm(p);
            AddMark(new Annotation(AnnotationKind.Text, at, at, color, sizeLevel * 0.012, annotationText.Trim()));
            return;
        }
        dragFrom = p;
        overlay.CaptureMouse();
        Canvas.SetLeft(rubber, p.X);
        Canvas.SetTop(rubber, p.Y);
        rubber.Width = rubber.Height = 0;
        rubber.Visibility = Visibility.Visible;
    }

    void OnMove(object sender, MouseEventArgs e)
    {
        if (dragFrom is not { } from) return;
        var p = e.GetPosition(overlay);
        p = new Point(Math.Clamp(p.X, 0, stage.Width), Math.Clamp(p.Y, 0, stage.Height));
        Canvas.SetLeft(rubber, Math.Min(from.X, p.X));
        Canvas.SetTop(rubber, Math.Min(from.Y, p.Y));
        rubber.Width = Math.Abs(p.X - from.X);
        rubber.Height = Math.Abs(p.Y - from.Y);
    }

    void OnUp(object sender, MouseButtonEventArgs e)
    {
        if (dragFrom is not { } from) return;
        dragFrom = null;
        overlay.ReleaseMouseCapture();
        rubber.Visibility = Visibility.Collapsed;
        var a = Norm(from);
        var b = Norm(e.GetPosition(overlay));
        var rect = NormRect.Between(a, b);
        var tiny = rect.Width < 0.01 && rect.Height < 0.01;
        switch (tool)
        {
            case Tool.Crop:
                if (rect.Width < 0.02 || rect.Height < 0.02) return;
                Update(edit with { Crop = rect });
                break;
            case Tool.Redact:
                if (tiny) return;
                AddMark(new Redaction(rect, redactionStyle));
                break;
            case Tool.Annotate:
                if (tiny) return;
                AddMark(new Annotation(annotationKind, a, b, color, sizeLevel * 0.002));
                break;
        }
    }

    void AddMark(object mark)
    {
        history.Add(mark);
        Update(mark switch
        {
            Redaction r => edit with { Redactions = [.. edit.Redactions, r] },
            Annotation a => edit with { Annotations = [.. edit.Annotations, a] },
            _ => edit,
        });
    }

    void Save()
    {
        Editors.Run(job, new JobOperation.EditImage(edit));
        Close();
    }
}
