// Whether Rollback's player draws through the video surface (packages/frame_video): the video
// engine (libmpv) draws with mpv's best renderer (gpu-next: HDR, Dolby Vision, smooth motion)
// into a window kept just under Rollback's, and Rollback's window is see-through behind the player's
// controls. Windows only for now: there it gives real HDR in a window. On Linux the player
// draws the video inside Rollback's window (proven, no extra window): the X11 surface needed X11
// mode, where KDE can't show HDR anyway, and it was fragile (black picture, crashes). Real HDR
// on Linux will come through Wayland / Gaming Mode as its own project.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// Linux: whether Rollback is running in X11 mode right now (the surface needs it).
bool get runningInX11 {
  final env = Platform.environment;
  final backend = env['GDK_BACKEND'] ?? '';
  if (backend.startsWith('x11')) return true;
  if (backend.startsWith('wayland')) return false;
  return (env['WAYLAND_DISPLAY'] ?? '').isEmpty && (env['DISPLAY'] ?? '').isNotEmpty;
}

/// Whether to try the surface on this system.
// Off for now on every system: the player draws inside Rollback's window, the version that works.
// The surface (real HDR) comes back once it's been made reliable, Windows first.
bool get surfaceWanted => false;

/// Linux under Wayland: whether to draw through the HDR layer (packages/frame_video,
/// hdr_surface.cc), a subsurface under Rollback's window that the compositor shows as HDR10 when
/// the video and the screen are HDR (KDE Plasma 6 with HDR on, for example). If the desktop
/// can't (no colour management), the player draws inside Rollback's window as before.
/// FRAME_HDR_LAYER=0 turns it off.
bool get hdrLayerWanted {
  if (!Platform.isLinux) return false;
  final env = Platform.environment;
  if (env['FRAME_HDR_LAYER'] == '0') return false;
  return !runningInX11 && (env['WAYLAND_DISPLAY'] ?? '').isNotEmpty;
}

/// Set when the surface couldn't be used (shown once as a banner by the app).
final ValueNotifier<String?> surfacePlayerSkipped = ValueNotifier(null);
