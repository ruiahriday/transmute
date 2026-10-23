using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Transmute.App;

/// Explorer's icon for a file, cached by extension.
static class FileIcons
{
    static readonly Dictionary<string, ImageSource?> cache = new(StringComparer.OrdinalIgnoreCase);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SHFILEINFO
    {
        public IntPtr hIcon;
        public int iIcon;
        public uint dwAttributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr SHGetFileInfo(string path, uint attributes, ref SHFILEINFO info, uint size, uint flags);

    [DllImport("user32.dll")]
    static extern bool DestroyIcon(IntPtr icon);

    const uint SHGFI_ICON = 0x100, SHGFI_LARGEICON = 0x0, SHGFI_USEFILEATTRIBUTES = 0x10;
    const uint FILE_ATTRIBUTE_NORMAL = 0x80, FILE_ATTRIBUTE_DIRECTORY = 0x10;

    public static ImageSource? For(string path)
    {
        var isDir = Directory.Exists(path);
        var ext = isDir ? "<folder>" : Path.GetExtension(path);
        // Programs and shortcuts have their own icons.
        var own = ext.Equals(".exe", StringComparison.OrdinalIgnoreCase) || ext.Equals(".lnk", StringComparison.OrdinalIgnoreCase) || ext.Equals(".ico", StringComparison.OrdinalIgnoreCase);
        var key = own ? path : ext;
        if (cache.TryGetValue(key, out var cached)) return cached;
        ImageSource? image = null;
        try
        {
            var info = new SHFILEINFO();
            var flags = SHGFI_ICON | SHGFI_LARGEICON | (own ? 0 : SHGFI_USEFILEATTRIBUTES);
            var name = own ? path : isDir ? "folder" : "file" + ext;
            SHGetFileInfo(name, isDir ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL, ref info, (uint)Marshal.SizeOf<SHFILEINFO>(), flags);
            if (info.hIcon != IntPtr.Zero)
            {
                var source = Imaging.CreateBitmapSourceFromHIcon(info.hIcon, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                source.Freeze();
                DestroyIcon(info.hIcon);
                image = source;
            }
        }
        catch { }
        cache[key] = image;
        return image;
    }
}
