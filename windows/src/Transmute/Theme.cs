using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace Transmute.App;

/// Spinform's look in code: the indigo-violet-pink brand gradient from the icon, a colour per
/// kind of file, and small helpers for the springy animations.
static class Theme
{
    public static readonly Color Indigo = Color.FromRgb(0x43, 0x38, 0xCA);
    public static readonly Color Violet = Color.FromRgb(0x8B, 0x5C, 0xF6);
    public static readonly Color Pink = Color.FromRgb(0xEC, 0x48, 0x99);

    public static LinearGradientBrush Brand { get; } = Frozen(new LinearGradientBrush(
        new GradientStopCollection { new GradientStop(Indigo, 0), new GradientStop(Violet, 0.55), new GradientStop(Pink, 1) },
        new Point(0, 0), new Point(1, 1)));

    public static Color Tint(FileKind kind) => kind switch
    {
        FileKind.Image => Color.FromRgb(0xF2, 0x73, 0x8C),
        FileKind.Video => Color.FromRgb(0x8C, 0x6B, 0xF7),
        FileKind.Audio => Color.FromRgb(0xFA, 0x9E, 0x40),
        FileKind.Pdf => Color.FromRgb(0xED, 0x52, 0x4D),
        FileKind.Document or FileKind.Ebook => Color.FromRgb(0x40, 0x8C, 0xF2),
        FileKind.Presentation => Color.FromRgb(0xF5, 0x80, 0x33),
        FileKind.Spreadsheet => Color.FromRgb(0x33, 0xB3, 0x73),
        FileKind.Subtitle => Color.FromRgb(0x73, 0x99, 0xB3),
        FileKind.Archive => Color.FromRgb(0x9E, 0x80, 0x61),
        _ => Color.FromRgb(0x8A, 0x8A, 0x8A),
    };

    public static Brush TintBrush(FileKind kind)
    {
        var c = Tint(kind);
        return Frozen(new LinearGradientBrush(c, Color.FromArgb(0xC0, c.R, c.G, c.B), new Point(0, 0), new Point(1, 1)));
    }

    /// The short label in a file's badge.
    public static string Badge(FileKind kind) => kind switch
    {
        FileKind.Image => "IMG",
        FileKind.Video => "VID",
        FileKind.Audio => "AUD",
        FileKind.Pdf => "PDF",
        FileKind.Document => "DOC",
        FileKind.Ebook => "BOOK",
        FileKind.Presentation => "PPT",
        FileKind.Spreadsheet => "XLS",
        FileKind.Subtitle => "SUB",
        FileKind.Archive => "ZIP",
        _ => "FILE",
    };

    static T Frozen<T>(T brush) where T : Freezable
    {
        brush.Freeze();
        return brush;
    }

    public static readonly IEasingFunction Spring = new BackEase { Amplitude = 0.4, EasingMode = EasingMode.EaseOut };
    public static readonly IEasingFunction Smooth = new CubicEase { EasingMode = EasingMode.EaseOut };

    /// Animates a dependency property to a value.
    public static void To(IAnimatable target, DependencyProperty property, double to, double seconds,
        IEasingFunction? ease = null, double delay = 0, double? from = null)
    {
        var animation = new DoubleAnimation(to, TimeSpan.FromSeconds(seconds))
        {
            EasingFunction = ease ?? Smooth,
            BeginTime = TimeSpan.FromSeconds(delay),
        };
        if (from is { } f) animation.From = f;
        target.BeginAnimation(property, animation);
    }

    /// A value that goes from `from` to `to` and back, forever.
    public static void Wave(IAnimatable target, DependencyProperty property, double from, double to, double seconds, double delay = 0)
    {
        target.BeginAnimation(property, new DoubleAnimation(from, to, TimeSpan.FromSeconds(seconds))
        {
            AutoReverse = true,
            RepeatBehavior = RepeatBehavior.Forever,
            BeginTime = TimeSpan.FromSeconds(delay),
            EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut },
        });
    }

    /// A value that runs from `from` to `to` again and again, at a steady speed.
    public static void Loop(IAnimatable target, DependencyProperty property, double from, double to, double seconds)
    {
        target.BeginAnimation(property, new DoubleAnimation(from, to, TimeSpan.FromSeconds(seconds)) { RepeatBehavior = RepeatBehavior.Forever });
    }
}
