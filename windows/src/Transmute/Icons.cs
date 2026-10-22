using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using Path = System.Windows.Shapes.Path;

namespace Transmute.App;

/// Spinform's own line icons, drawn as vectors on a 24 × 24 grid so they stay sharp at every
/// display scale. Each is a stroke of 1.6 with round ends, in the text colour unless given one.
static class Icons
{
    static readonly Dictionary<string, Geometry> Cache = [];

    static readonly Dictionary<string, string> Paths = new()
    {
        ["add"] = "M12 5 V19 M5 12 H19",
        ["close"] = "M6 6 L18 18 M18 6 L6 18",
        ["check"] = "M5 12.5 L10 17.5 L19 7",
        ["folder"] = "M3.5 7 A1.5 1.5 0 0 1 5 5.5 H9.5 L11.5 7.5 H19 A1.5 1.5 0 0 1 20.5 9 V17.5 A1.5 1.5 0 0 1 19 19 H5 A1.5 1.5 0 0 1 3.5 17.5 Z",
        ["settings"] = "M4 7 H13 M17 7 H20 M15 4.5 V9.5 M4 17 H7 M11 17 H20 M9 14.5 V19.5 M4 12 H20",
        ["feedback"] = "M4.5 6 A1.5 1.5 0 0 1 6 4.5 H18 A1.5 1.5 0 0 1 19.5 6 V14 A1.5 1.5 0 0 1 18 15.5 H11 L7 19 V15.5 H6 A1.5 1.5 0 0 1 4.5 14 Z M8.5 9 H15.5 M8.5 12 H13",
        ["edit"] = "M14.5 5.5 L18.5 9.5 M4.5 19.5 L5.5 15 L15.8 4.7 A1.4 1.4 0 0 1 17.8 4.7 L19.3 6.2 A1.4 1.4 0 0 1 19.3 8.2 L9 18.5 Z",
        ["info"] = "M12 3.5 A8.5 8.5 0 1 1 11.99 3.5 Z M12 11 V16.5 M12 7.6 V7.8",
        ["convert"] = "M5 9 H18 M14.5 5.5 L18 9 L14.5 12.5 M19 15 H6 M9.5 11.5 L6 15 L9.5 18.5",
        ["compress"] = "M9.5 4.5 V9.5 H4.5 M14.5 4.5 V9.5 H19.5 M9.5 19.5 V14.5 H4.5 M14.5 19.5 V14.5 H19.5",
        ["tools"] = "M12 3.5 L13.6 9 L19 10.5 L13.6 12 L12 17.5 L10.4 12 L5 10.5 L10.4 9 Z M18.5 16 L19.2 18 L21 18.7 L19.2 19.4 L18.5 21.4 L17.8 19.4 L16 18.7 L17.8 18 Z",
        ["image"] = "M4.5 6 A1.5 1.5 0 0 1 6 4.5 H18 A1.5 1.5 0 0 1 19.5 6 V18 A1.5 1.5 0 0 1 18 19.5 H6 A1.5 1.5 0 0 1 4.5 18 Z M4.5 16 L9.5 11 L15 16.5 M13.5 14.5 L15.5 12.5 L19.5 16.5 M15 8.2 V8.4",
        ["video"] = "M4.5 7 A1.5 1.5 0 0 1 6 5.5 H14 A1.5 1.5 0 0 1 15.5 7 V17 A1.5 1.5 0 0 1 14 18.5 H6 A1.5 1.5 0 0 1 4.5 17 Z M15.5 10 L19.5 7.5 V16.5 L15.5 14",
        ["audio"] = "M9 17.5 V6 L19 4 V15.5 M9 17.5 A2.5 2.2 0 1 1 8.99 17.5 Z M19 15.5 A2.5 2.2 0 1 1 18.99 15.5 Z",
        ["document"] = "M6.5 3.5 H13.5 L18.5 8.5 V19 A1.5 1.5 0 0 1 17 20.5 H6.5 A1.5 1.5 0 0 1 5 19 V5 A1.5 1.5 0 0 1 6.5 3.5 Z M13.5 3.5 V8.5 H18.5 M8.5 12.5 H15 M8.5 16 H15",
        ["zip"] = "M4.5 8 L12 4 L19.5 8 V16 L12 20 L4.5 16 Z M4.5 8 L12 12 L19.5 8 M12 12 V20",
        ["qr"] = "M4.5 4.5 H10 V10 H4.5 Z M14 4.5 H19.5 V10 H14 Z M4.5 14 H10 V19.5 H4.5 Z M14 14 H16 V16 H14 Z M17.5 17.5 H19.5 V19.5 H17.5 Z M14 18.5 V19.5 M19.5 14 H18.5",
        ["split"] = "M5 4.5 H11 V19.5 H5 Z M14 4.5 H19 V19.5 H14 Z M8 9 V9.2 M16.5 9 V9.2",
        ["merge"] = "M5 4.5 V9 C5 12 12 12 12 15 V19.5 M19 4.5 V9 C19 12 12 12 12 15 M9 16.5 L12 19.5 L15 16.5",
        ["pin"] = "M9 4.5 H15 M10 4.5 V10 L7 14 H17 L14 10 V4.5 M12 14 V20",
        ["copy"] = "M8.5 8.5 H18 A1.5 1.5 0 0 1 19.5 10 V18 A1.5 1.5 0 0 1 18 19.5 H10 A1.5 1.5 0 0 1 8.5 18 Z M15.5 8.5 V6 A1.5 1.5 0 0 0 14 4.5 H6 A1.5 1.5 0 0 0 4.5 6 V14 A1.5 1.5 0 0 0 6 15.5 H8.5",
        ["link"] = "M10 14 L14 10 M8.5 11.5 L6.5 13.5 A3.2 3.2 0 0 0 11 18 L13 16 M15.5 12.5 L17.5 10.5 A3.2 3.2 0 0 0 13 6 L11 8",
        ["terminal"] = "M4.5 6 A1.5 1.5 0 0 1 6 4.5 H18 A1.5 1.5 0 0 1 19.5 6 V18 A1.5 1.5 0 0 1 18 19.5 H6 A1.5 1.5 0 0 1 4.5 18 Z M8 9.5 L11 12 L8 14.5 M12.5 15 H16",
        ["move"] = "M3.5 7 A1.5 1.5 0 0 1 5 5.5 H9.5 L11.5 7.5 H19 A1.5 1.5 0 0 1 20.5 9 V17.5 A1.5 1.5 0 0 1 19 19 H5 A1.5 1.5 0 0 1 3.5 17.5 Z M9 13.5 H15 M12.5 11 L15 13.5 L12.5 16",
        ["search"] = "M10.5 4.5 A6 6 0 1 1 10.49 4.5 Z M15 15 L19.5 19.5",
        ["cutout"] = "M12 4 C8 4 7 7.5 7.5 10 C8 12.5 10 13.5 12 13.5 C14 13.5 16 12.5 16.5 10 C17 7.5 16 4 12 4 Z M5 20 C5.5 16.5 8 15 12 15 C16 15 18.5 16.5 19 20 M3.5 3.5 H5 M3.5 3.5 V5 M20.5 3.5 H19 M20.5 3.5 V5 M3.5 20.5 V19 M20.5 20.5 V19",
        ["layers"] = "M12 4 L20 8.5 L12 13 L4 8.5 Z M4 12.5 L12 17 L20 12.5 M4 16 L12 20.5 L20 16",
        ["undo"] = "M8.5 7 L4.5 11 L8.5 15 M5 11 H14.5 A4.5 4.5 0 0 1 14.5 20 H11",
        ["rotateleft"] = "M8 4.5 L4.5 8 L8 11.5 M5 8 H13 A6 6 0 1 1 7 14",
        ["rotateright"] = "M16 4.5 L19.5 8 L16 11.5 M19 8 H11 A6 6 0 1 0 17 14",
        ["fliph"] = "M12 4 V20 M9 7 L4 17 H9 Z M15 7 L20 17 H15 Z",
        ["flipv"] = "M4 12 H20 M7 9 L17 4 V9 Z M7 15 L17 20 V15 Z",
        ["play"] = "M8 5.5 L18.5 12 L8 18.5 Z",
        ["stop"] = "M7 7 H17 V17 H7 Z",
        ["warning"] = "M12 4 L21 19.5 H3 Z M12 10 V14 M12 16.8 V17",
        ["working"] = "M19.5 12 A7.5 7.5 0 1 1 17 6.4 M19.5 4.5 V8.5 H15.5",
        ["up"] = "M6 14.5 L12 8.5 L18 14.5",
        ["down"] = "M6 9.5 L12 15.5 L18 9.5",
        ["eraser"] = "M9 19.5 H19.5 M4.8 14.2 L13.8 5.2 A1.5 1.5 0 0 1 15.9 5.2 L19.8 9.1 A1.5 1.5 0 0 1 19.8 11.2 L11.5 19.5 H8.5 L4.8 15.8 A1.2 1.2 0 0 1 4.8 14.2 Z M9.5 9.5 L15.5 15.5",
        ["palette"] = "M12 4 A8 8 0 1 0 12 20 C13.5 20 13.8 18.8 13.2 17.8 C12.5 16.6 13.3 15.5 14.6 15.5 H16.5 A3.5 3.5 0 0 0 20 12 C20 7.6 16.4 4 12 4 Z M8 11 V11.2 M10.5 7.8 V8 M14.5 8 V8.2",
    };

    public static Geometry Geometry(string name)
    {
        if (Cache.TryGetValue(name, out var cached)) return cached;
        var geometry = System.Windows.Media.Geometry.Parse(Paths.TryGetValue(name, out var data) ? data : Paths["tools"]);
        geometry.Freeze();
        Cache[name] = geometry;
        return geometry;
    }

    public static bool Has(string name) => Paths.ContainsKey(name);

    /// The icon at `size` device-independent pixels. With no brush it follows the text colour.
    public static FrameworkElement Make(string name, double size = 16, Brush? brush = null, double weight = 1.6)
    {
        var path = new Path
        {
            Data = Geometry(name),
            StrokeThickness = weight,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            StrokeLineJoin = PenLineJoin.Round,
            Stretch = Stretch.None,
            SnapsToDevicePixels = true,
        };
        if (brush is not null) path.Stroke = brush;
        else path.SetBinding(Shape.StrokeProperty, new System.Windows.Data.Binding("Foreground")
        {
            RelativeSource = new System.Windows.Data.RelativeSource(System.Windows.Data.RelativeSourceMode.FindAncestor, typeof(Control), 1),
            FallbackValue = Application.Current?.TryFindResource("Ink") as Brush ?? Brushes.Black,
        });
        // Drawn on a 24 grid, scaled to the size asked for.
        var box = new Viewbox { Width = size, Height = size, Stretch = Stretch.Uniform, Child = new Canvas { Width = 24, Height = 24, Children = { path } }, SnapsToDevicePixels = true };
        return box;
    }

    /// An icon followed by a label, for buttons.
    public static StackPanel WithText(string icon, string text, double size = 15)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        var glyph = Make(icon, size);
        glyph.Margin = new Thickness(0, 0, 7, 0);
        glyph.VerticalAlignment = VerticalAlignment.Center;
        panel.Children.Add(glyph);
        panel.Children.Add(new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center });
        return panel;
    }
}

/// Lets XAML put an icon in a button: &lt;local:Icon Name="add" /&gt;.
sealed class Icon : ContentControl
{
    public static readonly DependencyProperty GlyphProperty = DependencyProperty.Register(nameof(Glyph), typeof(string), typeof(Icon),
        new PropertyMetadata("tools", (d, _) => ((Icon)d).Rebuild()));
    public static readonly DependencyProperty SizeProperty = DependencyProperty.Register(nameof(Size), typeof(double), typeof(Icon),
        new PropertyMetadata(16.0, (d, _) => ((Icon)d).Rebuild()));
    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(nameof(Text), typeof(string), typeof(Icon),
        new PropertyMetadata(null, (d, _) => ((Icon)d).Rebuild()));

    public string Glyph { get => (string)GetValue(GlyphProperty); set => SetValue(GlyphProperty, value); }
    public double Size { get => (double)GetValue(SizeProperty); set => SetValue(SizeProperty, value); }
    public string? Text { get => (string?)GetValue(TextProperty); set => SetValue(TextProperty, value); }

    public Icon()
    {
        Focusable = false;
        IsTabStop = false;
        Rebuild();
    }

    void Rebuild()
    {
        var path = new Path
        {
            Data = Icons.Geometry(Glyph),
            StrokeThickness = 1.6,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            StrokeLineJoin = PenLineJoin.Round,
        };
        path.SetBinding(Shape.StrokeProperty, new System.Windows.Data.Binding(nameof(Foreground)) { Source = this });
        var glyph = new Viewbox { Width = Size, Height = Size, Child = new Canvas { Width = 24, Height = 24, Children = { path } }, VerticalAlignment = VerticalAlignment.Center };
        if (string.IsNullOrEmpty(Text)) { Content = glyph; return; }
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        glyph.Margin = new Thickness(0, 0, 7, 0);
        panel.Children.Add(glyph);
        panel.Children.Add(new TextBlock { Text = Text, VerticalAlignment = VerticalAlignment.Center });
        Content = panel;
    }
}
