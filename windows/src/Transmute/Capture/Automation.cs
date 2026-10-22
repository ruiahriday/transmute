namespace Transmute.App;

/// Captures started from outside: command-line switches (spinform.exe --capture-area) and
/// spinform:// links (spinform://capture/area), so scripts, Stream Deck buttons and shortcuts in
/// other apps can drive Spinform. A running copy receives them through the single-instance pipe.
static class Automation
{
    public static readonly (string Switch, string Link, string Help)[] Commands =
    [
        ("--capture", "capture", "Open the all-in-one capture chooser"),
        ("--capture-area", "capture/area", "Capture an area"),
        ("--capture-window", "capture/window", "Capture a window"),
        ("--capture-screen", "capture/screen", "Capture the display under the pointer"),
        ("--capture-previous", "capture/previous", "Capture the previous area again"),
        ("--capture-scrolling", "capture/scrolling", "Scrolling capture"),
        ("--ocr", "ocr", "Copy text from an area, or from a picture or video given after it"),
        ("--record", "record", "Record an area (again to stop)"),
        ("--record-window", "record/window", "Record a window"),
        ("--record-screen", "record/screen", "Record the display under the pointer"),
        ("--stop-recording", "record/stop", "Stop the recording"),
        ("--history", "history", "Open the capture history"),
        ("--pin", "pin", "Pin a picture on top of everything"),
        ("--frame", "frame", "Put a picture on a background"),
        ("--annotate", "annotate", "Mark up a picture"),
    ];

    public static bool IsLink(string arg) => arg.StartsWith("spinform:", StringComparison.OrdinalIgnoreCase);

    /// Whether the arguments hold a capture command.
    public static bool Has(IEnumerable<string> args) => args.Any(a => IsLink(a) || Commands.Any(c => c.Switch.Equals(a, StringComparison.OrdinalIgnoreCase)) || a.Equals("--capture-text", StringComparison.OrdinalIgnoreCase));

    /// Turns spinform://capture/area?file=… into ("--capture-area", file).
    public static (string Switch, string? File) FromLink(string link)
    {
        var rest = link[(link.IndexOf(':') + 1)..].TrimStart('/');
        string? file = null;
        var q = rest.IndexOf('?');
        if (q >= 0)
        {
            foreach (var pair in rest[(q + 1)..].Split('&'))
            {
                var parts = pair.Split('=', 2);
                if (parts.Length == 2 && parts[0].Equals("file", StringComparison.OrdinalIgnoreCase)) file = Uri.UnescapeDataString(parts[1]);
            }
            rest = rest[..q];
        }
        rest = rest.TrimEnd('/').ToLowerInvariant();
        var match = Commands.FirstOrDefault(c => c.Link == rest);
        return (match.Switch ?? "", file);
    }

    /// Runs the first command in the arguments. Returns false when there was none.
    public static bool Run(IReadOnlyList<string> args)
    {
        for (var i = 0; i < args.Count; i++)
        {
            var arg = args[i];
            string command;
            string? file = i + 1 < args.Count && !args[i + 1].StartsWith("--") && !IsLink(args[i + 1]) ? args[i + 1] : null;
            if (IsLink(arg)) (command, file) = FromLink(arg);
            else command = arg.ToLowerInvariant();
            if (command == "--capture-text") command = "--ocr";
            if (Execute(command, file)) return true;
        }
        return false;
    }

    static bool Execute(string command, string? file)
    {
        bool needsFile = command is "--pin" or "--frame" or "--annotate";
        if (needsFile && (file is null || !File.Exists(file)))
        {
            Toast.Show("Choose a picture", $"{command} needs a picture file after it.", ok: false);
            return true;
        }
        switch (command)
        {
            case "--capture": _ = Capture.Run(CaptureAction.AllInOne); return true;
            case "--capture-area": _ = Capture.Run(CaptureAction.Area); return true;
            case "--capture-window": _ = Capture.Run(CaptureAction.Window); return true;
            case "--capture-screen": _ = Capture.Run(CaptureAction.FullScreen); return true;
            case "--capture-previous": _ = Capture.Run(CaptureAction.Previous); return true;
            case "--capture-scrolling": _ = Capture.Run(CaptureAction.Scrolling); return true;
            case "--ocr":
                if (file is not null && File.Exists(file)) _ = Capture.RecognizeFile(file);
                else _ = Capture.Run(CaptureAction.Text);
                return true;
            case "--record": _ = Capture.Run(CaptureAction.RecordArea); return true;
            case "--record-window": _ = Capture.RecordWindow(); return true;
            case "--record-screen": _ = Capture.Run(CaptureAction.RecordScreen); return true;
            case "--stop-recording": if (RecordingSession.Current is { } r) _ = r.Stop(); return true;
            case "--history": HistoryWindow.Open(); return true;
            case "--pin": PinWindow.Show(file!); return true;
            case "--frame": FrameWindow.Open(file!); return true;
            case "--annotate": Editors.Open(new Job(file!), null); return true;
            default: return false;
        }
    }
}
