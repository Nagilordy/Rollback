#!/bin/bash
# Builds Rollback's own LGPL-only FFmpeg and libmpv for Windows, the same versions and rules as
# Linux (packaging/linux/build-lgpl-libmpv.sh): no --enable-gpl / --enable-nonfree for FFmpeg,
# -Dgpl=false for mpv. Unlike media_kit's Windows engine, FFmpeg keeps all its decoders, so
# Dolby TrueHD audio and Blu-ray (PGS) subtitles play.
#
# Runs in MSYS2's UCRT64 shell (.github/workflows/windows.yml sets it up with the packages below):
#
#   packaging/windows/build-lgpl-libmpv.sh <work dir>   -> <work dir>/out/libmpv-2.dll + the DLLs
#                                                          it needs + licenses/
#
# MSYS2 packages (pacboy names): toolchain meson ninja nasm pkgconf libass libplacebo dav1d
# shaderc spirv-cross vulkan-headers vulkan-loader lcms2 libjpeg-turbo zimg uchardet opus
# libvpx libxml2 zlib ffnvcodec-headers
set -euo pipefail
WORK=$(realpath -m "${1:?usage: $0 <work dir>}")
SRC=$WORK/src
PREFIX=$WORK/prefix
OUT=$WORK/out
JOBS=$(nproc)
FFMPEG=ffmpeg-7.1.1
FFMPEG_SHA=733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1
MPV=0.39.0
MPV_SHA=2ca92437affb62c2b559b4419ea4785c70d023590500e8a52e95ea3ab4554683

fetch() {  # url file sha256
  [ -f "$SRC/$2" ] || curl -fsSL -o "$SRC/$2" "$1"
  echo "$3  $SRC/$2" | sha256sum -c -
}

mkdir -p "$SRC"
fetch "https://ffmpeg.org/releases/$FFMPEG.tar.xz" "$FFMPEG.tar.xz" "$FFMPEG_SHA"
fetch "https://github.com/mpv-player/mpv/archive/refs/tags/v$MPV.tar.gz" "mpv-$MPV.tar.gz" "$MPV_SHA"

rm -rf "$PREFIX" "$OUT" "$WORK/build" "$SRC/$FFMPEG" "$SRC/mpv-$MPV"
mkdir -p "$PREFIX" "$OUT/licenses" "$WORK/build/ffmpeg"
tar xf "$SRC/$FFMPEG.tar.xz" -C "$SRC"
tar xf "$SRC/mpv-$MPV.tar.gz" -C "$SRC"

echo "=== FFmpeg (LGPL) ==="
cd "$WORK/build/ffmpeg"
"$SRC/$FFMPEG/configure" \
  --prefix="$PREFIX" \
  --enable-shared --disable-static \
  --disable-programs --disable-doc --disable-debug \
  --enable-d3d11va --enable-dxva2 --enable-nvdec \
  --enable-schannel \
  --enable-libdav1d \
  --enable-libplacebo --enable-vulkan \
  --enable-libopus --enable-libvpx \
  --enable-libxml2 --enable-zlib
grep -q 'FFMPEG_LICENSE "LGPL' config.h || { echo "FFmpeg is not LGPL: $(grep FFMPEG_LICENSE config.h)"; exit 1; }
# The whole point of this engine: these must be in.
for d in TRUEHD MLP PGSSUB EAC3 AC3 DCA; do
  grep -q "#define CONFIG_${d}_DECODER 1" config.h || { echo "FFmpeg has no $d decoder"; exit 1; }
done
make -j"$JOBS"
make install

echo "=== libmpv (LGPL) ==="
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
cd "$SRC/mpv-$MPV"
# cplayer is built only to check the result below; Rollback ships just libmpv-2.dll.
meson setup "$WORK/build/mpv" \
  --prefix="$PREFIX" --buildtype=release \
  -Dgpl=false -Dlibmpv=true -Dcplayer=true \
  -Dlua=disabled -Djavascript=disabled \
  -Dmanpage-build=disabled -Dhtml-build=disabled -Dpdf-build=disabled \
  -Dd3d11=enabled -Dd3d-hwaccel=enabled \
  -Dgl=enabled -Dgl-win32=enabled \
  -Dvulkan=enabled -Dshaderc=enabled -Dspirv-cross=enabled \
  -Dwasapi=enabled \
  -Drubberband=disabled -Dlibarchive=disabled -Dlibbluray=disabled \
  -Ddvdnav=disabled -Dcdda=disabled -Dvapoursynth=disabled
meson compile -C "$WORK/build/mpv"
meson install -C "$WORK/build/mpv"

DLL=$PREFIX/bin/libmpv-2.dll
[ -f "$DLL" ] || { echo "libmpv-2.dll was not built"; exit 1; }
# Check: TrueHD is among the engine's audio decoders.
"$PREFIX/bin/mpv.exe" --no-config --ad=help | grep -qw truehd || { echo "the engine has no TrueHD decoder"; exit 1; }
# Nothing GPL-only may be linked in.
if ldd "$DLL" | grep -iE "rubberband|fftw|postproc|x264|x265|xvid"; then
  echo "libmpv links a GPL library"; exit 1
fi

# libmpv-2.dll and every DLL it needs that isn't part of Windows (FFmpeg's, libass, libplacebo…).
cp "$DLL" "$OUT/"
ldd "$DLL" | awk '{print $3}' | grep -viE '^/c/windows|^$|not' | sort -u | while read -r dep; do
  cp -n "$dep" "$OUT/"
done
echo "Engine files:"; ls -1 "$OUT"

# Their licences go next to them in Rollback's install folder.
cp "$SRC/$FFMPEG/COPYING.LGPLv2.1" "$OUT/licenses/FFmpeg-COPYING.LGPLv2.1"
cp "$SRC/$FFMPEG/LICENSE.md" "$OUT/licenses/FFmpeg-LICENSE.md"
cp "$SRC/mpv-$MPV/LICENSE.LGPL" "$OUT/licenses/mpv-LICENSE.LGPL"
cp "$SRC/mpv-$MPV/Copyright" "$OUT/licenses/mpv-Copyright"
echo "LGPL Windows engine ready in $OUT"
