using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;

namespace Transmute.App;

public enum JobStatus { Queued, Running, Done, Failed }

/// One file in the list, and what happened to it.
public sealed class Job : INotifyPropertyChanged
{
    public Guid Id { get; } = Guid.NewGuid();
    public string Path { get; }
    public FileKind Kind { get; }
    public long Size { get; }
    public string Name => System.IO.Path.GetFileName(Path);
    public string Details => $"{Kind.Title()} · {OutputPaths.FormatSize(Size)}";
    public ImageSource? Icon => FileIcons.For(Path);

    JobStatus status;
    double fraction;
    JobResult? result;
    string? error;

    public Job(string path)
    {
        Path = path;
        Kind = Kinds.Of(path);
        Size = OutputPaths.FileSize(path);
    }

    public JobStatus Status { get => status; set { status = value; Changed(); Changed(nameof(IsRunning)); Changed(nameof(IsFinished)); Changed(nameof(StatusText)); Changed(nameof(Message)); Changed(nameof(HasOutputs)); } }
    public double Fraction { get => fraction; set { fraction = value; Changed(); } }
    public JobResult? Result { get => result; set { result = value; Changed(); Changed(nameof(Message)); Changed(nameof(HasOutputs)); } }
    public string? Error { get => error; set { error = value; Changed(); Changed(nameof(Message)); } }

    public bool IsRunning => Status == JobStatus.Running;
    public bool IsFinished => Status is JobStatus.Done or JobStatus.Failed;
    public bool HasOutputs => Status == JobStatus.Done && Result?.Outputs.Count > 0;
    public string? Message => Status switch
    {
        JobStatus.Failed => Error,
        JobStatus.Done => Result?.Message,
        _ => null,
    };
    public string StatusText => Status switch
    {
        JobStatus.Queued => "Ready",
        JobStatus.Done => "✓",
        JobStatus.Failed => "⚠",
        _ => "",
    };
    public bool CanEdit => Kind is FileKind.Image or FileKind.Video or FileKind.Audio;
    public bool HasInfo => Kind is FileKind.Image or FileKind.Video or FileKind.Audio or FileKind.Pdf;

    public event PropertyChangedEventHandler? PropertyChanged;
    void Changed([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new(name));
}

/// The file list and the conversions running on it. Lives on the UI thread.
public sealed class JobQueue : INotifyPropertyChanged
{
    public static JobQueue Shared { get; } = new();

    public ObservableCollection<Job> Jobs { get; } = [];
    readonly List<CancellationTokenSource> running = [];
    int activeBatches;

    /// How many files convert at once. ffmpeg is multithreaded itself, so keep this small.
    const int Concurrency = 2;

    public bool IsRunning => activeBatches > 0;
    public event PropertyChangedEventHandler? PropertyChanged;
    public event Action? Finished;

    JobQueue()
    {
        Jobs.CollectionChanged += (_, _) => PropertyChanged?.Invoke(this, new(nameof(Jobs)));
    }

    static Dispatcher UI => Application.Current.Dispatcher;

    public IEnumerable<FileKind> KindsPresent => Kinds.All.Where(k => Jobs.Any(j => j.Kind == k));

    public Job? Find(Guid id) => Jobs.FirstOrDefault(j => j.Id == id);

    /// Adds files (folders are expanded). Returns the jobs, reusing ones already listed.
    public List<Job> Add(IEnumerable<string> paths)
    {
        var result = new List<Job>();
        foreach (var path in Expand(paths))
        {
            var existing = Jobs.FirstOrDefault(j => string.Equals(j.Path, path, StringComparison.OrdinalIgnoreCase));
            if (existing is not null)
            {
                if (!existing.IsRunning) existing.Status = JobStatus.Queued;
                result.Add(existing);
                continue;
            }
            var job = new Job(path);
            Jobs.Add(job);
            result.Add(job);
        }
        return result;
    }

    public void Remove(Job job)
    {
        if (!job.IsRunning) Jobs.Remove(job);
    }

    public void Clear()
    {
        foreach (var job in Jobs.Where(j => !j.IsRunning).ToList()) Jobs.Remove(job);
    }

    public void CancelAll()
    {
        foreach (var source in running.ToList()) source.Cancel();
    }

    public static List<string> Expand(IEnumerable<string> paths)
    {
        var result = new List<string>();
        foreach (var raw in paths)
        {
            if (string.IsNullOrWhiteSpace(raw)) continue;
            var path = System.IO.Path.GetFullPath(raw.Trim('"'));
            if (File.Exists(path)) { result.Add(path); continue; }
            if (!Directory.Exists(path)) continue;
            try
            {
                var options = new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = FileAttributes.Hidden | FileAttributes.System, IgnoreInaccessible = true };
                result.AddRange(Directory.EnumerateFiles(path, "*", options).OrderBy(p => p, StringComparer.OrdinalIgnoreCase));
            }
            catch { }
        }
        return result;
    }

    void SetRunning(int delta)
    {
        activeBatches += delta;
        PropertyChanged?.Invoke(this, new(nameof(IsRunning)));
    }

    /// Runs one operation per file, two at a time.
    public async Task Start(IReadOnlyList<(Job Job, JobOperation Operation)> plan, bool reveal)
    {
        if (plan.Count == 0) return;
        foreach (var (job, _) in plan) { job.Status = JobStatus.Queued; job.Fraction = 0; }
        var options = Settings.Current.Options();
        var cts = new CancellationTokenSource();
        running.Add(cts);
        SetRunning(+1);
        try
        {
            var next = 0;
            var workers = Enumerable.Range(0, Math.Min(Concurrency, plan.Count)).Select(async _ =>
            {
                while (true)
                {
                    int index;
                    lock (plan) { index = next++; }
                    if (index >= plan.Count) return;
                    await RunOne(plan[index].Job, plan[index].Operation, options, cts.Token);
                }
            });
            await Task.WhenAll(workers);
        }
        finally
        {
            running.Remove(cts);
            SetRunning(-1);
        }
        if (reveal)
        {
            var outputs = plan.Where(p => p.Job.Status == JobStatus.Done).SelectMany(p => p.Job.Result!.Outputs).ToList();
            if (outputs.Count > 0) Native.RevealInExplorer(outputs);
        }
        Finished?.Invoke();
    }

    async Task RunOne(Job job, JobOperation operation, ConversionOptions options, CancellationToken token)
    {
        if (token.IsCancellationRequested) { Fail(job, "Cancelled"); return; }
        job.Status = JobStatus.Running;
        job.Fraction = 0;
        try
        {
            var result = await Task.Run(() => Engine.Perform(operation, job.Path, options,
                f => UI.BeginInvoke(() => { if (job.IsRunning) job.Fraction = Math.Clamp(f, 0, 1); }), token), token);
            job.Result = result;
            job.Fraction = 1;
            job.Status = JobStatus.Done;
        }
        catch (OperationCanceledException)
        {
            Fail(job, "Cancelled");
        }
        catch (Exception e)
        {
            Fail(job, token.IsCancellationRequested ? "Cancelled" : Describe(e));
        }
    }

    static void Fail(Job job, string message)
    {
        job.Error = message;
        job.Status = JobStatus.Failed;
    }

    public static string Describe(Exception e) => e switch
    {
        ConversionException => e.Message,
        UnauthorizedAccessException => $"Windows didn't allow access: {e.Message}",
        AggregateException { InnerException: { } inner } => Describe(inner),
        _ => e.Message,
    };

    /// Tools that make one file from many (merge, zip, join…).
    public async Task RunBatch(BatchTool tool, IReadOnlyList<Job> jobs, bool reveal)
    {
        if (jobs.Count == 0) return;
        foreach (var job in jobs) { job.Status = JobStatus.Running; job.Fraction = 0; }
        var options = Settings.Current.Options();
        var cts = new CancellationTokenSource();
        running.Add(cts);
        SetRunning(+1);
        try
        {
            var output = await Task.Run(() => Engine.Batch(tool, jobs.Select(j => j.Path).ToList(), options,
                f => UI.BeginInvoke(() => { foreach (var j in jobs) if (j.IsRunning) j.Fraction = Math.Clamp(f, 0, 1); }), cts.Token), cts.Token);
            foreach (var job in jobs) { job.Result = JobResult.Of(output); job.Status = JobStatus.Done; }
            if (reveal) Native.RevealInExplorer([output]);
        }
        catch (Exception e)
        {
            var message = e is OperationCanceledException || cts.IsCancellationRequested ? "Cancelled" : Describe(e);
            foreach (var job in jobs) Fail(job, message);
        }
        finally
        {
            running.Remove(cts);
            SetRunning(-1);
        }
        Finished?.Invoke();
    }
}
