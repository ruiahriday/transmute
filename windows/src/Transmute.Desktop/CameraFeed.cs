using Windows.Graphics.Imaging;
using Windows.Media.Capture;
using Windows.Media.Capture.Frames;
using Windows.Media.MediaProperties;
using Windows.Security.Cryptography;

namespace Transmute.Desktop;

public enum CameraShape { Circle, Rounded, Full }

/// The webcam, frame by frame (Windows.Media.Capture), for the bubble shown while recording.
public sealed class CameraFeed : IDisposable
{
    MediaCapture? capture;
    MediaFrameReader? reader;
    BgraImage? latest;
    readonly object gate = new();
    public event Action? FrameArrived;
    public string Name { get; private set; } = "";

    public BgraImage? Latest { get { lock (gate) return latest; } }

    public static async Task<CameraFeed> Start()
    {
        var feed = new CameraFeed();
        try
        {
            await feed.Open();
            return feed;
        }
        catch
        {
            feed.Dispose();
            throw;
        }
    }

    async Task Open()
    {
        var groups = await MediaFrameSourceGroup.FindAllAsync();
        var group = groups.FirstOrDefault(g => g.SourceInfos.Any(i => i.SourceKind == MediaFrameSourceKind.Color && i.MediaStreamType is MediaStreamType.VideoRecord or MediaStreamType.VideoPreview))
            ?? throw new ConversionException("No camera was found.");
        var info = group.SourceInfos.First(i => i.SourceKind == MediaFrameSourceKind.Color);
        Name = group.DisplayName;
        capture = new MediaCapture();
        try
        {
            await capture.InitializeAsync(new MediaCaptureInitializationSettings
            {
                SourceGroup = group, SharingMode = MediaCaptureSharingMode.SharedReadOnly, MemoryPreference = MediaCaptureMemoryPreference.Cpu,
                StreamingCaptureMode = StreamingCaptureMode.Video,
            });
        }
        catch (UnauthorizedAccessException)
        {
            throw new ConversionException("Windows isn't letting desktop apps use the camera. Turn on Settings › Privacy & security › Camera › Let desktop apps access your camera.");
        }
        var source = capture.FrameSources[info.Id];
        reader = await capture.CreateFrameReaderAsync(source, MediaEncodingSubtypes.Bgra8);
        reader.AcquisitionMode = MediaFrameReaderAcquisitionMode.Realtime;
        reader.FrameArrived += OnFrame;
        var status = await reader.StartAsync();
        if (status != MediaFrameReaderStartStatus.Success) throw new ConversionException($"The camera didn't start ({status}).");
    }

    void OnFrame(MediaFrameReader sender, MediaFrameArrivedEventArgs args)
    {
        try
        {
            using var frame = sender.TryAcquireLatestFrame();
            var bitmap = frame?.VideoMediaFrame?.SoftwareBitmap;
            if (bitmap is null) return;
            using var bgra = bitmap.BitmapPixelFormat == BitmapPixelFormat.Bgra8 ? null : SoftwareBitmap.Convert(bitmap, BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
            var use = bgra ?? bitmap;
            var buffer = new Windows.Storage.Streams.Buffer((uint)(use.PixelWidth * use.PixelHeight * 4));
            use.CopyToBuffer(buffer);
            CryptographicBuffer.CopyToByteArray(buffer, out byte[] bytes);
            var image = new BgraImage(use.PixelWidth, use.PixelHeight, bytes);
            for (var i = 3; i < bytes.Length; i += 4) bytes[i] = 255;
            lock (gate) latest = image;
            FrameArrived?.Invoke();
        }
        catch { }
    }

    /// The latest frame, mirrored like a mirror, cropped to the shape and sized to fit `width` ×
    /// `height` pixels, with see-through corners.
    public static BgraImage Shape(BgraImage frame, int width, int height, CameraShape shape)
    {
        width = Math.Max(8, width);
        height = Math.Max(8, height);
        var result = new BgraImage(width, height);
        // Crop the frame to the target's shape (centre), then sample it.
        double target = (double)width / height, source = (double)frame.Width / frame.Height;
        double cw = frame.Width, ch = frame.Height;
        if (source > target) cw = frame.Height * target; else ch = frame.Width / target;
        double ox = (frame.Width - cw) / 2, oy = (frame.Height - ch) / 2;
        var radius = shape switch { CameraShape.Circle => Math.Min(width, height) / 2.0, CameraShape.Rounded => Math.Min(width, height) * 0.16, _ => 0 };
        var src = frame.Pixels;
        var dst = result.Pixels;
        for (var y = 0; y < height; y++)
        {
            var sy = (int)(oy + (y + 0.5) * ch / height);
            for (var x = 0; x < width; x++)
            {
                var sx = (int)(ox + (width - 1 - x + 0.5) * cw / width); // mirrored
                var si = (Math.Clamp(sy, 0, frame.Height - 1) * frame.Width + Math.Clamp(sx, 0, frame.Width - 1)) * 4;
                var di = (y * width + x) * 4;
                dst[di] = src[si]; dst[di + 1] = src[si + 1]; dst[di + 2] = src[si + 2];
                dst[di + 3] = (byte)(255 * Coverage(x + 0.5, y + 0.5, width, height, radius));
            }
        }
        return result;
    }

    /// How much of a pixel is inside a rounded rectangle (antialiased edge).
    static double Coverage(double x, double y, int w, int h, double r)
    {
        if (r <= 0) return 1;
        double cx = Math.Clamp(x, r, w - r), cy = Math.Clamp(y, r, h - r);
        var d = Math.Sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy));
        return Math.Clamp(r - d + 0.5, 0, 1);
    }

    public void Dispose()
    {
        try
        {
            if (reader is not null)
            {
                reader.FrameArrived -= OnFrame;
                _ = reader.StopAsync();
                reader.Dispose();
            }
        }
        catch { }
        try { capture?.Dispose(); } catch { }
        reader = null;
        capture = null;
    }
}
