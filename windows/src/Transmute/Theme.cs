using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace Transmute.App;

/// Spinform's look in code: the accent brush (the user's Windows accent, from ThemeManager), a
/// muted colour per kind of file, and small helpers for gentle animations that respect Windows'
/// "Animation effects" setting.
static class Theme
{
    /// The accent brush for chosen states and the main action.
    public static Brush Brand => Application.Current?.TryFindResource("Accent") as Brush ?? new SolidColorBrush(Color.FromRgb(0x00, 0x5F, 0xB8));

    /// False when the user turned animation effects off in Windows.
    public static bool Motion => SystemParameters.ClientAreaAnimation;

    public static Color Tint(FileKind kind) => kind switch
    {
        FileKind.Image => Color.FromRgb(0xB8, 0x6B, 0x7A),
        FileKind.Video => Color.FromRgb(0x7A, 0x72, 0xA8),
        FileKind.Audio => Color.FromRgb(0xB8, 0x8A, 0x55),
        FileKind.Pdf => Color.FromRgb(0xB0, 0x5E, 0x58),
        FileKind.Document or FileKind.Ebook => Color.FromRgb(0x56, 0x7F, 0xB0),
        FileKind.Presentation => Color.FromRgb(0xB5, 0x7A, 0x52),
        FileKind.Spreadsheet => Color.FromRgb(0x4F, 0x93, 0x70),
        FileKind.Subtitle => Color.FromRgb(0x6E, 0x88, 0x99),
        FileKind.Archive => Color.FromRgb(0x8E, 0x7B, 0x68),
        _ => Color.FromRgb(0x80, 0x80, 0x80),
    };

    public static Brush TintBrush(FileKind kind)
    {
        return Frozen(new SolidColorBrush(Tint(kind)));
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

    /// Buttons sink a touch when pressed (only with animation effects on).
    public static void PressFeedback()
    {
        EventManager.RegisterClassHandler(typeof(System.Windows.Controls.Primitives.ButtonBase), UIElement.PreviewMouseLeftButtonDownEvent, new System.Windows.Input.MouseButtonEventHandler((s, _) => Press((FrameworkElement)s, 0.97, 0.08)), true);
        EventManager.RegisterClassHandler(typeof(System.Windows.Controls.Primitives.ButtonBase), UIElement.PreviewMouseLeftButtonUpEvent, new System.Windows.Input.MouseButtonEventHandler((s, _) => Press((FrameworkElement)s, 1, 0.18)), true);
        EventManager.RegisterClassHandler(typeof(System.Windows.Controls.Primitives.ButtonBase), UIElement.MouseLeaveEvent, new System.Windows.Input.MouseEventHandler((s, _) => Press((FrameworkElement)s, 1, 0.18)), true);
    }

    static void Press(FrameworkElement button, double to, double seconds)
    {
        if (!Motion || button.ActualWidth > 400) return;
        if (button.RenderTransform is not ScaleTransform scale)
        {
            if (to == 1 || !(button.RenderTransform is null || ReferenceEquals(button.RenderTransform, Transform.Identity))) return;
            button.RenderTransform = scale = new ScaleTransform();
            button.RenderTransformOrigin = new Point(0.5, 0.5);
        }
        To(scale, ScaleTransform.ScaleXProperty, to, seconds);
        To(scale, ScaleTransform.ScaleYProperty, to, seconds);
    }

    static T Frozen<T>(T brush) where T : Freezable
    {
        brush.Freeze();
        return brush;
    }

    /// A soft settle (no bounce past the target: calmer than a spring).
    public static readonly IEasingFunction Spring = new QuinticEase { EasingMode = EasingMode.EaseOut };
    public static readonly IEasingFunction Smooth = new CubicEase { EasingMode = EasingMode.EaseOut };

    /// Animates a dependency property to a value.
    public static void To(IAnimatable target, DependencyProperty property, double to, double seconds,
        IEasingFunction? ease = null, double delay = 0, double? from = null)
    {
        if (!Motion) { seconds = 0; delay = 0; }
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
        if (!Motion) return;
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
        if (!Motion) return;
        target.BeginAnimation(property, new DoubleAnimation(from, to, TimeSpan.FromSeconds(seconds)) { RepeatBehavior = RepeatBehavior.Forever });
    }
}
