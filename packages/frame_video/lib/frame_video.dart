// Frame's video surface (Windows): a borderless window kept exactly under Frame's window, the
// same size, where the video engine (libmpv) draws with its own renderer, so HDR, Dolby Vision
// and smooth motion work. Frame's window turns see-through while the video plays, so its
// controls sit on top of the picture: one app, one window.
//
// Windows, and Linux when Frame runs in X11 mode (the AppImage switches to it when the preview
// is on; Gaming Mode always is). Elsewhere every call answers null / does nothing.
// Linux under Wayland has the HDR layer instead (openHdr below).

import 'dart:io' show Platform;

import 'package:flutter/services.dart';

class FrameVideo {
  static const _channel = MethodChannel('frame/video');

  static bool get supported => Platform.isWindows || Platform.isLinux;

  /// Creates the video surface under Frame's window and makes Frame's window see-through.
  /// Returns the surface's window handle (for mpv's "wid"), or null if it couldn't.
  static Future<int?> open() async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<int>('open');
    } catch (_) {
      return null;
    }
  }

  /// Removes the surface and makes Frame's window solid again.
  static Future<void> close() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('close');
    } catch (_) {}
  }

  // ---------- Linux (Wayland): the HDR layer ----------
  //
  // A Wayland subsurface under Frame's window where the engine draws through libmpv's render
  // API, described to the compositor as HDR10 when the video and the screen are HDR. The
  // player must be created with vo=libmpv and no VideoController (one render context per
  // player), and closeHdr() must run before the player is disposed.

  /// Whether this desktop can show the HDR layer, and why not when it can't.
  static Future<(bool, String)> hdrSupported() async {
    if (!Platform.isLinux) return (false, 'not Linux');
    try {
      final r = await _channel.invokeMapMethod<String, dynamic>('hdrSupported');
      return ((r?['ok'] as bool?) ?? false, (r?['why'] as String?) ?? '');
    } catch (e) {
      return (false, '$e');
    }
  }

  /// Starts drawing the player (its native mpv handle) into the layer. Null if it couldn't.
  static Future<HdrLayerInfo?> openHdr(int mpvHandle, {required bool hdr}) async {
    if (!Platform.isLinux) return null;
    try {
      final r = await _channel.invokeMapMethod<String, dynamic>('openHdr', {'handle': mpvHandle, 'hdr': hdr});
      final info = HdrLayerInfo._(r);
      return info.open ? info : null;
    } catch (_) {
      return null;
    }
  }

  /// Switches the open layer between HDR10 and a normal picture (for the next video).
  static Future<HdrLayerInfo?> setHdr(bool hdr) async {
    if (!Platform.isLinux) return null;
    try {
      return HdrLayerInfo._(await _channel.invokeMapMethod<String, dynamic>('setHdr', {'hdr': hdr}));
    } catch (_) {
      return null;
    }
  }

  /// What the open layer shows now. The layer follows the screen by itself (HDR switched on
  /// or off in the display settings), so this can differ from what openHdr/setHdr returned.
  static Future<HdrLayerInfo?> hdrState() async {
    if (!Platform.isLinux) return null;
    try {
      return HdrLayerInfo._(await _channel.invokeMapMethod<String, dynamic>('hdrState'));
    } catch (_) {
      return null;
    }
  }

  /// Stops drawing and removes the layer [id] (from openHdr). Call before disposing the
  /// player. A layer already replaced by another player's is left alone.
  static Future<void> closeHdr(int id) async {
    if (!Platform.isLinux) return;
    try {
      await _channel.invokeMethod<void>('closeHdr', {'id': id});
    } catch (_) {}
  }
}

/// What the HDR layer is doing: whether the picture goes to the screen as HDR10, and the
/// screen's peak and SDR white brightness the compositor reported (nits).
class HdrLayerInfo {
  HdrLayerInfo._(Map<String, dynamic>? r)
      : open = (r?['open'] as bool?) ?? false,
        id = (r?['id'] as int?) ?? 0,
        hdr = (r?['hdr'] as bool?) ?? false,
        peak = ((r?['peak'] as num?) ?? 0).toDouble(),
        reference = ((r?['reference'] as num?) ?? 0).toDouble();

  final bool open;
  final int id;
  final bool hdr;
  final double peak;
  final double reference;
}
