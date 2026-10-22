namespace Transmute;

/// A piece of text with simple formatting. "\n" in Text is a line break, "\t" a tab.
public sealed record Run(string Text, bool Bold = false, bool Italic = false, bool Underline = false, string? Link = null)
{
    public Run With(string text) => this with { Text = text };
}

/// A document's content as Spinform understands it: headings, paragraphs, lists, tables and
/// pictures. Every document reader produces this and every writer consumes it.
public abstract record Block
{
    public sealed record Heading(int Level, List<Run> Runs) : Block;
    public sealed record Paragraph(List<Run> Runs) : Block;
    public sealed record ListItem(bool Ordered, int Level, List<Run> Runs) : Block;
    public sealed record Table(List<List<string>> Rows) : Block;
    public sealed record Picture(byte[] Data, string? Alt = null) : Block;
    public sealed record Code(string Text) : Block;
    public sealed record PageBreak : Block;
}

public sealed class Doc
{
    public string? Title { get; set; }
    public string? Author { get; set; }
    public List<Block> Blocks { get; } = [];

    public static string Text(IEnumerable<Run> runs) => string.Concat(runs.Select(r => r.Text));

    /// All the words, for checks and for formats that only hold plain text.
    public string PlainText()
    {
        var lines = new List<string>();
        foreach (var block in Blocks)
        {
            switch (block)
            {
                case Block.Heading h: lines.Add(Text(h.Runs)); break;
                case Block.Paragraph p: lines.Add(Text(p.Runs)); break;
                case Block.ListItem li: lines.Add(new string(' ', li.Level * 2) + "• " + Text(li.Runs)); break;
                case Block.Table t: lines.AddRange(t.Rows.Select(r => string.Join("\t", r))); break;
                case Block.Code c: lines.Add(c.Text); break;
            }
        }
        return string.Join("\n", lines);
    }

    /// The first heading, or the first words, to use as a title.
    public string GuessTitle(string fallback)
    {
        if (!string.IsNullOrWhiteSpace(Title)) return Title!;
        var heading = Blocks.OfType<Block.Heading>().FirstOrDefault();
        if (heading is not null && Text(heading.Runs).Trim() is { Length: > 0 } h) return h;
        return fallback;
    }

    /// Merges neighbouring runs with the same formatting and drops empty ones.
    public static List<Run> Tidy(IEnumerable<Run> runs)
    {
        var result = new List<Run>();
        foreach (var run in runs)
        {
            if (run.Text.Length == 0) continue;
            if (result.Count > 0 && result[^1] with { Text = "" } == run with { Text = "" })
                result[^1] = result[^1].With(result[^1].Text + run.Text);
            else result.Add(run);
        }
        // Trim the paragraph's outer whitespace.
        if (result.Count > 0) result[0] = result[0].With(result[0].Text.TrimStart(' ', '\n'));
        if (result.Count > 0) result[^1] = result[^1].With(result[^1].Text.TrimEnd(' ', '\n'));
        result.RemoveAll(r => r.Text.Length == 0);
        return result;
    }
}
