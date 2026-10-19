using System.IO.Pipes;
using System.Text;
using System.Windows;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace Transmute.App;

public partial class App : Application
{
    static string InstanceName => $"Transmute-{Environment.UserName}-{System.Diagnostics.Process.GetCurrentProcess().SessionId}";

    Mutex? instance;
    // A fixed name the installer looks for, so it can ask to close Transmute before updating.
    Mutex? installerSignal;
    Forms.NotifyIcon? tray;
    DragWatcher? watcher;
    MainWindow? main;

    public static new App Current => (App)Application.Current;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += OnCrash;
        var args = e.Args.ToList();

        if (args.Count >= 2 && args[0] == "--smoke-test")
        {
            Settings.Load();
            _ = SmokeTest.Run(args[1], args.Count > 2 ? args[2] : args[1]);
            return;
        }

        instance = new Mutex(true, InstanceName, out var first);
        if (!first)
        {
            // Already running: hand the files over and quit.
            Forward(args);
            Shutdown();
            return;
        }

        installerSignal = new Mutex(false, "TransmuteRunning");
        Settings.Load();
        Listen();
        SetUpTray();
        watcher = new DragWatcher();
        watcher.Start();

        var background = args.Remove("--background");
        var files = args.Where(a => !a.StartsWith("--")).ToList();
        if (files.Count > 0 || !background) ShowMain(files);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        watcher?.Stop();
        if (tray is not null) { tray.Visible = false; tray.Dispose(); }
        instance?.Dispose();
        installerSignal?.Dispose();
        base.OnExit(e);
    }

    public void ShowMain(IEnumerable<string>? files = null)
    {
        if (main is null || !main.IsLoaded)
        {
            main = new MainWindow();
            main.Closed += (_, _) => main = null;
        }
        if (files is not null)
        {
            var list = files.ToList();
            if (list.Count > 0) JobQueue.Shared.Add(list);
        }
        main.Show();
        if (main.WindowState == WindowState.Minimized) main.WindowState = WindowState.Normal;
        main.Activate();
        // Windows only lets the foreground app take focus; this nudges it after a hand-over.
        main.Topmost = true;
        main.Topmost = false;
        main.Focus();
    }

    public void Quit()
    {
        JobQueue.Shared.CancelAll();
        Shutdown();
    }

    // Tray icon

    void SetUpTray()
    {
        tray = new Forms.NotifyIcon
        {
            Text = "Transmute",
            Visible = true,
        };
        try
        {
            using var stream = GetResourceStream(new Uri("pack://application:,,,/Assets/app.ico"))!.Stream;
            tray.Icon = new System.Drawing.Icon(stream, Forms.SystemInformation.SmallIconSize);
        }
        catch { tray.Icon = System.Drawing.SystemIcons.Application; }
        tray.MouseClick += (_, e) => { if (e.Button == Forms.MouseButtons.Left) ShowMain(); };
        tray.ContextMenuStrip = new Forms.ContextMenuStrip();
        tray.ContextMenuStrip.Opening += (_, _) => BuildMenu(tray.ContextMenuStrip);
        BuildMenu(tray.ContextMenuStrip);
    }

    void BuildMenu(Forms.ContextMenuStrip menu)
    {
        menu.Items.Clear();
        menu.Items.Add("Open Transmute", null, (_, _) => ShowMain());
        menu.Items.Add("Show Floating Files", null, (_, _) => Shelf.Shared.Toggle());
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Send Feedback…", null, (_, _) => Feedback.OpenForm());
        menu.Items.Add("Settings…", null, (_, _) => SettingsWindow.Open());
        var settings = Settings.Current;
        if (settings.WheelEnabled)
        {
            var hints = Enum.GetValues<WheelKind>().Where(k => settings.KeyFor(k) != WheelKey.Off).ToList();
            if (hints.Count > 0) menu.Items.Add(new Forms.ToolStripSeparator());
            foreach (var kind in hints)
                menu.Items.Add(new Forms.ToolStripMenuItem($"Hold {settings.KeyFor(kind).Label()} while dragging for {kind.Hint()}") { Enabled = false });
        }
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Quit Transmute", null, (_, _) => Quit());
    }

    // One copy at a time: later launches (Send To, Open With, the context menu) pass their files here.

    static void Forward(List<string> args)
    {
        try
        {
            using var pipe = new NamedPipeClientStream(".", InstanceName, PipeDirection.Out);
            pipe.Connect(3000);
            var payload = string.Join("\n", args.Count == 0 ? ["--show"] : args.Select(a => a.StartsWith("--") ? a : Path.GetFullPath(a)));
            var bytes = Encoding.UTF8.GetBytes(payload);
            pipe.Write(bytes, 0, bytes.Length);
        }
        catch { }
    }

    void Listen()
    {
        var thread = new Thread(() =>
        {
            while (true)
            {
                try
                {
                    using var pipe = new NamedPipeServerStream(InstanceName, PipeDirection.In, 1);
                    pipe.WaitForConnection();
                    using var reader = new StreamReader(pipe, Encoding.UTF8);
                    var lines = reader.ReadToEnd().Split('\n', StringSplitOptions.RemoveEmptyEntries);
                    var files = lines.Where(l => !l.StartsWith("--")).ToList();
                    var background = lines.Contains("--background");
                    Dispatcher.BeginInvoke(() => { if (files.Count > 0 || !background) ShowMain(files); });
                }
                catch
                {
                    Thread.Sleep(500);
                }
            }
        }) { IsBackground = true, Name = "Transmute hand-over" };
        thread.Start();
    }

    // Crashes: keep a log, say what happened, keep running.

    void OnCrash(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        try
        {
            Directory.CreateDirectory(Settings.Folder);
            File.AppendAllText(Path.Combine(Settings.Folder, "errors.log"), $"{DateTime.Now:u}\n{e.Exception}\n\n");
        }
        catch { }
        if (SmokeTest.Active)
        {
            SmokeTest.Fail(e.Exception);
            e.Handled = true;
            return;
        }
        MessageBox.Show($"Something went wrong: {e.Exception.Message}\n\nThe details are saved in {Path.Combine(Settings.Folder, "errors.log")}.",
            "Transmute", MessageBoxButton.OK, MessageBoxImage.Warning);
        e.Handled = true;
    }
}
