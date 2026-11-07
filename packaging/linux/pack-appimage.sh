#!/bin/bash
# Packs Rollback-x86_64.AppImage from a release build. Used by .github/workflows/linux.yml and
# locally, so both pack the same way.
#
#   packaging/linux/pack-appimage.sh <LGPL prefix> <out dir> [tools dir]
#
# <LGPL prefix>: the output of build-lgpl-libmpv.sh (<work dir>/prefix). Rollback ships that
#   libmpv / FFmpeg, never the distro's (Ubuntu's are GPL).
# [tools dir]: holds linuxdeploy-x86_64.AppImage and linuxdeploy-plugin-gtk.sh; downloaded at
#   fixed, checksummed versions when left out.
# Run from the repo root after `flutter build linux --release`.
set -euo pipefail
REPO=$(pwd)
LGPL=$(realpath "${1:?usage: $0 <LGPL prefix> <out dir> [tools dir]}")/lib
OUT=$(realpath -m "${2:?usage: $0 <LGPL prefix> <out dir> [tools dir]}")
TOOLS=${3:-}
BUNDLE=$REPO/build/linux/x64/release/bundle
[ -x "$BUNDLE/player_test" ] || { echo "No release build in $BUNDLE"; exit 1; }
[ -e "$LGPL/libmpv.so.2" ] || { echo "No libmpv.so.2 in $LGPL"; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT"; cd "$OUT"
APPDIR=AppDir
mkdir -p $APPDIR/usr/bin $APPDIR/usr/share/applications $APPDIR/usr/share/icons/hicolor/512x512/apps
# The app keeps its own layout next to the program (lib/ and data/ beside it).
cp -r "$BUNDLE"/* $APPDIR/usr/bin/
# sentry_flutter brings the jni package, whose library needs Java. Only Sentry's Android code
# uses it, so it stays out (with it, linuxdeploy would pack whatever Java the machine has).
rm -f $APPDIR/usr/bin/lib/libdartjni.so
cp "$REPO/packaging/rollback.desktop" $APPDIR/usr/share/applications/rollback.desktop
cp "$REPO/packaging/rollback.png" $APPDIR/usr/share/icons/hicolor/512x512/apps/rollback.png
cp "$REPO/packaging/AppRun" ./AppRun; chmod +x AppRun
# Rollback's licence, the third-party notices and the LGPL libraries' licence texts.
mkdir -p $APPDIR/usr/share/doc/rollback
cp "$REPO/LICENSE" "$REPO/THIRD_PARTY_NOTICES.md" $APPDIR/usr/share/doc/rollback/
cp -r "$LGPL/../share/doc/rollback-lgpl" $APPDIR/usr/share/doc/

# Packing tools at fixed versions, checked against their known checksums: every release is
# packed the same way, and a changed or tampered download stops the build.
if [ -n "$TOOLS" ]; then
  cp "$TOOLS/linuxdeploy-x86_64.AppImage" "$TOOLS/linuxdeploy-plugin-gtk.sh" .
else
  curl -fsSLO https://github.com/linuxdeploy/linuxdeploy/releases/download/1-alpha-20251107-1/linuxdeploy-x86_64.AppImage
  curl -fsSLO https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/7a3fbc31a9e5075073ff8790f26effbac5f84453/linuxdeploy-plugin-gtk.sh
fi
echo "c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d  linuxdeploy-x86_64.AppImage" | sha256sum -c -
echo "b0f4cbc684a0103a9651f0955b635eaea0096b3a66c0f5a2c2aa337960375171  linuxdeploy-plugin-gtk.sh" | sha256sum -c -
chmod +x linuxdeploy-x86_64.AppImage linuxdeploy-plugin-gtk.sh

# Every library Rollback and its video player need, so nothing has to be installed. The LGPL
# libmpv / FFmpeg come first in line, so everything that needs them gets these.
LIBS=()
for l in $APPDIR/usr/bin/lib/*.so; do LIBS+=(--library "$l"); done
export LD_LIBRARY_PATH="$LGPL${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export DEPLOY_GTK_VERSION=3 APPIMAGE_EXTRACT_AND_RUN=1
./linuxdeploy-x86_64.AppImage --appdir $APPDIR \
  --executable $APPDIR/usr/bin/player_test "${LIBS[@]}" --library "$LGPL/libmpv.so.2" \
  --desktop-file $APPDIR/usr/share/applications/rollback.desktop \
  --icon-file "$REPO/packaging/rollback.png" \
  --custom-apprun ./AppRun --plugin gtk

# Leave out GTK's TIFF image loader: it pulls in libtiff -> libjbig, which is GPL-only.
# Rollback never shows TIFF images through GTK.
rm -f $APPDIR/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader-tiff.so \
  $APPDIR/usr/lib/libpixbufloader-tiff.so $APPDIR/usr/lib/libtiff.so.* $APPDIR/usr/lib/libjbig.so.*
rm -rf $APPDIR/usr/share/doc/libjbig0 $APPDIR/usr/share/doc/libtiff6
python3 - $APPDIR/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache <<'PY'
import sys
p = sys.argv[1]
blocks = open(p).read().split('\n\n')
open(p, 'w').write('\n\n'.join(b for b in blocks if 'libpixbufloader-tiff.so' not in b))
PY

# Licence checks: nothing GPL-only, the LGPL libmpv / FFmpeg and no other, no Java.
bad=$(find $APPDIR \( -name '*jbig*' -o -name '*tiff*' -o -name 'libjvm*' -o -name 'libdartjni*' -o -name 'libpostproc*' \
  -o -name 'librubberband*' -o -name 'libfftw3*' -o -name 'libx264*' -o -name 'libx265*' \))
[ -z "$bad" ] || { echo "Must not ship: $bad"; exit 1; }
for l in libmpv.so.2 libavcodec.so.61 libavformat.so.61 libavutil.so.59; do
  # (linuxdeploy strips libraries, so compare build ids rather than bytes)
  id() { readelf -n "$1" | sed -n 's/.*Build ID: //p'; }
  [ -n "$(id "$LGPL/$l")" ] && [ "$(id "$APPDIR/usr/lib/$l")" = "$(id "$LGPL/$l")" ] \
    || { echo "$l is not the LGPL build"; exit 1; }
done

OUTPUT=Rollback-x86_64.AppImage ./linuxdeploy-x86_64.AppImage --appdir $APPDIR --output appimage
ls -la "$OUT/Rollback-x86_64.AppImage"
