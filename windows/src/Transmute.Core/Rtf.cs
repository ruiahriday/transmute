using System.Globalization;
using System.Text;

namespace Transmute;

/// Rich Text Format: a small reader (text, bold, italic, underline, paragraphs, tables, outline
/// headings) and a writer.
public static class Rtf
{
    sealed class State
    {
        public bool Bold, Italic, Underline, Skip;
        public int UnicodeSkip = 1;
        public State Copy() => (State)MemberwiseClone();
    }

    static readonly HashSet<string> SkippedDestinations =
    [
        "fonttbl", "colortbl", "stylesheet", "info", "pict", "header", "footer", "headerl", "headerr", "headerf",
        "footerl", "footerr", "footerf", "listtable", "listoverridetable", "generator", "themedata", "colorschememapping",
        "latentstyles", "datastore", "xmlnstbl", "rsidtbl", "mmathpr", "pgdsctbl", "filetbl", "revtbl", "object",
        "fldinst", "footnote", "annotation", "comment", "bkmkstart", "bkmkend", "xe", "tc", "shppict", "nonshppict",
        "expandedcolortbl", "listtext", "pntext", "pntxta", "pntxtb", "userprops", "operator", "creatim", "revtim",
    ];

    public static Doc Read(string rtf)
    {
        CodePages.Register();
        var doc = new Doc();
        if (!rtf.TrimStart().StartsWith("{\\rtf", StringComparison.Ordinal))
            throw new ConversionException("This file isn't valid RTF.");
        var encoding = Encoding.GetEncoding(1252);
        var stack = new Stack<State>();
        var state = new State();
        var runs = new List<Run>();
        var text = new StringBuilder();
        var bytes = new List<byte>();
        var outline = -1;
        var inTable = false;
        var row = new List<string>();
        var rows = new List<List<string>>();
        var cell = new StringBuilder();
        var skipChars = 0;
        var fieldResultDepth = new Stack<bool>();

        void FlushBytes()
        {
            if (bytes.Count == 0) return;
            Append(encoding.GetString(bytes.ToArray()));
            bytes.Clear();
        }
        void Append(string s)
        {
            if (state.Skip) return;
            if (inTable) { cell.Append(s); return; }
            text.Append(s);
        }
        void FlushRun()
        {
            FlushBytes();
            if (text.Length == 0) return;
            runs.Add(new Run(text.ToString(), state.Bold, state.Italic, state.Underline));
            text.Clear();
        }
        void EndParagraph()
        {
            FlushRun();
            var tidy = Doc.Tidy(runs);
            runs.Clear();
            if (tidy.Count == 0) return;
            if (outline >= 0 && outline < 6) doc.Blocks.Add(new Block.Heading(outline + 1, tidy.Select(r => r with { Bold = false }).ToList()));
            else
            {
                var first = tidy[0].Text;
                if (first.StartsWith("•\t") || first.StartsWith("• ") || first.StartsWith("·\t"))
                {
                    tidy[0] = tidy[0].With(first[2..]);
                    doc.Blocks.Add(new Block.ListItem(false, 0, Doc.Tidy(tidy)));
                }
                else doc.Blocks.Add(new Block.Paragraph(tidy));
            }
        }
        void EndTable()
        {
            if (rows.Count > 0) doc.Blocks.Add(new Block.Table(rows.Select(r => r.ToList()).ToList()));
            rows.Clear();
            inTable = false;
        }

        var i = 0;
        // Skip "{\rtf1" handled as normal control word.
        while (i < rtf.Length)
        {
            var c = rtf[i];
            if (c == '{')
            {
                FlushRun();
                stack.Push(state.Copy());
                i++;
                // "{\*\destination" is an optional destination we don't know: skip it.
                if (i + 1 < rtf.Length && rtf[i] == '\\' && rtf[i + 1] == '*') state.Skip = true;
                continue;
            }
            if (c == '}')
            {
                FlushRun();
                if (stack.Count > 0) state = stack.Pop();
                i++;
                continue;
            }
            if (c == '\\')
            {
                i++;
                if (i >= rtf.Length) break;
                var next = rtf[i];
                if (next is '\\' or '{' or '}')
                {
                    if (skipChars > 0) { skipChars--; i++; continue; }
                    FlushBytes(); Append(next.ToString()); i++; continue;
                }
                if (next == '\'')
                {
                    if (i + 2 < rtf.Length && byte.TryParse(rtf.AsSpan(i + 1, 2), NumberStyles.HexNumber, null, out var b))
                    {
                        if (skipChars > 0) skipChars--;
                        else if (!state.Skip) bytes.Add(b);
                    }
                    i += 3;
                    continue;
                }
                if (next == '~') { FlushBytes(); Append(" "); i++; continue; }
                if (next == '_') { FlushBytes(); Append("-"); i++; continue; }
                if (next == '-') { i++; continue; }
                if (next == '*') { state.Skip = true; i++; continue; }
                if (next is '\n' or '\r') { EndParagraph(); i++; continue; }
                if (!char.IsLetter(next)) { i++; continue; }
                var start = i;
                while (i < rtf.Length && char.IsLetter(rtf[i])) i++;
                var word = rtf[start..i];
                int? param = null;
                var numStart = i;
                if (i < rtf.Length && (rtf[i] == '-' || char.IsDigit(rtf[i])))
                {
                    i++;
                    while (i < rtf.Length && char.IsDigit(rtf[i])) i++;
                    if (int.TryParse(rtf.AsSpan(numStart, i - numStart), out var p)) param = p;
                }
                if (i < rtf.Length && rtf[i] == ' ') i++;

                if (SkippedDestinations.Contains(word)) { FlushRun(); state.Skip = true; continue; }
                switch (word)
                {
                    case "ansicpg" when param is { } cp:
                        try { encoding = Encoding.GetEncoding(cp); } catch { }
                        break;
                    case "fldrslt": state.Skip = false; break;
                    case "par": case "sect":
                        if (inTable) cell.Append(' ');
                        else EndParagraph();
                        break;
                    case "page":
                        EndParagraph();
                        doc.Blocks.Add(new Block.PageBreak());
                        break;
                    case "pard":
                        FlushRun();
                        outline = -1;
                        break;
                    case "line": FlushBytes(); Append("\n"); break;
                    case "tab": FlushBytes(); Append("\t"); break;
                    case "bullet": FlushBytes(); Append("•"); break;
                    case "emdash": FlushBytes(); Append("—"); break;
                    case "endash": FlushBytes(); Append("–"); break;
                    case "lquote": FlushBytes(); Append("‘"); break;
                    case "rquote": FlushBytes(); Append("’"); break;
                    case "ldblquote": FlushBytes(); Append("“"); break;
                    case "rdblquote": FlushBytes(); Append("”"); break;
                    case "b": FlushRun(); state.Bold = param != 0; break;
                    case "i": FlushRun(); state.Italic = param != 0; break;
                    case "ul": FlushRun(); state.Underline = param != 0; break;
                    case "ulnone": FlushRun(); state.Underline = false; break;
                    case "plain": FlushRun(); state.Bold = state.Italic = state.Underline = false; break;
                    case "outlinelevel": outline = param ?? -1; break;
                    case "uc": state.UnicodeSkip = param ?? 1; break;
                    case "u" when param is { } code:
                        FlushBytes();
                        Append(((char)(code < 0 ? code + 65536 : code)).ToString());
                        skipChars = state.UnicodeSkip;
                        break;
                    case "intbl":
                        if (!inTable) { EndParagraph(); inTable = true; }
                        break;
                    case "cell":
                        FlushBytes();
                        row.Add(cell.ToString().Trim());
                        cell.Clear();
                        break;
                    case "row":
                        if (row.Count > 0) rows.Add(row.ToList());
                        row.Clear();
                        break;
                    case "trowd": inTable = true; break;
                }
                // Text after a \pard that isn't in a table ends the table.
                if (word == "pard" && inTable)
                {
                    var look = i;
                    // A table continues when the next paragraph says \intbl before any text.
                    var probe = rtf.IndexOf("\\intbl", look, StringComparison.Ordinal);
                    var nextPar = rtf.IndexOf("\\par", look, StringComparison.Ordinal);
                    if (probe < 0 || (nextPar >= 0 && nextPar < probe)) EndTable();
                }
                continue;
            }
            if (c is '\r' or '\n') { i++; continue; }
            if (skipChars > 0) { skipChars--; i++; continue; }
            if (!state.Skip)
            {
                if (c < 128) { FlushBytes(); Append(c.ToString()); }
                else { FlushBytes(); Append(c.ToString()); }
            }
            i++;
        }
        EndParagraph();
        if (inTable) EndTable();
        return doc;
    }

    // Writing

    public static string Write(Doc doc)
    {
        var sb = new StringBuilder();
        sb.Append(@"{\rtf1\ansi\ansicpg1252\deff0\uc1");
        sb.Append(@"{\fonttbl{\f0\fswiss\fcharset0 Arial;}{\f1\fmodern\fcharset0 Consolas;}}");
        sb.Append(@"{\colortbl;\red0\green0\blue238;}");
        if (doc.Title is { } title) sb.Append(@"{\info{\title ").Append(Escape(title)).Append("}}");
        sb.Append(@"\paperw11906\paperh16838\margl1134\margr1134\margt1134\margb1134\f0\fs22").Append('\n');
        var number = 0;
        foreach (var block in doc.Blocks)
        {
            if (block is not Block.ListItem { Ordered: true }) number = 0;
            switch (block)
            {
                case Block.Heading h:
                    var size = h.Level switch { 1 => 40, 2 => 32, 3 => 28, _ => 24 };
                    sb.Append($@"\pard\sb240\sa120\keepn\outlinelevel{h.Level - 1}\b\fs{size} ");
                    AppendRuns(sb, h.Runs);
                    sb.Append(@"\b0\fs22\par").Append('\n');
                    break;
                case Block.Paragraph p:
                    sb.Append(@"\pard\sa160 ");
                    AppendRuns(sb, p.Runs);
                    sb.Append(@"\par").Append('\n');
                    break;
                case Block.ListItem li:
                    var indent = 360 + li.Level * 360;
                    var marker = li.Ordered ? $"{++number}." : @"\bullet";
                    sb.Append($@"\pard\sa80\li{indent}\fi-360 {marker}\tab ");
                    AppendRuns(sb, li.Runs);
                    sb.Append(@"\par").Append('\n');
                    break;
                case Block.Code code:
                    sb.Append(@"\pard\sa160\f1\fs20 ");
                    sb.Append(Escape(code.Text).Replace("\n", "\\line "));
                    sb.Append(@"\f0\fs22\par").Append('\n');
                    break;
                case Block.Table t:
                    var columns = t.Rows.Max(r => r.Count);
                    var width = 9638 / Math.Max(1, columns);
                    foreach (var row in t.Rows)
                    {
                        sb.Append(@"\trowd\trgaph108");
                        for (var c = 1; c <= columns; c++)
                            sb.Append(@"\clbrdrt\brdrs\clbrdrl\brdrs\clbrdrb\brdrs\clbrdrr\brdrs\cellx").Append(c * width);
                        sb.Append(@"\pard\intbl ");
                        for (var c = 0; c < columns; c++)
                            sb.Append(Escape(c < row.Count ? row[c] : "")).Append(@"\cell ");
                        sb.Append(@"\row").Append('\n');
                    }
                    sb.Append(@"\pard\par").Append('\n');
                    break;
                case Block.Picture pic:
                    try
                    {
                        using var image = new ImageMagick.MagickImage(pic.Data);
                        image.Strip();
                        var png = image.ToByteArray(ImageMagick.MagickFormat.Png);
                        // Twips at 96 dpi, at most 16 cm wide.
                        double w = image.Width * 15, h = image.Height * 15;
                        if (w > 9000) { h *= 9000 / w; w = 9000; }
                        sb.Append($@"\pard\sa160{{\pict\pngblip\picw{image.Width}\pich{image.Height}\picwgoal{(int)w}\pichgoal{(int)h} ");
                        sb.Append(Convert.ToHexString(png)).Append(@"}\par").Append('\n');
                    }
                    catch { }
                    break;
                case Block.PageBreak:
                    sb.Append(@"\page").Append('\n');
                    break;
            }
        }
        sb.Append('}');
        return sb.ToString();
    }

    static void AppendRuns(StringBuilder sb, IEnumerable<Run> runs)
    {
        foreach (var run in runs)
        {
            var open = (run.Bold ? @"\b" : "") + (run.Italic ? @"\i" : "") + (run.Underline || run.Link is not null ? @"\ul" : "");
            if (run.Link is not null)
            {
                sb.Append(@"{\field{\*\fldinst{HYPERLINK """).Append(Escape(run.Link)).Append(@"""}}{\fldrslt{\cf1").Append(open).Append(' ')
                    .Append(Escape(run.Text)).Append("}}}");
                continue;
            }
            if (open.Length > 0) sb.Append('{').Append(open).Append(' ');
            sb.Append(Escape(run.Text));
            if (open.Length > 0) sb.Append('}');
        }
    }

    public static string Escape(string text)
    {
        var sb = new StringBuilder();
        foreach (var c in text)
        {
            switch (c)
            {
                case '\\': sb.Append(@"\\"); break;
                case '{': sb.Append(@"\{"); break;
                case '}': sb.Append(@"\}"); break;
                case '\n': sb.Append(@"\line "); break;
                case '\t': sb.Append(@"\tab "); break;
                case '\r': break;
                default:
                    if (c < 128) sb.Append(c);
                    else sb.Append(@"\u").Append(((short)c).ToString(CultureInfo.InvariantCulture)).Append('?');
                    break;
            }
        }
        return sb.ToString();
    }
}
