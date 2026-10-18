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
