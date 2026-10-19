#!/bin/bash
# Creates one sample file of every supported kind, for the self-test.
#   scripts/make-fixtures.sh <output-dir> <path-to-ffmpeg>
set -euo pipefail
DIR="$1"
FF="$2"
mkdir -p "$DIR"
cd "$DIR"
ff() { "$FF" -hide_banner -loglevel error -nostdin -y "$@"; }

# Images
ff -f lavfi -i testsrc=size=640x480 -frames:v 1 sample.png
sips -s format jpeg sample.png --out photo.jpg >/dev/null
sips -s format heic sample.png --out phone.heic >/dev/null 2>&1 || true
heic_info=$(sips -g pixelWidth phone.heic 2>/dev/null || true)
case "$heic_info" in
  *"pixelWidth: "[1-9]*) ;;
  *) rm -f phone.heic phone.heic.sb-*; echo "warning: this machine can't encode HEIC; no HEIC fixture" ;;
esac
sips -s format tiff sample.png --out scan.tiff >/dev/null
ff -f lavfi -i testsrc=size=320x240:rate=10 -t 1 -loop 0 anim.gif
ff -i sample.png -c:v libwebp web.webp
cat > logo.svg <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="200" height="120" viewBox="0 0 200 120">
  <rect width="200" height="120" rx="16" fill="#2c7be5"/>
  <circle cx="60" cy="60" r="30" fill="#ffffff"/>
  <text x="105" y="70" font-family="Helvetica" font-size="28" fill="#ffffff">SVG</text>
</svg>
SVG

# Video and audio
ff -f lavfi -i testsrc=duration=3:size=320x240:rate=25 -f lavfi -i sine=frequency=440:duration=3 \
   -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest clip.mp4
ff -i clip.mp4 -c copy movie.mkv
ff -f lavfi -i sine=frequency=440:duration=3 tone.wav
ff -i tone.wav -c:a libmp3lame song.mp3

# Documents
printf 'Hello from Transmute\n\nThis is a test document with a few lines of text.\nSecond paragraph.\n' > note.txt
cp note.txt readme.md
textutil -convert rtf note.txt -output letter.rtf
textutil -convert docx note.txt -output report.docx
textutil -convert html note.txt -output page.html

# Spreadsheets: a CSV, and an XLSX with shared strings like Excel writes
printf 'Name,Qty,Price\nApples,3,1.25\n"Pears, green",12,0.8\n' > table.csv
python3 - <<'PY'
import zipfile
files = {
    "[Content_Types].xml": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/></Types>',
    "_rels/.rels": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>',
    "xl/workbook.xml": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Budget" sheetId="1" r:id="rId1"/></sheets></workbook>',
    "xl/_rels/workbook.xml.rels": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/></Relationships>',
    "xl/sharedStrings.xml": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="4" uniqueCount="4"><si><t>Item</t></si><si><t>Cost</t></si><si><t>Rent</t></si><si><r><t>Food </t></r><r><t>&amp; drink</t></r></si></sst>',
    "xl/worksheets/sheet1.xml": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row><row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>1200</v></c></row><row r="3"><c r="A3" t="s"><v>3</v></c><c r="C3"><v>310.5</v></c></row></sheetData></worksheet>',
}
with zipfile.ZipFile("budget.xlsx", "w", zipfile.ZIP_DEFLATED) as z:
    for name, text in files.items():
        z.writestr(name, text)
PY

# An EPUB with two chapters (listed out of order), a stylesheet, an image and a link
python3 - <<'PY'
import zipfile
png = open("sample.png", "rb").read()
def ch(title, body):
    return ('<?xml version="1.0" encoding="utf-8"?>\n<html xmlns="http://www.w3.org/1999/xhtml"><head><title>%s</title>'
            '<link rel="stylesheet" type="text/css" href="../Styles/book.css"/></head><body>%s</body></html>' % (title, body))
with zipfile.ZipFile("book.epub", "w") as z:
    z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
    d = zipfile.ZIP_DEFLATED
    z.writestr("META-INF/container.xml", '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>', d)
    z.writestr("OPS/book.opf", '<?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:uuid:12345678-1234-1234-1234-123456789abc</dc:identifier><dc:title>Fixture Book</dc:title><dc:language>en</dc:language></metadata><manifest><item id="c2" href="Text/chapter%20two.xhtml" media-type="application/xhtml+xml"/><item id="c1" href="Text/chapter%20one.xhtml" media-type="application/xhtml+xml"/><item id="css" href="Styles/book.css" media-type="text/css"/><item id="img" href="Images/dot.png" media-type="image/png"/></manifest><spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>', d)
    z.writestr("OPS/Text/chapter one.xhtml", ch("One", '<h1>Chapter One</h1><p><a id="p1"/>First chapter text. <a href="chapter%20two.xhtml#end">Jump</a></p><p><img src="../Images/dot.png" alt="dot"/></p>'), d)
    z.writestr("OPS/Text/chapter two.xhtml", ch("Two", '<h1>Chapter Two</h1><p id="end">Second chapter text.</p>'), d)
    z.writestr("OPS/Styles/book.css", "h1 { color: #333; }", d)
    z.writestr("OPS/Images/dot.png", png, d)
PY

# Subtitles
cat > subs.srt <<'SRT'
1
00:00:01,000 --> 00:00:03,500
Hello there.

2
00:00:04,000 --> 00:00:06,000
<i>Second line</i>
SRT
cat > captions.vtt <<'VTT'
WEBVTT

NOTE a comment block

00:01.000 --> 00:03.500 align:start
<v Narrator>Hello there.

intro
00:04.000 --> 00:06.000
Second line
VTT

# Archives
mkdir -p stuff
cp note.txt sample.png stuff/
ditto -c -k --keepParent stuff bundle.zip
tar -czf backup.tar.gz stuff
rm -rf stuff

ls -la
