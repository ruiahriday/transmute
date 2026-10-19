using System.Globalization;
using System.Net;
using System.Text;
using System.Xml;
using System.Xml.Linq;
using DocumentFormat.OpenXml;
using DocumentFormat.OpenXml.Packaging;
using DocumentFormat.OpenXml.Spreadsheet;
using MigraDoc.DocumentObjectModel;
using Text = DocumentFormat.OpenXml.Spreadsheet.Text;
using Color = MigraDoc.DocumentObjectModel.Color;
using Colors = MigraDoc.DocumentObjectModel.Colors;
using MigraDoc.Rendering;

namespace Transmute;

/// Spreadsheets: reads the first sheet of CSV, TSV, XLSX, XLS and ODS files, and writes CSV, XLSX,
/// HTML and PDF. Values are kept; formulas show their last saved results and formatting isn't kept.
public static class Sheets
{
    public sealed record Table(string Name, List<List<string>> Rows)
    {
        public int Columns => Rows.Count == 0 ? 0 : Rows.Max(r => r.Count);
    }

    public static Table Read(string path)
    {
        var ext = Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        var name = OutputPaths.BaseName(path);
        var table = ext switch
        {
            "csv" => new Table(name, ParseDelimited(DocReaders.ReadAllText(path), null)),
            "tsv" => new Table(name, ParseDelimited(DocReaders.ReadAllText(path), '\t')),
            "xlsx" or "xlsm" => ReadXlsx(path),
            "xls" => ReadXls(path),
            "ods" => ReadOds(path),
            "numbers" => throw new ConversionException("Numbers files can only be opened with Apple's Numbers app. Export it as Excel from Numbers first."),
            _ => throw new ConversionException($"Transmute can't read {ext.ToUpperInvariant()} spreadsheets."),
        };
        // Every row as wide as the widest, so CSV columns line up.
        var width = table.Columns;
        foreach (var row in table.Rows) while (row.Count < width) row.Add("");
        // Drop empty rows at the end.
        while (table.Rows.Count > 0 && table.Rows[^1].All(c => c.Length == 0)) table.Rows.RemoveAt(table.Rows.Count - 1);
        return table;
    }

    public static void Write(Table table, OutputFormat format, string output)
    {
        switch (format)
        {
            case OutputFormat.Csv: File.WriteAllText(output, ToCsv(table.Rows), new UTF8Encoding(false)); break;
            case OutputFormat.Xlsx: WriteXlsx(table, output); break;
            case OutputFormat.Html: File.WriteAllText(output, ToHtml(table), new UTF8Encoding(false)); break;
            case OutputFormat.Pdf: WritePdf(table, output); break;
            default: throw new ConversionException($"Spreadsheets can't be saved as {format.Label()}.");
        }
    }

    // Delimited text

    public static List<List<string>> ParseDelimited(string text, char? delimiter)
    {
        text = text.TrimStart('﻿');
        if (delimiter is null)
        {
            // Many European spreadsheets write semicolons; pick whichever the first line uses more.
            var firstLine = text.Split('\n')[0];
            delimiter = firstLine.Count(c => c == ';') > firstLine.Count(c => c == ',') ? ';' : ',';
        }
        var rows = new List<List<string>>();
        var row = new List<string>();
        var cell = new StringBuilder();
        var quoted = false;
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (quoted)
            {
                if (c == '"')
                {
                    if (i + 1 < text.Length && text[i + 1] == '"') { cell.Append('"'); i++; }
                    else quoted = false;
                }
                else cell.Append(c);
                continue;
            }
            if (c == '"' && cell.Length == 0) quoted = true;
            else if (c == delimiter) { row.Add(cell.ToString()); cell.Clear(); }
            else if (c is '\n' or '\r')
            {
                if (c == '\r' && i + 1 < text.Length && text[i + 1] == '\n') i++;
                row.Add(cell.ToString());
                cell.Clear();
                rows.Add(row);
                row = [];
            }
            else cell.Append(c);
        }
        if (cell.Length > 0 || row.Count > 0)
        {
            row.Add(cell.ToString());
            rows.Add(row);
        }
        return rows;
    }

    public static string ToCsv(IEnumerable<IEnumerable<string>> rows)
    {
        var sb = new StringBuilder();
        foreach (var row in rows)
        {
            sb.Append(string.Join(",", row.Select(cell =>
                cell.IndexOfAny([',', '"', '\n', '\r']) >= 0 || cell.StartsWith(' ') || cell.EndsWith(' ')
                    ? "\"" + cell.Replace("\"", "\"\"") + "\"" : cell)));
            sb.Append('\n');
        }
        return sb.ToString();
    }

    // Excel

    static Table ReadXlsx(string path)
    {
        SpreadsheetDocument book;
        try { book = SpreadsheetDocument.Open(path, false); }
        catch (Exception e) { throw new ConversionException($"Couldn't open {Path.GetFileName(path)} as an Excel workbook: {e.Message}"); }
        using (book)
        {
            var workbook = book.WorkbookPart ?? throw new ConversionException("The workbook is empty.");
            var sheet = workbook.Workbook?.Sheets?.Elements<Sheet>().FirstOrDefault(s => s.State is null || s.State.Value == SheetStateValues.Visible)
                ?? throw new ConversionException("The workbook has no sheets.");
            var part = (WorksheetPart)workbook.GetPartById(sheet.Id!.Value!);
            var shared = workbook.SharedStringTablePart?.SharedStringTable?.Elements<SharedStringItem>().Select(si => si.InnerText).ToList() ?? [];
            var formats = DateFormats(workbook);
            var rows = new List<List<string>>();
            foreach (var row in part.Worksheet?.Descendants<Row>() ?? [])
            {
                var index = (int)(row.RowIndex?.Value ?? (uint)(rows.Count + 1)) - 1;
                while (rows.Count <= index) rows.Add([]);
                var cells = rows[index];
                foreach (var cell in row.Elements<Cell>())
                {
                    var col = cell.CellReference?.Value is { } reference ? ColumnIndex(reference) : cells.Count;
                    while (cells.Count <= col) cells.Add("");
                    cells[col] = CellText(cell, shared, formats);
                }
            }
            return new Table(sheet.Name?.Value ?? "Sheet1", rows);
        }
    }

    /// Style indexes whose number format is a date.
    static HashSet<uint> DateFormats(WorkbookPart workbook)
    {
        var result = new HashSet<uint>();
        var stylesheet = workbook.WorkbookStylesPart?.Stylesheet;
        var cellFormats = stylesheet?.CellFormats?.Elements<CellFormat>().ToList();
        if (cellFormats is null) return result;
        var custom = stylesheet!.NumberingFormats?.Elements<NumberingFormat>()
            .Where(n => n.NumberFormatId is not null)
            .ToDictionary(n => n.NumberFormatId!.Value, n => n.FormatCode?.Value ?? "") ?? [];
        for (var i = 0; i < cellFormats.Count; i++)
        {
            var id = cellFormats[i].NumberFormatId?.Value ?? 0;
            var isDate = id is >= 14 and <= 22 or >= 45 and <= 47;
            if (custom.TryGetValue(id, out var code))
            {
                var stripped = System.Text.RegularExpressions.Regex.Replace(code, "\"[^\"]*\"|\\[[^\\]]*\\]", "");
                isDate = stripped.IndexOfAny(['y', 'd', 'h', 's']) >= 0 || stripped.Contains("mm");
            }
            if (isDate) result.Add((uint)i);
        }
        return result;
    }

    static string CellText(Cell cell, List<string> shared, HashSet<uint> dates)
    {
        var type = cell.DataType?.Value;
        var raw = cell.CellValue?.Text ?? "";
        if (type == CellValues.SharedString) return int.TryParse(raw, out var i) && i < shared.Count ? shared[i] : "";
        if (type == CellValues.InlineString) return cell.InlineString?.InnerText ?? "";
        if (type == CellValues.Boolean) return raw == "1" ? "TRUE" : "FALSE";
        if (type == CellValues.String || type == CellValues.Error) return raw;
        if (raw.Length > 0 && cell.StyleIndex?.Value is { } style && dates.Contains(style)
            && double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out var serial) && serial is > 0 and < 2958466)
        {
            var date = DateTime.FromOADate(serial);
            return date.TimeOfDay == TimeSpan.Zero ? date.ToString("yyyy-MM-dd") : date.ToString("yyyy-MM-dd HH:mm:ss");
        }
        if (double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out var number))
            return number.ToString(CultureInfo.InvariantCulture);
        return raw;
    }

    static int ColumnIndex(string reference)
    {
        var index = 0;
        foreach (var c in reference)
        {
            if (!char.IsLetter(c)) break;
            index = index * 26 + (char.ToUpperInvariant(c) - 'A' + 1);
        }
        return Math.Max(0, index - 1);
    }

    static string ColumnName(int index)
    {
        var name = "";
        for (index++; index > 0; index = (index - 1) / 26) name = (char)('A' + (index - 1) % 26) + name;
        return name;
    }

    public static void WriteXlsx(Table table, string output)
    {
        using var book = SpreadsheetDocument.Create(output, SpreadsheetDocumentType.Workbook);
        var workbook = book.AddWorkbookPart();
        workbook.Workbook = new Workbook();
        var sheetPart = workbook.AddNewPart<WorksheetPart>();
        var data = new SheetData();
        for (var r = 0; r < table.Rows.Count; r++)
        {
            var row = new Row { RowIndex = (uint)(r + 1) };
            for (var c = 0; c < table.Rows[r].Count; c++)
            {
                var text = table.Rows[r][c];
                if (text.Length == 0) continue;
                var cell = new Cell { CellReference = ColumnName(c) + (r + 1) };
                if (IsPlainNumber(text, out var number))
                {
                    cell.CellValue = new CellValue(number.ToString(CultureInfo.InvariantCulture));
                }
                else
                {
                    cell.DataType = CellValues.InlineString;
                    cell.InlineString = new InlineString(new Text(text) { Space = SpaceProcessingModeValues.Preserve });
                }
                row.Append(cell);
            }
            data.Append(row);
        }
        sheetPart.Worksheet = new Worksheet(data);
        var sheetName = new string(table.Name.Where(ch => !"[]:*?/\\".Contains(ch)).ToArray());
        if (sheetName.Length == 0) sheetName = "Sheet1";
        if (sheetName.Length > 31) sheetName = sheetName[..31];
        workbook.Workbook.AppendChild(new DocumentFormat.OpenXml.Spreadsheet.Sheets(new Sheet { Id = workbook.GetIdOfPart(sheetPart), SheetId = 1, Name = sheetName }));
        workbook.Workbook.Save();
    }

    /// "12", "0.8", "-3.5e2", but not "007" or "1,000", which would lose their look as numbers.
    static bool IsPlainNumber(string text, out double number)
    {
        number = 0;
        if (text.Length > 15 || text.Trim() != text) return false;
        if (text.Length > 1 && text[0] == '0' && text[1] != '.') return false;
        return double.TryParse(text, NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint | NumberStyles.AllowExponent,
            CultureInfo.InvariantCulture, out number) && double.IsFinite(number);
    }

    static Table ReadXls(string path)
    {
        CodePages.Register();
        try
        {
            using var stream = File.OpenRead(path);
            using var reader = ExcelDataReader.ExcelReaderFactory.CreateReader(stream);
            var rows = new List<List<string>>();
            while (reader.Read())
            {
                var row = new List<string>();
                for (var i = 0; i < reader.FieldCount; i++)
                {
                    var value = reader.GetValue(i);
                    row.Add(value switch
                    {
                        null => "",
                        double d => d.ToString(CultureInfo.InvariantCulture),
                        DateTime t => t.TimeOfDay == TimeSpan.Zero ? t.ToString("yyyy-MM-dd") : t.ToString("yyyy-MM-dd HH:mm:ss"),
                        bool b => b ? "TRUE" : "FALSE",
                        _ => Convert.ToString(value, CultureInfo.InvariantCulture) ?? "",
                    });
                }
                while (row.Count > 0 && row[^1].Length == 0) row.RemoveAt(row.Count - 1);
                rows.Add(row);
            }
            return new Table(reader.Name ?? "Sheet1", rows);
        }
        catch (Exception e) when (e is not ConversionException)
        {
            throw new ConversionException($"Couldn't read {Path.GetFileName(path)} as an Excel workbook: {e.Message}");
        }
    }

    // OpenDocument spreadsheet

    static readonly XNamespace TableNs = "urn:oasis:names:tc:opendocument:xmlns:table:1.0";
    static readonly XNamespace OfficeNs = "urn:oasis:names:tc:opendocument:xmlns:office:1.0";
    static readonly XNamespace TextNs = "urn:oasis:names:tc:opendocument:xmlns:text:1.0";

    static Table ReadOds(string path)
    {
        using var zip = DocReaders.OpenZip(path);
        var content = DocReaders.LoadXml(zip, "content.xml") ?? throw new ConversionException("The spreadsheet has no content.");
        var sheet = content.Descendants(TableNs + "table").FirstOrDefault() ?? throw new ConversionException("The spreadsheet has no sheets.");
        var rows = new List<List<string>>();
        foreach (var row in sheet.Descendants(TableNs + "table-row"))
        {
            var repeatRows = Math.Min(1000, (int?)row.Attribute(TableNs + "number-rows-repeated") ?? 1);
            var cells = new List<string>();
            foreach (var cell in row.Elements().Where(e => e.Name == TableNs + "table-cell" || e.Name == TableNs + "covered-table-cell"))
            {
                var repeat = Math.Min(1000, (int?)cell.Attribute(TableNs + "number-columns-repeated") ?? 1);
                var type = (string?)cell.Attribute(OfficeNs + "value-type");
                var value = type switch
                {
                    "float" or "percentage" or "currency" => (string?)cell.Attribute(OfficeNs + "value"),
                    "date" => (string?)cell.Attribute(OfficeNs + "date-value"),
                    "boolean" => (string?)cell.Attribute(OfficeNs + "boolean-value") == "true" ? "TRUE" : "FALSE",
                    _ => null,
                } ?? string.Join("\n", cell.Elements(TextNs + "p").Select(p => p.Value));
                for (var i = 0; i < repeat; i++) cells.Add(value);
            }
            while (cells.Count > 0 && cells[^1].Length == 0) cells.RemoveAt(cells.Count - 1);
            for (var i = 0; i < repeatRows; i++) rows.Add(cells.ToList());
        }
        return new Table((string?)sheet.Attribute(TableNs + "name") ?? "Sheet1", rows);
    }

    // HTML and PDF

    static string ToHtml(Table table)
    {
        var sb = new StringBuilder();
        sb.Append("<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n");
        sb.Append($"<title>{WebUtility.HtmlEncode(table.Name)}</title>\n");
        sb.Append("<style>body{font-family:\"Segoe UI\",Arial,sans-serif;margin:2em}table{border-collapse:collapse}td{border:1px solid #bbb;padding:4px 8px}td.n{text-align:right}tr:first-child td{font-weight:600;background:#f2f2f2}</style>\n");
        sb.Append("</head>\n<body>\n<table>\n");
        foreach (var row in table.Rows)
        {
            sb.Append("<tr>");
            foreach (var cell in row)
                sb.Append(IsPlainNumber(cell, out _) ? "<td class=\"n\">" : "<td>").Append(WebUtility.HtmlEncode(cell).Replace("\n", "<br>")).Append("</td>");
            sb.Append("</tr>\n");
        }
        sb.Append("</table>\n</body>\n</html>\n");
        return sb.ToString();
    }

    static void WritePdf(Table table, string output)
    {
        Fonts.Install();
        var document = new Document();
        document.Info.Title = table.Name;
        var normal = document.Styles[StyleNames.Normal]!;
        normal.Font.Name = Fonts.Sans;
        normal.Font.Size = table.Columns > 8 ? 7 : 9;
        var section = document.AddSection();
        section.PageSetup = document.DefaultPageSetup.Clone();
        var landscape = table.Columns > 5;
        section.PageSetup.PageWidth = Unit.FromCentimeter(landscape ? 29.7 : 21);
        section.PageSetup.PageHeight = Unit.FromCentimeter(landscape ? 21 : 29.7);
        section.PageSetup.LeftMargin = section.PageSetup.RightMargin = Unit.FromCentimeter(1.5);
        section.PageSetup.TopMargin = section.PageSetup.BottomMargin = Unit.FromCentimeter(1.5);
        var usable = (landscape ? 29.7 : 21) - 3;
        var title = section.AddParagraph(table.Name);
        title.Format.Font.Size = 14;
        title.Format.Font.Bold = true;
        title.Format.SpaceAfter = Unit.FromPoint(8);
        var columns = Math.Max(1, table.Columns);
        var pdfTable = section.AddTable();
        pdfTable.Borders.Width = 0.5;
        pdfTable.Borders.Color = Colors.Gray;
        for (var c = 0; c < columns; c++) pdfTable.AddColumn(Unit.FromCentimeter(usable / columns));
        for (var r = 0; r < table.Rows.Count; r++)
        {
            var row = pdfTable.AddRow();
            if (r == 0)
            {
                row.HeadingFormat = true;
                row.Format.Font.Bold = true;
                row.Shading.Color = new Color(242, 242, 242);
            }
            for (var c = 0; c < columns; c++)
            {
                var text = c < table.Rows[r].Count ? table.Rows[r][c] : "";
                var p = row.Cells[c].AddParagraph(text);
                if (IsPlainNumber(text, out _)) p.Format.Alignment = ParagraphAlignment.Right;
            }
        }
        var renderer = new PdfDocumentRenderer { Document = document };
        renderer.RenderDocument();
        renderer.PdfDocument.Save(output);
    }
}
