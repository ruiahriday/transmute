using Transmute.Desktop;

namespace Transmute.App;

/// How window captures look: Windows 11's rounded corners kept see-through, a soft shadow, and
/// optionally the window placed on the wallpaper, a colour or a picture (Settings › Capture).
static class WindowLook
{
    public static BgraImage Apply(BgraImage image, double displayScale)
    {
        var prefs = Settings.Current;
        var rounded = prefs.WindowTransparentCorners && OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000);
        var background = prefs.WindowBackground ?? "none";
        if (!rounded && !prefs.WindowShadow && background == "none") return image;
        var radius = rounded ? 8 * displayScale : 0;
        var style = new FrameStyle
        {
            Background = FrameBackground.Transparent,
            Padding = background != "none" ? Math.Clamp(prefs.WindowPadding, 0, 0.3) : prefs.WindowShadow ? 0.05 : 0,
            Corners = radius / Math.Max(1, Math.Min(image.Width, image.Height)),
            Shadow = prefs.WindowShadow ? 0.7 : 0,
        };
        if (background == "wallpaper" && CaptureKit.WallpaperPath() is { } wallpaper) style = style with { Background = FrameBackground.Picture, PicturePath = wallpaper };
        else if (background.StartsWith("color:")) style = style with { Background = FrameBackground.Solid, From = background[6..] };
        else if (background.StartsWith("picture:") && File.Exists(background[8..])) style = style with { Background = FrameBackground.Picture, PicturePath = background[8..] };
        using var magick = image.ToMagick();
        using var framed = Frames.Render(magick, style);
        return BgraImage.FromMagick(framed);
    }
}
