#!/bin/bash
# Builds an LGPL-only, static ffmpeg for the Mac App Store build: arm64 and x86_64, joined
# with lipo. No --enable-gpl and no --enable-nonfree, so no libx264/libx265; H.264 and HEVC
# are encoded with Apple's VideoToolbox (h264_videotoolbox, hevc_videotoolbox) and AAC with
# ffmpeg's own encoder or AudioToolbox (aac_at). Extra codecs come from LGPL/BSD libraries,
# built statically: LAME (MP3), libogg + libvorbis, Opus, libvpx (VP8/VP9), libwebp.
#
#   scripts/build-ffmpeg-lgpl.sh <work-dir>
#
# Results:  <work-dir>/out/ffmpeg         universal binary
#           <work-dir>/out/LICENSES.txt   licence texts, versions and configure options
# Needs the Xcode command line tools, pkg-config and nasm (brew install pkg-config nasm).
# CI caches <work-dir>/out keyed on this file's hash, so changing a version or a flag
# here rebuilds.
set -euo pipefail

FFMPEG_VERSION=8.0
LAME_VERSION=3.100
OGG_VERSION=1.3.5
VORBIS_VERSION=1.3.7
OPUS_VERSION=1.5.2
VPX_VERSION=1.14.1
WEBP_VERSION=1.4.0
export MACOSX_DEPLOYMENT_TARGET=13.0

mkdir -p "$1"
WORK="$(cd "$1" && pwd)"
DL="$WORK/downloads"
OUT="$WORK/out"
mkdir -p "$DL" "$OUT"
JOBS="$(sysctl -n hw.ncpu)"
HOST_ARCH="$(uname -m)"   # arm64 on GitHub's macos-15 runners

FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
LAME_URL="https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz"
OGG_URL="https://downloads.xiph.org/releases/ogg/libogg-$OGG_VERSION.tar.gz"
VORBIS_URL="https://downloads.xiph.org/releases/vorbis/libvorbis-$VORBIS_VERSION.tar.xz"
OPUS_URL="https://downloads.xiph.org/releases/opus/opus-$OPUS_VERSION.tar.gz"
VPX_URL="https://github.com/webmproject/libvpx/archive/refs/tags/v$VPX_VERSION.tar.gz"
WEBP_URL="https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$WEBP_VERSION.tar.gz"

log() { echo "==> $*"; }

fetch() { # url file
  if [[ ! -s "$DL/$2" ]]; then
    log "Downloading $1"
    curl -fsSL --retry 3 -o "$DL/$2" "$1"
  fi
}

fetch "$FFMPEG_URL" "ffmpeg-$FFMPEG_VERSION.tar.xz"
fetch "$LAME_URL" "lame-$LAME_VERSION.tar.gz"
fetch "$OGG_URL" "libogg-$OGG_VERSION.tar.gz"
fetch "$VORBIS_URL" "libvorbis-$VORBIS_VERSION.tar.xz"
fetch "$OPUS_URL" "opus-$OPUS_VERSION.tar.gz"
fetch "$VPX_URL" "libvpx-$VPX_VERSION.tar.gz"
fetch "$WEBP_URL" "libwebp-$WEBP_VERSION.tar.gz"

triple() { if [[ "$1" == "arm64" ]]; then echo aarch64-apple-darwin; else echo x86_64-apple-darwin; fi; }

build_arch() {
  local arch="$1"
  local root="$WORK/$arch"
  local prefix="$root/prefix"
  local src="$root/src"
  rm -rf "$root"
  mkdir -p "$prefix" "$src"
  for f in "$DL"/*; do tar -xf "$f" -C "$src"; done

  local host build
  host="$(triple "$arch")"
  build="$(triple "$HOST_ARCH")"
  export CC="clang -arch $arch"
  export CFLAGS="-arch $arch -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -O2"
  export LDFLAGS="-arch $arch -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
  # Only our own static libraries, never Homebrew's.
  export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
  unset PKG_CONFIG_PATH
  local auto=(--prefix="$prefix" --host="$host" --build="$build" --disable-shared --enable-static --with-pic)

  log "[$arch] LAME $LAME_VERSION"
  (cd "$src/lame-$LAME_VERSION"
    # Exported but never defined; breaks linking on macOS.
    sed -i '' '/lame_init_old/d' include/libmp3lame.sym
    ./configure "${auto[@]}" --disable-frontend --disable-gtktest --disable-analyzer-hooks
    make -j"$JOBS" && make install) > "$root/lame.log" 2>&1 || { tail -40 "$root/lame.log"; return 1; }

  log "[$arch] libogg $OGG_VERSION"
  (cd "$src/libogg-$OGG_VERSION"
    ./configure "${auto[@]}"
    make -j"$JOBS" && make install) > "$root/ogg.log" 2>&1 || { tail -40 "$root/ogg.log"; return 1; }

  log "[$arch] libvorbis $VORBIS_VERSION"
  (cd "$src/libvorbis-$VORBIS_VERSION"
    # An old PowerPC-era flag that current clang rejects.
    sed -i '' 's/-force_cpusubtype_ALL//g' configure
    ./configure "${auto[@]}" --with-ogg="$prefix" --disable-docs --disable-examples --disable-oggtest
    make -j"$JOBS" && make install) > "$root/vorbis.log" 2>&1 || { tail -40 "$root/vorbis.log"; return 1; }

  log "[$arch] Opus $OPUS_VERSION"
  (cd "$src/opus-$OPUS_VERSION"
    ./configure "${auto[@]}" --disable-doc --disable-extra-programs
    make -j"$JOBS" && make install) > "$root/opus.log" 2>&1 || { tail -40 "$root/opus.log"; return 1; }

  log "[$arch] libvpx $VPX_VERSION"
  local vpx_target vpx_as=()
  if [[ "$arch" == "arm64" ]]; then vpx_target=arm64-darwin20-gcc; else vpx_target=x86_64-darwin20-gcc; vpx_as=(--as=nasm); fi
  (cd "$src/libvpx-$VPX_VERSION"
    ./configure --prefix="$prefix" --target="$vpx_target" ${vpx_as[@]+"${vpx_as[@]}"} \
      --disable-shared --enable-static --enable-pic --enable-vp8 --enable-vp9 \
      --disable-examples --disable-tools --disable-docs --disable-unit-tests \
      --extra-cflags="-arch $arch -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
    make -j"$JOBS" && make install) > "$root/vpx.log" 2>&1 || { tail -60 "$root/vpx.log"; return 1; }

  log "[$arch] libwebp $WEBP_VERSION"
  (cd "$src/libwebp-$WEBP_VERSION"
    ./configure "${auto[@]}" --disable-png --disable-jpeg --disable-tiff --disable-gif --disable-wic \
      --disable-sdl --disable-gl --enable-libwebpmux --enable-libwebpdemux
    make -j"$JOBS" && make install) > "$root/webp.log" 2>&1 || { tail -40 "$root/webp.log"; return 1; }

  log "[$arch] FFmpeg $FFMPEG_VERSION"
  local cross=()
  if [[ "$arch" != "$HOST_ARCH" ]]; then cross=(--enable-cross-compile); fi
  # Configure flags are also written into LICENSES.txt below; keep them in this one array.
  FFMPEG_FLAGS=(
    --disable-autodetect --disable-shared --enable-static
    --disable-doc --disable-debug --disable-ffplay --disable-ffprobe
    --disable-network --disable-indevs --enable-indev=lavfi --disable-outdevs
    --enable-videotoolbox --enable-audiotoolbox
    --enable-zlib --enable-bzlib --enable-iconv
    --enable-libmp3lame --enable-libvorbis --enable-libopus --enable-libvpx --enable-libwebp
  )
  (cd "$src/ffmpeg-$FFMPEG_VERSION"
    unset CC CFLAGS LDFLAGS
    ./configure --prefix="$prefix" --arch="$arch" --target-os=darwin ${cross[@]+"${cross[@]}"} \
      --cc="clang -arch $arch" \
      --pkg-config=pkg-config --pkg-config-flags=--static \
      --extra-cflags="-I$prefix/include -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
      --extra-ldflags="-L$prefix/lib -arch $arch -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
      --extra-libs=-liconv \
      "${FFMPEG_FLAGS[@]}"
    make -j"$JOBS" && make install) > "$root/ffmpeg.log" 2>&1 || {
      if [[ -f "$src/ffmpeg-$FFMPEG_VERSION/ffbuild/config.mak" ]]; then
        # Configured; the compile or link failed. Show the linker's complaint first.
        grep -E -B2 -A30 "Undefined symbols|ld: |error:" "$root/ffmpeg.log" | grep -v "^clang (LLVM" | head -120
        tail -30 "$root/ffmpeg.log"
      else
        tail -40 "$root/ffmpeg.log"
        tail -60 "$src/ffmpeg-$FFMPEG_VERSION/ffbuild/config.log"
      fi
      return 1
    }
  log "[$arch] built $prefix/bin/ffmpeg"
}

build_arch arm64
build_arch x86_64

lipo -create "$WORK/arm64/prefix/bin/ffmpeg" "$WORK/x86_64/prefix/bin/ffmpeg" -output "$OUT/ffmpeg"
chmod +x "$OUT/ffmpeg"
lipo -info "$OUT/ffmpeg"

log "Checking the result"
# Only system libraries may be linked dynamically.
# (otool prints a header line per architecture; the libraries are the indented lines.)
if otool -L "$OUT/ffmpeg" | grep -E '^[[:space:]]' | grep -v -E '^[[:space:]]+(/usr/lib/|/System/Library/)' | grep -q .; then
  otool -L "$OUT/ffmpeg"
  echo "error: ffmpeg links a non-system library" >&2
  exit 1
fi
"$OUT/ffmpeg" -hide_banner -version
config="$("$OUT/ffmpeg" -hide_banner -buildconf)"
if grep -q -E -- '--enable-(gpl|nonfree)' <<<"$config"; then
  echo "error: this ffmpeg was configured with GPL or non-free parts" >&2
  exit 1
fi
"$OUT/ffmpeg" -hide_banner -L | head -3
if arch -x86_64 /usr/bin/true 2>/dev/null; then
  arch -x86_64 "$OUT/ffmpeg" -hide_banner -version | head -1 || echo "warning: x86_64 slice didn't run under Rosetta"
fi

# Licence texts and build record, appended to ThirdPartyNotices.txt by build-app.sh.
{
  echo
  echo "======================================================================"
  echo "BUILD RECORD"
  echo "FFmpeg $FFMPEG_VERSION  $FFMPEG_URL"
  echo "LAME $LAME_VERSION  $LAME_URL"
  echo "libogg $OGG_VERSION  $OGG_URL"
  echo "libvorbis $VORBIS_VERSION  $VORBIS_URL"
  echo "Opus $OPUS_VERSION  $OPUS_URL"
  echo "libvpx $VPX_VERSION  $VPX_URL"
  echo "libwebp $WEBP_VERSION  $WEBP_URL"
  echo
  echo "SHA-256 of the source archives:"
  (cd "$DL" && shasum -a 256 *)
  echo
  echo "FFmpeg configure options: ${FFMPEG_FLAGS[*]}"
  section() { # title file...
    echo
    echo "======================================================================"
    echo "$1"
    echo "======================================================================"
    shift
    for f in "$@"; do if [[ -f "$f" ]]; then cat "$f"; echo; fi; done
  }
  S="$WORK/arm64/src"
  section "FFmpeg: LICENSE.md and COPYING.LGPLv2.1" "$S/ffmpeg-$FFMPEG_VERSION/LICENSE.md" "$S/ffmpeg-$FFMPEG_VERSION/COPYING.LGPLv2.1"
  section "LAME: COPYING (GNU LGPL)" "$S/lame-$LAME_VERSION/COPYING"
  section "libogg: COPYING" "$S/libogg-$OGG_VERSION/COPYING"
  section "libvorbis: COPYING" "$S/libvorbis-$VORBIS_VERSION/COPYING"
  section "Opus: COPYING" "$S/opus-$OPUS_VERSION/COPYING"
  section "libvpx: LICENSE and PATENTS" "$S/libvpx-$VPX_VERSION/LICENSE" "$S/libvpx-$VPX_VERSION/PATENTS"
  section "libwebp: COPYING and PATENTS" "$S/libwebp-$WEBP_VERSION/COPYING" "$S/libwebp-$WEBP_VERSION/PATENTS"
} > "$OUT/LICENSES.txt"
wc -c "$OUT/LICENSES.txt"
log "Done: $OUT/ffmpeg"
