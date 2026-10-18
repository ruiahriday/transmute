# Transmute

A personal file converter for your Mac. It lives in the menu bar, converts in batches,
and everything runs on your Mac: no files are uploaded anywhere.

It's an original app written from scratch, using Tangerine's public App Store listing and
website only to decide which features to build. It contains no code, icons or branding
from Tangerine.

## Install the ready-made app

Each push to `main` makes GitHub's Mac build server compile the app, bundle ffmpeg, run a
self-test of every conversion, and publish `Transmute.dmg` under **Releases → latest**.

1. Download `Transmute.dmg` from the repository's latest release and open it.
2. Drag **Transmute** into **Applications**.
3. Open it. macOS will refuse the first time, because the app isn't signed with a paid
   Apple developer certificate. Go to **System Settings → Privacy & Security**, scroll down,
   and click **Open Anyway**. You only do this once.

It runs on Apple Silicon and Intel Macs with macOS 13 Ventura or newer. Nothing else needs
installing.

## Build it yourself instead

1. Install Apple's developer tools (skip this if you have Xcode): `xcode-select --install`
2. Optional: `brew install ffmpeg` for MP3, MKV, WebM, AVI, WMV, OGG, Opus, GIF-from-video
   and WebP. The ready-made app has ffmpeg built in.
3. From this folder, run `./build-app.sh --install`. This builds `Transmute.app`, copies it
   to `/Applications` and opens it.

To work on it in Xcode, open `Package.swift` with Xcode and press Run.

## Self-test

`Transmute.app/Contents/MacOS/Transmute --selftest <folder>` runs every conversion on the
files in a folder and prints PASS or FAIL for each one. `scripts/make-fixtures.sh <folder>
<ffmpeg>` creates one sample file of each kind. The build server runs both on every build.

## Using it

- **Main window:** click the menu bar icon (two circling arrows) and choose *Open Transmute*.
  Drop in files or whole folders, pick an output format for each kind of file, and click
  **Convert**. The **Compress** tab shrinks files by a percentage or to a target size. The
  **Tools** tab merges PDFs, turns images into a PDF, splits PDFs into pages, zips
  everything, removes metadata and reads QR codes.
- **Drag wheel:** start dragging files anywhere (Finder, the Desktop, Mail…) and hold a key:
  - **⇧ Shift** shows a ring of output formats,
  - **⌘ Command** or **⌥ Option** shows tools (half size, quarter size, clean metadata,
    split or merge PDFs, images to PDF, QR, zip),
  - **⌃ Control** shows actions (AirDrop, Copy, Copy Path, open in Terminal, Move…).

  Once the wheel is open you can let go of the key. Drop the files on a bubble, and the result
  is saved next to the original and shown in Finder. A small progress card appears in the
  top-right corner while it works.
- **Settings** (gear button in the main window): choose where results are saved, whether
  Finder opens afterwards, the drag wheel, and open at login.

Your original files are never changed. Results get a new name, such as `photo.jpg`,
`photo (compressed).jpg` or `photo (clean).jpg`.

## What converts to what

| From | To | Engine |
|---|---|---|
| Images: JPEG, PNG, HEIC, WebP, TIFF, BMP, GIF, SVG, RAW, AVIF, PSD | JPEG, PNG, HEIC, TIFF, BMP, GIF, PDF, SVG\*, WebP | ImageIO (WebP output uses ffmpeg) |
| Video: MP4, MOV, MKV, AVI, WMV, WebM, FLV, MPG… | MP4, MOV, MKV, WebM, AVI, WMV, GIF, MP3, M4A, WAV | ffmpeg, or AVFoundation for MP4/MOV/M4A/WAV without it |
| Audio: MP3, M4A, WAV, FLAC, OGG, Opus, AIFF, AAC… | MP3, M4A, WAV, FLAC, OGG, Opus, AIFF | ffmpeg, or `afconvert` for M4A/WAV/AIFF/FLAC without it |
| PDF | PNG/JPEG (one per page), TXT, RTF, DOCX, HTML | PDFKit |
| Documents: TXT, MD, RTF, DOC, DOCX, ODT, HTML | PDF, DOCX, RTF, TXT, HTML, ODT | macOS text system |
| Subtitles: SRT, VTT | SRT, VTT | built in |
| Archives: ZIP, TAR, TAR.GZ, GZ, BZ2, XZ, RAR, 7Z | Extract, ZIP, TAR.GZ | `ditto`, `tar` (libarchive) |
| Anything | ZIP, TAR.GZ | `ditto`, `tar` |

\* SVG output wraps the picture's pixels in an SVG file. It doesn't trace the image into vector shapes.

## Known limits

- DOCX → PDF keeps text and basic formatting, but not images or complex layouts.
- PDF compression recompresses embedded images. Text-only PDFs barely shrink, and target sizes
  are best effort for PDFs.
- Not built yet, compared with Tangerine: photo editing (crop, annotate, redact), video
  editing (trim, split, join, speed), audio normalize and trim, metadata editing, EPUB,
  Pages, PowerPoint and spreadsheet conversion, and floating files.

## Code map

```
Sources/Transmute/
  App.swift             App entry point, menu bar item, progress card, settings
  ContentView.swift     Main window: drop zone, file list, Convert / Compress / Tools
  DragWheel.swift       The drag wheel shown while dragging files with a key held
  SelfTest.swift        Headless --selftest run used by the build server
  JobQueue.swift        Batch queue: runs two files at a time, tracks progress, cancels
  Engine.swift          Sends each job to the right converter
  Formats.swift         File kinds, output formats, options, output file naming
  ImageConverter.swift  Image conversion, compression, metadata removal, QR reading
  MediaConverter.swift  Video and audio through ffmpeg, with AVFoundation fallback
  DocumentTools.swift   PDF tools, document conversion, subtitles, archives
  Shell.swift           Runs ffmpeg, tar and other command-line tools
scripts/make-fixtures.sh  Sample files for the self-test
.github/workflows/build.yml  Mac build server: build, test, package, publish
```
