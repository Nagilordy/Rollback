// Windows: Rollback opens where you left it, at the size you left it (or maximised), instead of
// always at the size that fits the screen (packaging/windows/window_size.inc, used on the very
// first start, or when the remembered place isn't on any screen anymore, like after unplugging
// a monitor). Full screen isn't remembered here: F11 is quick, and Gaming Mode has its own.

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show Rect;

import 'package:screen_retriever/screen_retriever.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'gaming_mode.dart' show inGamingMode;
import 'ui.dart' show fullScreen;

const _key = 'windowPlace'; // "x,y,width,height,maximised" in Windows' units before scaling

/// Called while the window is still hidden (before Rollback's first frame), so it never jumps.
Future<void> restoreWindowPlace() async {
  if (!Platform.isWindows || inGamingMode) return;
  try {
    final saved = (await SharedPreferences.getInstance()).getString(_key);
    if (saved != null) {
      final p = saved.split(',').map(double.parse).toList();
      if (p.length == 5) {
        final place = Rect.fromLTWH(p[0], p[1], p[2], p[3]);
        // Only if it's still on a screen, and fits on it.
        final screens = await screenRetriever.getAllDisplays();
        final fits = screens.any((d) {
          final at = d.visiblePosition;
          final size = d.visibleSize ?? d.size;
          if (at == null) return false;
          final area = Rect.fromLTWH(at.dx, at.dy, size.width, size.height);
          return area.contains(place.center) && place.width <= area.width + 1 && place.height <= area.height + 1;
        });
        if (fits && place.width >= 320 && place.height >= 200) {
          await windowManager.setBounds(place);
          if (p[4] > 0) await windowManager.maximize();
        }
      }
    }
  } catch (_) {
    // Anything odd: the fitted size, as on a first start.
  }
  windowManager.addListener(_WindowPlaceSaver());
}

class _WindowPlaceSaver extends WindowListener {
  Timer? _later;

  void _saveSoon() {
    _later?.cancel();
    _later = Timer(const Duration(milliseconds: 600), () async {
      try {
        if (fullScreen.value || await windowManager.isFullScreen() || await windowManager.isMinimized()) return;
        final maximised = await windowManager.isMaximized();
        final prefs = await SharedPreferences.getInstance();
        if (maximised) {
          // Keep the size it had before being maximised; just remember it was maximised.
          final before = prefs.getString(_key)?.split(',');
          if (before != null && before.length == 5) {
            await prefs.setString(_key, [...before.take(4), '1'].join(','));
          }
          return;
        }
        final b = await windowManager.getBounds();
        await prefs.setString(_key, [b.left, b.top, b.width, b.height, 0].map((v) => v.toStringAsFixed(1)).join(','));
      } catch (_) {}
    });
  }

  @override
  void onWindowResized() => _saveSoon();

  @override
  void onWindowMoved() => _saveSoon();

  @override
  void onWindowMaximize() => _saveSoon();

  @override
  void onWindowUnmaximize() => _saveSoon();
}
