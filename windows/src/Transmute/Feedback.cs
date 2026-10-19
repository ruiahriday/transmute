using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows;
using Microsoft.Win32;

namespace Transmute.App;

/// Beta feedback: opens a prefilled feedback form on GitHub, or copies this PC's details
/// for testers who'd rather send them in a message.
static class Feedback
{
    public const string Repository = "ruiahriday/transmute";

    public static string Version =>
        Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "?";

    /// Transmute's version, Windows version, processor and helpers, one per line.
    public static string Details
    {
        get
        {
            var office = string.Join(", ", new[] { OfficeApps.App.Word, OfficeApps.App.Excel, OfficeApps.App.PowerPoint }.Where(OfficeApps.Has));
            return $"""
                Transmute {Version} for Windows
                {WindowsName()} (build {Environment.OSVersion.Version.Build})
                {RuntimeInformation.ProcessArchitecture} app on {RuntimeInformation.OSArchitecture} PC, {Processor()}
                ffmpeg {(Tools.Ffmpeg is null ? "missing" : "found")}
                Office: {(office.Length > 0 ? office : "not found")}; LibreOffice: {(OfficeApps.LibreOffice is null ? "not found" : "found")}
                """;
        }
    }

    static string WindowsName()
    {
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion");
            var name = key?.GetValue("ProductName") as string ?? "Windows";
            // Windows 11 still calls itself Windows 10 in the registry.
            if (Environment.OSVersion.Version.Build >= 22000) name = name.Replace("Windows 10", "Windows 11");
            var display = key?.GetValue("DisplayVersion") as string;
            return display is null ? name : $"{name} {display}";
        }
        catch { return "Windows"; }
    }

    static string Processor()
    {
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey(@"HARDWARE\DESCRIPTION\System\CentralProcessor\0");
            return (key?.GetValue("ProcessorNameString") as string)?.Trim() ?? "unknown processor";
        }
        catch { return "unknown processor"; }
    }

    public static void OpenForm()
    {
        var url = $"https://github.com/{Repository}/issues/new?template=beta-feedback.yml&mac={Uri.EscapeDataString(Details)}";
        Native.Open(url);
    }

    public static void CopyDetails()
    {
        try { Clipboard.SetText(Details); } catch { }
    }
}
