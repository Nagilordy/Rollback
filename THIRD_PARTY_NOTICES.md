# Third-party software in Rollback

Rollback itself is not open source (see LICENSE). It uses the open-source software below,
which stays under its own licence.

## Video playback: libmpv and FFmpeg (LGPL)

Rollback plays video with **libmpv** and the **FFmpeg** libraries (libavcodec, libavformat,
libavutil, libavfilter, libavdevice, libswresample, libswscale). In every Rollback build they
are LGPL-only, with no GPL or non-free parts: FFmpeg is configured without `--enable-gpl` and
without `--enable-nonfree`, and mpv is built with `-Dgpl=false`.

- **Linux:** mpv 0.39.0 and FFmpeg 7.1.1, LGPL 2.1 or later, built by
  `packaging/linux/build-lgpl-libmpv.sh`. Separate files in the AppImage's `usr/lib/`.
- **Windows:** `libmpv-2.dll` (mpv and FFmpeg in one file), the LGPL build media_kit publishes
  (release 2023-09-24, mpv git 652a1dd: https://github.com/media-kit/libmpv-win32-video-build).
  FFmpeg there is configured with `--enable-version3`, so this file is under the LGPL 3 or later.

They are linked dynamically and ship as separate files, so you can replace them with your own
build:

- Linux: extract the AppImage (`./Rollback-x86_64.AppImage --appimage-extract`) and replace
  the files in `squashfs-root/usr/lib/`.
- Windows: replace `libmpv-2.dll` in Rollback's install folder.

**Source code.** Rollback makes no changes to these libraries.

- Linux: every Rollback release has the exact source attached next to the download
  (`ffmpeg-7.1.1.tar.xz`, `mpv-0.39.0.tar.gz`); the same releases are on https://ffmpeg.org/releases/
  and https://github.com/mpv-player/mpv/releases.
- Windows: the source and build scripts for `libmpv-2.dll` are published by media_kit at the
  link above.

For three years after a release you can also ask for the complete source code of these
libraries, for either platform, through the place you got Rollback; it's provided at no more
than the cost of sending it.

**Licence texts.** Linux: in the AppImage at `usr/share/doc/rollback-lgpl/`. Windows: in the
`licenses` folder of Rollback's install folder (LGPL 3 and the GPL 3 it builds on). Also at
https://www.gnu.org/licenses/.

## Windows: graphics libraries

The Windows video player draws through ANGLE. These files come with it, from media_kit's
ANGLE package (https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES, v1.0.1):

| File | What | Licence |
|---|---|---|
| `libEGL.dll`, `libGLESv2.dll` | ANGLE (https://chromium.googlesource.com/angle/angle) | BSD 3-Clause |
| `vk_swiftshader.dll` | SwiftShader (https://github.com/google/swiftshader) | Apache 2.0 |
| `vulkan-1.dll` | Khronos Vulkan loader (https://github.com/KhronosGroup/Vulkan-Loader) | Apache 2.0 |
| `zlib.dll` | zlib (https://zlib.net) | zlib |
| `d3dcompiler_47.dll` | Microsoft's shader compiler | Microsoft redistributable |

## Libraries in the Linux AppImage

The AppImage also contains libraries from Ubuntu 24.04 that Rollback needs to run (GTK, GLib,
cairo, pango, the Wayland and X11 client libraries, libass, libplacebo, dav1d, libva, PipeWire
and PulseAudio clients, gnutls, and their dependencies). They are under LGPL, MIT, BSD, ISC,
zlib and similar licences; each one's copyright and licence file is in the AppImage under
`usr/share/doc/<package>/copyright`. Source code for each is available from Ubuntu
(https://launchpad.net/ubuntu/noble) under the package name of its folder.

## Flutter and Dart packages

Rollback is built with Flutter (BSD 3-Clause) and Dart packages including media_kit (MIT),
sentry_flutter (MIT; on Windows and Linux it includes sentry-native, MIT, and Crashpad,
Apache 2.0) and others. Their full licence texts are packed into the app at
`data/flutter_assets/NOTICES.Z` (gzip-compressed text), next to the program on Windows and in
`usr/bin/data/` in the AppImage.

## Fonts

The fonts in `assets/fonts/` are under the SIL Open Font License 1.1; the licence files sit
next to them.
