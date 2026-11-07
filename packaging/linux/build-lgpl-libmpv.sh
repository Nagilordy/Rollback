#!/bin/bash
# Builds LGPL-only FFmpeg and libmpv for Rollback's Linux AppImage, so Rollback can stay closed
# source: no --enable-gpl / --enable-nonfree for FFmpeg, -Dgpl=false for mpv, and none of the
# GPL-only extras (x11 in mpv, rubberband). Used by .github/workflows/linux.yml and locally.
#
#   packaging/linux/build-lgpl-libmpv.sh <work dir>     -> <work dir>/prefix/lib/libmpv.so.2 …
#
# Needs (Ubuntu 24.04): build-essential nasm meson ninja-build pkg-config libass-dev
# libplacebo-dev libdav1d-dev libva-dev libdrm-dev libvulkan-dev libvdpau-dev libgnutls28-dev
# libpipewire-0.3-dev libpulse-dev libwayland-dev wayland-protocols libxkbcommon-dev libegl-dev
# libgl-dev libopus-dev libvpx-dev libxml2-dev zlib1g-dev libuchardet-dev liblcms2-dev
# libjpeg-dev libzimg-dev libbluray-dev libarchive-dev
set -euo pipefail
WORK=$(realpath -m "${1:?usage: $0 <work dir>}")
SRC=$WORK/src
PREFIX=$WORK/prefix
JOBS=$(nproc)

FFMPEG=ffmpeg-7.1.1
FFMPEG_SHA=733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1
MPV=0.39.0
MPV_SHA=2ca92437affb62c2b559b4419ea4785c70d023590500e8a52e95ea3ab4554683
VKH=1.3.290

fetch() {  # url file sha256
  [ -f "$SRC/$2" ] || curl -fsSL -o "$SRC/$2" "$1"
  echo "$3  $SRC/$2" | sha256sum -c -
}

mkdir -p "$SRC"
fetch "https://ffmpeg.org/releases/$FFMPEG.tar.xz" "$FFMPEG.tar.xz" "$FFMPEG_SHA"
fetch "https://github.com/mpv-player/mpv/archive/refs/tags/v$MPV.tar.gz" "mpv-$MPV.tar.gz" "$MPV_SHA"
fetch "https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v$VKH.tar.gz" "vulkan-headers-$VKH.tar.gz" "f38a653bf93cab7a2a229a53d2d53b1cba9a2819e4c0a7de13c54085bde9bcf5"
rm -rf "$PREFIX" "$WORK/build" "$SRC/$FFMPEG" "$SRC/mpv-$MPV" "$SRC/Vulkan-Headers-$VKH"
mkdir -p "$PREFIX" "$WORK/build/ffmpeg"
tar xf "$SRC/$FFMPEG.tar.xz" -C "$SRC"
tar xf "$SRC/mpv-$MPV.tar.gz" -C "$SRC"
tar xf "$SRC/vulkan-headers-$VKH.tar.gz" -C "$SRC"

# FFmpeg 7.1 needs Vulkan headers 1.3.277+ (Ubuntu 24.04 has 1.3.275). Headers only: the
# system's libvulkan is what runs.
mkdir -p "$PREFIX/vk-include"
cp -r "$SRC/Vulkan-Headers-$VKH/include/." "$PREFIX/vk-include/"

echo "=== FFmpeg (LGPL) ==="
cd "$WORK/build/ffmpeg"
"$SRC/$FFMPEG/configure" \
  --prefix="$PREFIX" \
  --enable-shared --disable-static \
  --disable-programs --disable-doc --disable-debug --enable-pic \
  --extra-cflags="-I$PREFIX/vk-include" \
  --enable-libdav1d \
  --enable-libplacebo --enable-vulkan \
  --enable-vaapi --enable-vdpau --enable-libdrm \
  --enable-gnutls \
  --enable-libopus --enable-libvpx \
  --enable-libxml2 --enable-zlib
grep -q 'FFMPEG_LICENSE "LGPL' config.h || { echo "FFmpeg is not LGPL: $(grep FFMPEG_LICENSE config.h)"; exit 1; }
make -j"$JOBS"
make install

echo "=== libmpv (LGPL) ==="
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
cd "$SRC/mpv-$MPV"
meson setup "$WORK/build/mpv" \
  --prefix="$PREFIX" --libdir=lib --buildtype=release \
  -Dgpl=false -Dlibmpv=true -Dcplayer=false \
  -Dlua=disabled -Djavascript=disabled \
  -Dmanpage-build=disabled -Dhtml-build=disabled -Dpdf-build=disabled \
  -Dwayland=enabled -Dx11=disabled -Degl=enabled -Dgl=enabled \
  -Dvaapi=enabled -Dvulkan=enabled \
  -Dpipewire=enabled -Dpulse=enabled \
  -Drubberband=disabled
meson compile -C "$WORK/build/mpv"
meson install -C "$WORK/build/mpv"
# Nothing GPL-only may be linked in.
if ldd "$PREFIX/lib/libmpv.so.2" | grep -E "rubberband|fftw|libpostproc|x264|x265|xvid"; then
  echo "libmpv links a GPL library"; exit 1
fi
# Their licences go inside the AppImage with them (pack-appimage.sh copies this folder).
DOC=$PREFIX/share/doc/rollback-lgpl
mkdir -p "$DOC"
cp "$SRC/$FFMPEG/COPYING.LGPLv2.1" "$DOC/FFmpeg-COPYING.LGPLv2.1"
cp "$SRC/$FFMPEG/LICENSE.md" "$DOC/FFmpeg-LICENSE.md"
cp "$SRC/mpv-$MPV/LICENSE.LGPL" "$DOC/mpv-LICENSE.LGPL"
cp "$SRC/mpv-$MPV/Copyright" "$DOC/mpv-Copyright"
echo "LGPL libmpv ready in $PREFIX/lib"
