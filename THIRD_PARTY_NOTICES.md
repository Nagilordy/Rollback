# Third-party software in Rollback

Rollback itself is not open source (see LICENSE). It uses the open-source software below,
which stays under its own licence.

## Video playback: libmpv and FFmpeg (LGPL 2.1 or later)

Rollback plays video with **libmpv** (mpv 0.39.0) and the **FFmpeg** 7.1.1 libraries
(libavcodec, libavformat, libavutil, libavfilter, libavdevice, libswresample, libswscale).
Both are built as LGPL-only, with no GPL or non-free parts:

- FFmpeg: configured without `--enable-gpl` and without `--enable-nonfree`.
- mpv: built with `-Dgpl=false`.

On Linux, the exact build is `packaging/linux/build-lgpl-libmpv.sh`. On Windows, Rollback
uses the LGPL libmpv build that media_kit publishes
(https://github.com/media-kit/libmpv-win32-video-build).

These libraries are linked dynamically and ship as separate files, so you can replace them
with your own build:

- Linux: extract the AppImage (`./Rollback-x86_64.AppImage --appimage-extract`) and replace
  the files in `squashfs-root/usr/lib/`.
- Windows: replace `libmpv-2.dll` in Rollback's install folder.

**Source code.** Every Rollback release has the exact source code of the Linux build's
libraries attached next to the download (`ffmpeg-7.1.1.tar.xz`, `mpv-0.39.0.tar.gz`). The
Windows build's sources and build scripts are published by media_kit at the link above. The same releases come from
https://ffmpeg.org/releases/ and https://github.com/mpv-player/mpv/releases. Rollback makes no
changes to them. For three years after a release you can also ask for that source code through
the place you got Rollback; it's provided at no more than the cost of sending it.

Their licence texts are in the AppImage at `usr/share/doc/rollback-lgpl/`, and at
https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html.

## Libraries in the Linux AppImage

The AppImage also contains libraries from Ubuntu 24.04 that Rollback needs to run (GTK, GLib,
cairo, pango, the Wayland and X11 client libraries, libass, libplacebo, dav1d, libva, PipeWire
and PulseAudio clients, gnutls, and their dependencies). They are under LGPL, MIT, BSD, ISC,
zlib and similar licences; each one's copyright and licence file is in the AppImage under
`usr/share/doc/<package>/copyright`. Source code for each is available from Ubuntu
(https://launchpad.net/ubuntu/noble) under the package name of its folder.

## Flutter and Dart packages

Rollback is built with Flutter (BSD 3-Clause) and Dart packages including media_kit (MIT),
sentry_flutter (MIT) and others. Their full licence texts are packed into the app at
`data/flutter_assets/NOTICES.Z` (gzip-compressed text).

## Fonts

The fonts in `assets/fonts/` are under the SIL Open Font License 1.1; the licence files sit
next to them.
