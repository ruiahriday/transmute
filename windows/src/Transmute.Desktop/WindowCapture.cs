using System.Runtime.InteropServices;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using WinRT;
using static Transmute.Desktop.Win32;

namespace Transmute.Desktop;

/// Takes a picture of one window, even when other windows cover it. Uses Windows.Graphics.Capture
/// (Windows 10 1903 and later), then PrintWindow, then the screen itself.
public static class WindowCapture
{
    /// Which way the last window picture was taken (for the self-test and the log).
    public static string LastMethod { get; private set; } = "";

    public static BgraImage Capture(IntPtr hwnd)
    {
        var bounds = Screens.WindowBounds(hwnd);
        if (GraphicsCapture.IsAvailable)
        {
            try
            {
                var image = GraphicsCapture.Window(hwnd);
                if (image is not null && !LooksEmpty(image))
                {
                    // Some apps leave junk in the alpha channel; the picture is what's on screen.
                    for (var i = 3; i < image.Pixels.Length; i += 4) image.Pixels[i] = 255;
                    LastMethod = "Windows.Graphics.Capture";
                    return image;
                }
            }
            catch { }
        }
        try
        {
            var printed = Print(hwnd, bounds);
            if (printed is not null && !LooksEmpty(printed)) { LastMethod = "PrintWindow"; return printed; }
        }
        catch { }
        LastMethod = "screen";
        return ScreenGrab.Area(bounds);
    }

    /// A picture that's all one colour (often black) means the method didn't really work.
    static bool LooksEmpty(BgraImage image)
    {
        var p = image.Pixels;
        var first = BitConverter.ToUInt32(p, 0) & 0xFFFFFF;
        var step = Math.Max(4, p.Length / 4 / 2000 * 4);
        for (var i = 0; i < p.Length - 4; i += step) if ((BitConverter.ToUInt32(p, i) & 0xFFFFFF) != first) return false;
        return true;
    }

    /// PrintWindow with full content (Windows 8.1 and later), cut to the visible frame.
    static BgraImage? Print(IntPtr hwnd, PixelRect visible)
    {
        GetWindowRect(hwnd, out var outer);
        if (outer.Width < 1 || outer.Height < 1) return null;
        using var grabber = new PrintTarget(outer.Width, outer.Height);
        if (!PrintWindow(hwnd, grabber.Dc, PW_RENDERFULLCONTENT)) return null;
        var image = grabber.ToImage();
        var x = visible.X - outer.Left;
        var y = visible.Y - outer.Top;
        return x == 0 && y == 0 && visible.Width == image.Width && visible.Height == image.Height ? image : image.Crop(x, y, visible.Width, visible.Height);
    }

    sealed unsafe class PrintTarget : IDisposable
    {
        readonly IntPtr screen, bitmap, old;
        readonly byte* bits;
        public IntPtr Dc { get; }
        readonly int w, h;

        public PrintTarget(int width, int height)
        {
            (w, h) = (width, height);
            screen = GetDC(IntPtr.Zero);
            Dc = CreateCompatibleDC(screen);
            var header = new BITMAPINFOHEADER { biSize = Marshal.SizeOf<BITMAPINFOHEADER>(), biWidth = w, biHeight = -h, biPlanes = 1, biBitCount = 32 };
            bitmap = CreateDIBSection(screen, ref header, 0, out var p, IntPtr.Zero, 0);
            bits = (byte*)p;
            old = SelectObject(Dc, bitmap);
        }

        public BgraImage ToImage()
        {
            GdiFlush();
            var image = new BgraImage(w, h);
            new ReadOnlySpan<byte>(bits, w * h * 4).CopyTo(image.Pixels);
            for (var i = 3; i < image.Pixels.Length; i += 4) image.Pixels[i] = 255;
            return image;
        }

        public void Dispose()
        {
            SelectObject(Dc, old);
            DeleteDC(Dc);
            DeleteObject(bitmap);
            ReleaseDC(IntPtr.Zero, screen);
        }
    }
}

/// Windows.Graphics.Capture for single pictures, with just enough Direct3D 11 to read the
/// frame back: a device (hardware, or the WARP software renderer), a staging texture, a copy.
public static unsafe class GraphicsCapture
{
    static readonly Guid ItemIid = new("79C3F95B-31F7-4EC2-A464-632EF5D30760");
    static readonly Guid InteropIid = new("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356");
    static readonly Guid DxgiDeviceIid = new("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
    static readonly Guid DxgiAccessIid = new("A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1");
    static readonly Guid Texture2DIid = new("6f15aaf2-d208-4e89-9ab4-489535d34f9c");

    [DllImport("d3d11.dll")]
    static extern int D3D11CreateDevice(IntPtr adapter, int driverType, IntPtr software, uint flags, IntPtr levels, uint count, uint sdk,
        out IntPtr device, out int level, out IntPtr context);

    [DllImport("d3d11.dll")]
    static extern int CreateDirect3D11DeviceFromDXGIDevice(IntPtr dxgiDevice, out IntPtr graphicsDevice);

    [StructLayout(LayoutKind.Sequential)]
    struct Texture2DDesc
    {
        public uint Width, Height, MipLevels, ArraySize, Format, SampleCount, SampleQuality, Usage, BindFlags, CpuAccessFlags, MiscFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct Mapped { public IntPtr Data; public uint RowPitch, DepthPitch; }

    public static bool IsAvailable
    {
        get
        {
            try { return OperatingSystem.IsWindowsVersionAtLeast(10, 0, 18362) && GraphicsCaptureSession.IsSupported(); }
            catch { return false; }
        }
    }

    static void* Slot(IntPtr com, int index) => (*(void***)com)[index];

    static IntPtr Query(IntPtr com, Guid iid)
    {
        Marshal.ThrowExceptionForHR(Marshal.QueryInterface(com, ref iid, out var result));
        return result;
    }

    static GraphicsCaptureItem Item(IntPtr handle, bool monitor)
    {
        using var factory = ActivationFactory.Get("Windows.Graphics.Capture.GraphicsCaptureItem");
        var interop = Query(factory.ThisPtr, InteropIid);
        try
        {
            var iid = ItemIid;
            IntPtr item;
            var create = (delegate* unmanaged[Stdcall]<IntPtr, IntPtr, Guid*, IntPtr*, int>)Slot(interop, monitor ? 4 : 3);
            Marshal.ThrowExceptionForHR(create(interop, handle, &iid, &item));
            try { return GraphicsCaptureItem.FromAbi(item); }
            finally { Marshal.Release(item); }
        }
        finally { Marshal.Release(interop); }
    }

    public static BgraImage? Window(IntPtr hwnd) => Grab(Item(hwnd, monitor: false));

    public static BgraImage? Monitor(IntPtr monitor) => Grab(Item(monitor, monitor: true));

    static BgraImage? Grab(GraphicsCaptureItem item)
    {
        IntPtr device = IntPtr.Zero, context = IntPtr.Zero;
        // Hardware first, then WARP (machines without a graphics driver, like build servers).
        foreach (var driver in new[] { 1, 5 })
        {
            if (D3D11CreateDevice(IntPtr.Zero, driver, IntPtr.Zero, 0x20 /* BGRA support */, IntPtr.Zero, 0, 7, out device, out _, out context) >= 0) break;
            device = context = IntPtr.Zero;
        }
        if (device == IntPtr.Zero) return null;
        IntPtr dxgi = IntPtr.Zero, inspectable = IntPtr.Zero;
        try
        {
            dxgi = Query(device, DxgiDeviceIid);
            Marshal.ThrowExceptionForHR(CreateDirect3D11DeviceFromDXGIDevice(dxgi, out inspectable));
            var direct3D = MarshalInterface<IDirect3DDevice>.FromAbi(inspectable);
            var size = item.Size;
            using var pool = Direct3D11CaptureFramePool.CreateFreeThreaded(direct3D, DirectXPixelFormat.B8G8R8A8UIntNormalized, 1, size);
            using var session = pool.CreateCaptureSession(item);
            try
            {
                // Windows 11: no yellow border, no pointer in the picture.
                if (Windows.Foundation.Metadata.ApiInformation.IsPropertyPresent("Windows.Graphics.Capture.GraphicsCaptureSession", "IsBorderRequired"))
                    session.IsBorderRequired = false;
                if (Windows.Foundation.Metadata.ApiInformation.IsPropertyPresent("Windows.Graphics.Capture.GraphicsCaptureSession", "IsCursorCaptureEnabled"))
                    session.IsCursorCaptureEnabled = false;
            }
            catch { }
            using var arrived = new ManualResetEventSlim();
            Direct3D11CaptureFrame? frame = null;
            pool.FrameArrived += (p, _) =>
            {
                if (frame is not null) return;
                frame = p.TryGetNextFrame();
                arrived.Set();
            };
            session.StartCapture();
            if (!arrived.Wait(2000) || frame is null) return null;
            using (frame)
                return Read(device, context, frame.Surface);
        }
        finally
        {
            if (inspectable != IntPtr.Zero) Marshal.Release(inspectable);
            if (dxgi != IntPtr.Zero) Marshal.Release(dxgi);
            if (context != IntPtr.Zero) Marshal.Release(context);
            Marshal.Release(device);
        }
    }

    static BgraImage Read(IntPtr device, IntPtr context, IDirect3DSurface surface)
    {
        var surfacePtr = MarshalInterface<IDirect3DSurface>.FromManaged(surface);
        IntPtr access = IntPtr.Zero, texture = IntPtr.Zero, staging = IntPtr.Zero;
        try
        {
            access = Query(surfacePtr, DxgiAccessIid);
            var iid = Texture2DIid;
            var getInterface = (delegate* unmanaged[Stdcall]<IntPtr, Guid*, IntPtr*, int>)Slot(access, 3);
            Marshal.ThrowExceptionForHR(getInterface(access, &iid, &texture));
            Texture2DDesc desc;
            ((delegate* unmanaged[Stdcall]<IntPtr, Texture2DDesc*, void>)Slot(texture, 10))(texture, &desc);
            desc.MipLevels = 1; desc.ArraySize = 1; desc.SampleCount = 1; desc.SampleQuality = 0;
            desc.Usage = 3; desc.BindFlags = 0; desc.CpuAccessFlags = 0x20000; desc.MiscFlags = 0;
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<IntPtr, Texture2DDesc*, IntPtr, IntPtr*, int>)Slot(device, 5))(device, &desc, IntPtr.Zero, &staging));
            ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, IntPtr, void>)Slot(context, 47))(context, staging, texture);
            Mapped mapped;
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, uint, int, uint, Mapped*, int>)Slot(context, 14))(context, staging, 0, 1, 0, &mapped));
            try
            {
                int w = (int)desc.Width, h = (int)desc.Height;
                var image = new BgraImage(w, h);
                for (var y = 0; y < h; y++)
                    new ReadOnlySpan<byte>((byte*)mapped.Data + y * mapped.RowPitch, w * 4).CopyTo(image.Pixels.AsSpan(y * w * 4, w * 4));
                return image;
            }
            finally
            {
                ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, uint, void>)Slot(context, 15))(context, staging, 0);
            }
        }
        finally
        {
            if (staging != IntPtr.Zero) Marshal.Release(staging);
            if (texture != IntPtr.Zero) Marshal.Release(texture);
            if (access != IntPtr.Zero) Marshal.Release(access);
            Marshal.Release(surfacePtr);
        }
    }
}
