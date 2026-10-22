using System.Text.Json;
using System.Text.Json.Serialization;

namespace Transmute;

public enum CaptureKind { Screenshot, Recording, Text }

/// One remembered capture. `File` is the copy kept in the history folder; `SavedPath` is where
/// it was also saved for the user, if anywhere.
public sealed record HistoryItem
{
    public string Id { get; init; } = Guid.NewGuid().ToString("N");
    public CaptureKind Kind { get; init; }
    public DateTime Created { get; init; } = DateTime.Now;
    public string File { get; init; } = "";
    public int Width { get; init; }
    public int Height { get; init; }
    public double Seconds { get; init; }
    public string? SavedPath { get; init; }
    /// For text: the first words, for the grid.
    public string? Preview { get; init; }
}

/// Recent captures and recordings, copied into a folder of their own with an index beside them
/// (%LOCALAPPDATA%\Spinform\History in the app). Thread-safe.
public sealed class CaptureHistory
{
    public string Folder { get; }
    string IndexPath => Path.Combine(Folder, "index.json");
    readonly object gate = new();
    List<HistoryItem> items = [];

    public event Action? Changed;

    public CaptureHistory(string folder)
    {
        Folder = folder;
        Load();
    }

    /// Newest first.
    public IReadOnlyList<HistoryItem> Items
    {
        get { lock (gate) return items.OrderByDescending(i => i.Created).ToList(); }
    }

    public string PathOf(HistoryItem item) => Path.Combine(Folder, item.File);
    public string ThumbnailOf(HistoryItem item) => Path.Combine(Folder, "thumbs", item.Id + ".png");

    void Load()
    {
        lock (gate)
        {
            try
            {
                if (System.IO.File.Exists(IndexPath))
                    items = JsonSerializer.Deserialize<List<HistoryItem>>(System.IO.File.ReadAllText(IndexPath), Json) ?? [];
            }
            catch { items = []; }
            // Forget entries whose file has gone.
            items.RemoveAll(i => !System.IO.File.Exists(PathOf(i)));
        }
    }

    void Save()
    {
        Directory.CreateDirectory(Folder);
        var temp = IndexPath + ".tmp";
        System.IO.File.WriteAllText(temp, JsonSerializer.Serialize(items, Json));
        System.IO.File.Move(temp, IndexPath, true);
    }

    static readonly JsonSerializerOptions Json = new() { WriteIndented = true, Converters = { new JsonStringEnumConverter() } };

    /// Copies (or moves) a file into the history and remembers it.
    public HistoryItem Add(string source, CaptureKind kind, int width = 0, int height = 0, double seconds = 0, string? savedPath = null,
        bool move = false, string? preview = null, DateTime? created = null)
    {
        Directory.CreateDirectory(Folder);
        var when = created ?? DateTime.Now;
        var ext = Path.GetExtension(source);
        var name = OutputPaths.Unique(Folder, $"{kind} {when:yyyy-MM-dd HH.mm.ss}", ext.TrimStart('.'));
        if (move) System.IO.File.Move(source, name);
        else System.IO.File.Copy(source, name);
        var item = new HistoryItem
        {
            Kind = kind, Created = when, File = Path.GetFileName(name), Width = width, Height = height, Seconds = seconds,
            SavedPath = savedPath, Preview = preview,
        };
        lock (gate)
        {
            items.Add(item);
            Save();
        }
        Changed?.Invoke();
        return item;
    }

    public void Delete(string id)
    {
        HistoryItem? item;
        lock (gate)
        {
            item = items.FirstOrDefault(i => i.Id == id);
            if (item is null) return;
            items.Remove(item);
            Save();
        }
        OutputPaths.TryDelete(PathOf(item));
        OutputPaths.TryDelete(ThumbnailOf(item));
        Changed?.Invoke();
    }

    public void Clear()
    {
        foreach (var item in Items) Delete(item.Id);
    }

    /// Removes captures older than `days` (0 keeps none, a negative number keeps them all).
    /// Returns how many went.
    public int Prune(int days, DateTime? now = null)
    {
        if (days < 0) return 0;
        var limit = (now ?? DateTime.Now) - TimeSpan.FromDays(days);
        var old = Items.Where(i => days == 0 || i.Created < limit).ToList();
        foreach (var item in old) Delete(item.Id);
        return old.Count;
    }

    public static string Describe(HistoryItem item) => item.Kind switch
    {
        CaptureKind.Recording => $"{Duration(item.Seconds)} · {item.Width} × {item.Height}",
        CaptureKind.Text => item.Preview ?? "Text",
        _ => $"{item.Width} × {item.Height}",
    };

    public static string Duration(double seconds)
    {
        var t = TimeSpan.FromSeconds(Math.Max(0, seconds));
        return t.TotalHours >= 1 ? $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}" : $"{t.Minutes}:{t.Seconds:00}";
    }

    /// "Today 14:32", "Yesterday 09:05", "12 Oct 18:20".
    public static string When(DateTime created, DateTime? now = null)
    {
        var today = (now ?? DateTime.Now).Date;
        var time = created.ToString("HH:mm");
        if (created.Date == today) return $"Today {time}";
        if (created.Date == today.AddDays(-1)) return $"Yesterday {time}";
        return created.ToString(created.Year == today.Year ? "d MMM" : "d MMM yyyy") + " " + time;
    }
}
