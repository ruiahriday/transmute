using System.Runtime.InteropServices;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using WinRT;

namespace Transmute.Desktop;

/// Windows' own Share panel (nearby sharing, Mail, Teams…) for a file, from a desktop window.
/// Nothing goes through Spinform: Windows hands the file to the app the user picks.
public static class ShareSheet
{
    static readonly Guid InteropIid = new("3A3DCD6C-3EAB-43DC-BCDE-45671CE800C8");
    static readonly Guid ManagerIid = new("A5CAEE9B-8708-49D1-8D36-67D25A8DA00C");
    static readonly HashSet<IntPtr> hooked = [];
    static readonly Dictionary<IntPtr, string> pending = [];

    public static bool IsAvailable => OperatingSystem.IsWindowsVersionAtLeast(10, 0, 17763);

    static async void Provide(IntPtr hwnd, DataRequestedEventArgs e)
    {
        if (!pending.TryGetValue(hwnd, out var file)) return;
        var deferral = e.Request.GetDeferral();
        try
        {
            e.Request.Data.Properties.Title = Path.GetFileName(file);
            e.Request.Data.Properties.Description = "Shared from Spinform";
            var item = await StorageFile.GetFileFromPathAsync(file);
            e.Request.Data.SetStorageItems([item]);
        }
        catch (Exception ex) { e.Request.FailWithDisplayText(ex.Message); }
        finally { deferral.Complete(); }
    }

    public static unsafe void Show(IntPtr hwnd, string path)
    {
        using var factory = ActivationFactory.Get("Windows.ApplicationModel.DataTransfer.DataTransferManager");
        Marshal.ThrowExceptionForHR(Marshal.QueryInterface(factory.ThisPtr, in InteropIid, out var interop));
        try
        {
            var vtable = *(void***)interop;
            var iid = ManagerIid;
            IntPtr managerPtr;
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, Guid*, IntPtr*, int>)vtable[3])(interop, hwnd, &iid, &managerPtr));
            var manager = DataTransferManager.FromAbi(managerPtr);
            Marshal.Release(managerPtr);
            pending[hwnd] = path;
            if (hooked.Add(hwnd))
            {
                manager.DataRequested += (_, e) => Provide(hwnd, e);
            }
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<IntPtr, IntPtr, int>)vtable[4])(interop, hwnd));
        }
        finally { Marshal.Release(interop); }
    }
}
