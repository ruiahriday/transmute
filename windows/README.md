# Transmute for Windows

The Windows version of Transmute, for **Windows 10 and Windows 11** on Intel/AMD (x64) and ARM PCs.
It does what the Mac app does: convert, compress and edit images, video, audio, PDFs, documents,
e-books, spreadsheets, presentations, subtitles and archives, with the drag wheel and floating files.

## Download

**https://github.com/ruiahriday/transmute/releases/download/windows-beta/Transmute-Setup.exe**

Open it and follow the steps. It installs for your user account only, so it doesn't need an
administrator password, and it picks the right version for your PC.

This beta isn't signed yet, so Windows may show "Windows protected your PC". Click **More info**, then
**Run anyway**.

## Using it

- Drop files on the window, choose a format for each kind of file, and click **Convert**. Results
  are saved next to the originals (or in a folder you pick in Settings).
- **Compress** shrinks images, video, audio and PDFs to a percentage or a target size.
- **Tools** merges and splits PDFs, turns images into a PDF, joins videos, zips files, removes
  metadata and reads QR codes.
- **Edit…** on a photo, video or recording opens an editor; **ⓘ** shows and edits its details.
- In File Explorer, right-click files and choose **Send to › Transmute** (or **Convert with
  Transmute** under "Show more options" on Windows 11).
- **Drag wheel:** while dragging files anywhere, hold **Shift** for formats, **Ctrl** for tools
  or **Alt** for actions, and drop on a bubble. Dropping on the wheel never moves your file.
  **Settings → Customize Wheels** picks which formats, tools and actions each wheel shows for
  each kind of file, and where each bubble sits (drag them around; Reset to default puts it back).
- **Floating files:** shake files while dragging them, or drag them to the middle of the top edge
  of the screen, to park them on a small shelf that stays on top.
- Transmute waits in the notification area by the clock. Right-click its icon for the menu.

Word, Excel and PowerPoint files convert exactly as Office shows them when Microsoft Office or
LibreOffice is installed; otherwise Transmute's own converters keep the text, headings, lists,
tables and pictures. Apple Pages, Numbers and Keynote files give their built-in preview.

## For developers

```
windows/
  src/Transmute.Core      converters (net8.0; builds and tests on Linux too)
  src/Transmute           the WPF app (net8.0-windows)
  src/Transmute.SelfTest  headless check of every conversion
  installer/Transmute.iss Inno Setup script
```

- Build: `dotnet build windows/src/Transmute`
- Test every conversion: `dotnet run --project windows/src/Transmute.SelfTest -- --make-fixtures out/fx`,
  then `dotnet run --project windows/src/Transmute.SelfTest -- out/fx`
- The app's own check: `Transmute.exe --smoke-test <fixtures> <output>` opens every window and
  saves a picture of each.

Every push to the `windows` branch runs `.github/workflows/build-windows.yml`: it builds both
versions with ffmpeg bundled, runs the conversion self-test and the app check on an Intel/AMD and an
ARM Windows machine, builds the installers and replaces the `windows-beta` release. Pictures and
logs from each run are pushed to the `windows-ci-x64` and `windows-ci-arm64` branches.

ffmpeg comes from https://github.com/BtbN/FFmpeg-Builds (GPL build).
