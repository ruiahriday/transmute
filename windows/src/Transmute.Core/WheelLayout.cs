namespace Transmute;

public enum WheelKind { Convert, Tools, Actions }

/// Which bubbles each drag wheel shows, and where. A layout is a list of item ids going clockwise
/// from the top; "gap" leaves a position empty so the others stay where the user put them.
/// Ids: "convert:pdf", "tool:half" (and quarter, clean, split, merge, topdf, qr, zip),
/// "action:float" (and copy, copypath, terminal, move, show). Any item can go on any wheel.
public static class WheelLayout
{
    public const string Gap = "gap";
    public const int MaxSlots = 12;

    public static readonly string[] Tools = ["half", "quarter", "clean", "split", "merge", "topdf", "qr", "zip"];
    public static readonly string[] Actions = ["float", "copy", "copypath", "terminal", "move", "show"];

    /// Where a customized layout is kept in settings: "convert.document", "tools.image"…
    public static string Key(WheelKind wheel, FileKind kind) => $"{wheel}.{kind}".ToLowerInvariant();

    public static string ConvertId(OutputFormat format) => "convert:" + format.ToString().ToLowerInvariant();

    public static OutputFormat? Format(string id) =>
        id.StartsWith("convert:") && Enum.TryParse<OutputFormat>(id["convert:".Length..], true, out var format) ? format : null;

    /// The layout Transmute ships with, the same as before wheels could be customized.
    public static List<string> Default(WheelKind wheel, FileKind kind) => wheel switch
    {
        WheelKind.Convert => kind.ConvertTargets().Take(10).Select(ConvertId).ToList(),
        WheelKind.Tools => Tools.Where(t => ToolFits(t, [kind], 2)).Select(t => "tool:" + t).ToList(),
        _ => Actions.Select(a => "action:" + a).ToList(),
    };

    /// Everything that can go on a wheel for this kind of file, formats first, then tools, then actions.
    public static List<string> Available(FileKind kind) =>
    [
        .. kind.ConvertTargets().Select(ConvertId),
        .. Tools.Where(t => ToolFits(t, [kind], 2)).Select(t => "tool:" + t),
        .. Actions.Select(a => "action:" + a),
    ];

    /// Whether an item works for every one of these files.
    public static bool Fits(string id, IReadOnlyList<FileKind> kinds)
    {
        if (id == Gap) return true;
        if (Format(id) is { } format) return kinds.All(k => k.ConvertTargets().Contains(format));
        if (id.StartsWith("tool:")) return ToolFits(id["tool:".Length..], kinds, kinds.Count);
        return id.StartsWith("action:") && Actions.Contains(id["action:".Length..]);
    }

    static bool ToolFits(string tool, IReadOnlyList<FileKind> kinds, int count) => tool switch
    {
        "half" or "quarter" => kinds.All(k => k.CanCompress()),
        "clean" => kinds.All(k => k.CanStripMetadata()),
        "split" => kinds.All(k => k == FileKind.Pdf),
        "merge" => kinds.All(k => k == FileKind.Pdf) && count > 1,
        "topdf" or "qr" => kinds.All(k => k == FileKind.Image),
        "zip" => true,
        _ => false,
    };

    /// A saved layout cleaned up: unknown or repeated items dropped and at most MaxSlots positions.
    /// Empty positions stay, even at the end: they decide where the others sit.
    public static List<string> Clean(IEnumerable<string> ids, FileKind kind)
    {
        var available = Available(kind);
        var seen = new HashSet<string>();
        return ids.Where(id => id == Gap || (available.Contains(id) && seen.Add(id))).Take(MaxSlots).ToList();
    }

    /// The positions to draw for these files: the user's layout for the first file's kind (or the
    /// default), with anything that doesn't suit all of the files left out. In a customized
    /// layout those become empty positions, so the rest stay where the user put them.
    /// Empty when nothing is left.
    public static List<string> Resolve(WheelKind wheel, IReadOnlyList<FileKind> kinds, IReadOnlyDictionary<string, List<string>>? custom)
    {
        if (kinds.Count == 0) return [];
        if (custom is not null && custom.TryGetValue(Key(wheel, kinds[0]), out var saved))
        {
            var slots = Clean(saved, kinds[0]).Select(id => Fits(id, kinds) ? id : Gap).ToList();
            return slots.Any(id => id != Gap) ? slots : [];
        }
        // The default for mixed files: the formats they have in common, as before.
        if (wheel == WheelKind.Convert)
            return kinds[0].ConvertTargets().Select(ConvertId).Where(id => Fits(id, kinds)).Take(10).ToList();
        return Default(wheel, kinds[0]).Where(id => Fits(id, kinds)).ToList();
    }
}
