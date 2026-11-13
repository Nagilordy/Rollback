// Rollback's own log files, and a quiet performance recorder.
//
// Logs go to ~/.local/share/frame/logs/ on Linux and %APPDATA%\Rollback\logs\ on Windows, one
// file per kind per day (together-2026-10-29.log, perf-2026-10-29.log). Each line starts with
// the seconds since Rollback started, then the time of day.
//
// The performance recorder writes, every 10 seconds that something was drawn: how many frames,
// how long the slowest took, how many missed the screen's refresh (a visible stutter), what
// was selected at the time, and how much memory Rollback uses. Startup time is logged once, and
// the players add their own playback lines (dropped frames, decoder, buffer).

import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'crash_reports.dart' show scrubSecrets;
import 'ui.dart' show focusLabels, fullScreen;

class AppLog {
  AppLog(this.name);
  final String name; // file prefix: together, perf

  static final Stopwatch since = Stopwatch()..start();
  IOSink? _file;
  String? _day;

  static String get folder {
    final env = Platform.environment;
    return Platform.isWindows
        ? '${env['APPDATA'] ?? '.'}\\Rollback\\logs'
        : '${env['XDG_DATA_HOME'] ?? '${env['HOME'] ?? '.'}/.local/share'}/frame/logs';
  }

  void call(String message) {
    debugPrint('${name[0].toUpperCase()}${name.substring(1)}: $message');
    try {
      final now = DateTime.now();
      final day = now.toIso8601String().substring(0, 10);
      if (_day != day) {
        _file?.close();
        Directory(folder).createSync(recursive: true);
        _file = File('$folder${Platform.pathSeparator}$name-$day.log').openWrite(mode: FileMode.append);
        _day = day;
      }
      final t = (since.elapsedMicroseconds / 1e6).toStringAsFixed(3).padLeft(10);
      _file!.writeln('$t  ${now.toIso8601String()}  $message');
    } catch (_) {}
  }
}

final perfLog = AppLog('perf');

/// Errors Rollback hit while running (errors-<date>.log): uncaught errors and Flutter's own
/// error reports, with where they happened, so a crash sweep has something to go on even
/// without crash reports turned on. Each different error is written in full once per run,
/// then only counted, so one error repeating every frame can't fill the disk.
final errorLog = AppLog('errors');

class ErrorRecorder {
  static final Map<String, int> _seen = {};
  static int _written = 0;

  static void start() {
    final flutterBefore = FlutterError.onError;
    FlutterError.onError = (details) {
      _record(details.exceptionAsString(), details.stack, details.context?.toDescription());
      flutterBefore?.call(details);
    };
    final platformBefore = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      _record(error.toString(), stack, 'uncaught');
      return platformBefore?.call(error, stack) ?? true;
    };
  }

  static void _record(String message, StackTrace? stack, String? where) {
    try {
      final key = message.length > 200 ? message.substring(0, 200) : message;
      final n = (_seen[key] ?? 0) + 1;
      _seen[key] = n;
      if (n == 1 && _written < 50) {
        _written++;
        final frames = (stack?.toString() ?? '').split('\n').where((l) => l.trim().isNotEmpty).take(12).join('\n    ');
        errorLog(scrubSecrets('${where == null ? '' : '[$where] '}$message${frames.isEmpty ? '' : '\n    $frames'}'));
      } else if (n == 10 || n == 100 || n == 1000) {
        errorLog(scrubSecrets('(seen $n times) $key'));
      }
    } catch (_) {}
  }
}

class PerfRecorder {
  static int _frames = 0, _janky = 0;
  static int _maxBuildUs = 0, _maxRasterUs = 0, _sumTotalUs = 0;
  static String? _worstWhere;
  static int _worstUs = 0;

  static void start() {
    perfLog('Rollback ${Platform.operatingSystem} started (log for this run begins here)');
    ErrorRecorder.start();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) {
      perfLog('first screen drawn ${AppLog.since.elapsedMilliseconds} ms after start');
    });
    // Every 10 s: a summary, only when something was drawn (an idle screen writes nothing).
    Stream.periodic(const Duration(seconds: 10)).listen((_) => _summary());
  }

  static double get _budgetUs {
    final hz = _refreshHz;
    return 1e6 / (hz > 20 ? hz : 60);
  }

  // The refresh rate of the screen Rollback's window is on (not just the first screen the
  // system lists, which can be another monitor). As the system reports it: when the graphics
  // chip can't keep up, Windows can report half the screen's real rate.
  static double get _refreshHz {
    try {
      final views = WidgetsBinding.instance.platformDispatcher.views;
      if (views.isNotEmpty) return views.first.display.refreshRate;
      return WidgetsBinding.instance.platformDispatcher.displays.first.refreshRate;
    } catch (_) {
      return 0;
    }
  }

  /// True while Rollback's window is hidden behind the mpv player: its frames then just wait
  /// for a window nobody sees, and would show up as huge false "slow frames".
  static bool hidden = false;

  static void _onTimings(List<FrameTiming> timings) {
    if (hidden) return;
    final budget = _budgetUs;
    for (final t in timings) {
      final build = t.buildDuration.inMicroseconds;
      final raster = t.rasterDuration.inMicroseconds;
      final total = t.totalSpan.inMicroseconds;
      _frames++;
      _sumTotalUs += total;
      if (build > _maxBuildUs) _maxBuildUs = build;
      if (raster > _maxRasterUs) _maxRasterUs = raster;
      // A frame whose work (build or draw) took longer than one refresh shows as a stutter.
      final work = build > raster ? build : raster;
      if (work > budget) {
        _janky++;
        if (work > _worstUs) {
          _worstUs = work;
          final f = FocusManager.instance.primaryFocus;
          _worstWhere = f == null ? null : (focusLabels[f] ?? f.context?.widget.runtimeType.toString());
        }
      }
    }
  }

  static void _summary() {
    if (_frames == 0) return;
    String ms(int us) => (us / 1000).toStringAsFixed(1);
    final rss = (ProcessInfo.currentRss / (1024 * 1024)).round();
    var window = '?';
    try {
      final size = WidgetsBinding.instance.platformDispatcher.views.first.physicalSize;
      window = '${size.width.round()}x${size.height.round()}${fullScreen.value ? ' full screen' : ''}';
    } catch (_) {}
    perfLog('$_frames frames, avg ${ms(_sumTotalUs ~/ _frames)} ms, slowest build ${ms(_maxBuildUs)} ms '
        '/ draw ${ms(_maxRasterUs)} ms, $_janky over budget (${ms(_budgetUs.round())} ms)'
        '${_janky > 0 ? ', worst ${ms(_worstUs)} ms at ${_worstWhere ?? '?'}' : ''}, memory $rss MB, window $window, '
        'screen ${_refreshHz.toStringAsFixed(0)} Hz');
    _frames = _janky = _maxBuildUs = _maxRasterUs = _sumTotalUs = _worstUs = 0;
    _worstWhere = null;
  }
}
