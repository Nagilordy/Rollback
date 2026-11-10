// Rollback's automatic test: opens the real app against a real Jellyfin server and uses it
// like a person would (Home, a library, a show, playing videos, tracks, seeking), with the
// keyboard, as a controller would. Each step is timed and its frames measured.
//
// Run by .github/workflows/windows-test.yml on GitHub's Windows machines, which set up a test
// server with small generated videos. To run it on your own server:
//   flutter build windows --profile -t integration_test/app_test.dart \
//     --dart-define=TEST_SERVER=http://127.0.0.1:8096 --dart-define=TEST_USER=test \
//     --dart-define=TEST_PASS=test --dart-define=TEST_REPORT=C:\rollback-test
// then start the built Rollback.exe: it runs the test, writes report.json, report.md and
// screenshots into TEST_REPORT, and closes (exit code 0 = every step passed).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'package:player_test/home.dart' show HomeScreen;
import 'package:player_test/library.dart' show LibraryScreen, ShowScreen;
import 'package:player_test/main.dart' as app;
import 'package:player_test/main.dart' show Jellyfin;
import 'package:player_test/movie.dart' show MovieScreen;
import 'package:player_test/player.dart' show PlayerScreen, openPlayer, playerScreen;
import 'package:player_test/profiles.dart' show ProfileStore;

const _server = String.fromEnvironment('TEST_SERVER', defaultValue: 'http://127.0.0.1:8096');
const _user = String.fromEnvironment('TEST_USER', defaultValue: 'test');
const _pass = String.fromEnvironment('TEST_PASS', defaultValue: 'test');
const _reportDir = String.fromEnvironment('TEST_REPORT', defaultValue: 'rollback-test');

// ---------- What gets measured ----------

class _Frames {
  final List<FrameTiming> all = [];
  void add(List<FrameTiming> t) => all.addAll(t);

  Map<String, Object> summary(double budgetMs) {
    double ms(Duration d) => d.inMicroseconds / 1000;
    if (all.isEmpty) return {'frames': 0};
    final total = all.map((f) => ms(f.totalSpan)).toList()..sort();
    final build = all.map((f) => ms(f.buildDuration)).toList()..sort();
    final raster = all.map((f) => ms(f.rasterDuration)).toList()..sort();
    double pct(List<double> l, double p) => l[((l.length - 1) * p).round()];
    double r(double v) => (v * 10).round() / 10;
    return {
      'frames': all.length,
      'slow': total.where((t) => t > budgetMs).length,
      'slowPercent': r(100 * total.where((t) => t > budgetMs).length / all.length),
      'medianMs': r(pct(total, 0.5)),
      'p90Ms': r(pct(total, 0.9)),
      'worstMs': r(total.last),
      'worstBuildMs': r(build.last),
      'worstRasterMs': r(raster.last),
    };
  }
}

class _Step {
  _Step(this.name);
  final String name;
  bool ok = true;
  String? error;
  int ms = 0;
  Map<String, Object> frames = {};
  final Map<String, Object> notes = {};

  Map<String, Object?> toJson() =>
      {'name': name, 'ok': ok, 'error': error, 'ms': ms, 'frames': frames, 'notes': notes};
}

final _steps = <_Step>[];
final _started = DateTime.now();
late final Directory _out;
const _budgetMs = 1000 / 60;

Future<void> main() async {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Real frames at the real pace, as in the app (not frames only when the test asks).
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('Rollback, used like a person would', (tester) async {
    _out = Directory(_reportDir)..createSync(recursive: true);
    final rssStart = ProcessInfo.currentRss;

    // Sign in the way the sign-in screen does, so the app opens straight on Home.
    final jf = Jellyfin(_server);
    List items = [];
    await _step(tester, 'Sign in to the test server', () async {
      // The server may still be starting: try for up to a minute.
      for (var i = 0;; i++) {
        try {
          await jf.login(_user, _pass);
          break;
        } catch (e) {
          if (i >= 20) rethrow;
          await _wait(tester, const Duration(seconds: 3));
        }
      }
      await ProfileStore.setServer(_server, 'Test server');
      await ProfileStore.remember(jf);
      items = (await jf.getPath(
              '/Items?Recursive=true&IncludeItemTypes=Movie,Series&Fields=Path&userId=${jf.userId}'))['Items']
          as List;
      _steps.last.notes['items'] = items.length;
    });
    if (!_steps.last.ok) {
      _writeReport(rssStart);
      return;
    }
    dynamic named(String part) => items.firstWhere((i) => i['Name'].toString().contains(part));
    final film1080 = named('Film 1080p');
    final film4k = named('Film 4K');
    final show = named('Test Show');

    await _step(tester, 'Open Rollback (to Home)', () async {
      app.main();
      await _until(tester, () => _shown(HomeScreen), const Duration(seconds: 30), 'Home never appeared');
      try {
        await windowManager.setSize(const Size(1920, 1080));
      } catch (_) {}
      // The rows and the first backdrop arrive.
      await _wait(tester, const Duration(seconds: 6));
    }, shot: 'home');

    await _step(tester, 'Home: down to the rows, along and back', () async {
      await _keys(tester, LogicalKeyboardKey.arrowDown, 1);
      await _keys(tester, LogicalKeyboardKey.arrowRight, 8);
      await _keys(tester, LogicalKeyboardKey.arrowLeft, 8);
    }, shot: 'home-rows');

    await _step(tester, 'Home: back up to the artwork', () async {
      await _keys(tester, LogicalKeyboardKey.escape, 1);
      _check(_shown(HomeScreen), 'left Home instead');
    });

    await _step(tester, 'Movie page opens and goes back', () async {
      _push(tester, MovieScreen(jf: _homeJf(tester), movie: film1080));
      await _until(tester, () => _shown(MovieScreen), const Duration(seconds: 10), 'movie page never appeared');
      await _wait(tester, const Duration(seconds: 3));
      await _shot(tester, 'movie');
      await _back(tester, MovieScreen);
    });

    await _step(tester, 'Library: open, scroll the posters, back', () async {
      await _keys(tester, LogicalKeyboardKey.pageDown, 1);
      await _until(tester, () => _shown(LibraryScreen), const Duration(seconds: 10),
          'Page Down on Home did not open the first library');
      await _wait(tester, const Duration(seconds: 3));
      await _keys(tester, LogicalKeyboardKey.arrowDown, 1);
      await _keys(tester, LogicalKeyboardKey.arrowRight, 5);
      await _keys(tester, LogicalKeyboardKey.arrowDown, 3);
      await _keys(tester, LogicalKeyboardKey.arrowUp, 3);
      await _shot(tester, 'library');
      await _back(tester, LibraryScreen);
    });

    await _step(tester, 'Show page: open, move through the episodes', () async {
      _push(tester, ShowScreen(jf: _homeJf(tester), series: show));
      await _until(tester, () => _shown(ShowScreen), const Duration(seconds: 10), 'show page never appeared');
      await _wait(tester, const Duration(seconds: 3));
      // Down until an episode card has focus (they're the big cards in the lower half).
      for (var i = 0; i < 5 && !_episodeFocused(tester); i++) {
        await _keys(tester, LogicalKeyboardKey.arrowDown, 1);
      }
      _check(_episodeFocused(tester), 'could not reach the episodes with the arrow keys');
      await _keys(tester, LogicalKeyboardKey.arrowRight, 5);
      await _keys(tester, LogicalKeyboardKey.arrowLeft, 5);
    }, shot: 'show');

    await _step(tester, 'Play an episode (Enter on its card)', () async {
      await _keys(tester, LogicalKeyboardKey.enter, 1, gap: const Duration(milliseconds: 200));
      await _until(tester, () => openPlayer.value != null, const Duration(seconds: 15), 'the player never opened');
      final s = _steps.last;
      final t0 = DateTime.now();
      await _until(tester, () => openPlayer.value!.state.position > const Duration(seconds: 1),
          const Duration(seconds: 30), 'the video never started playing');
      s.notes['startSeconds'] = DateTime.now().difference(t0).inMilliseconds / 1000;
      await _wait(tester, const Duration(seconds: 8));
      await _videoNotes(s);
    }, shot: 'episode');

    await _step(tester, 'Switch the audio track', () async {
      final p = openPlayer.value;
      _check(p != null, 'no player open');
      final audio = p!.state.tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();
      _steps.last.notes['audioTracks'] = audio.length;
      _check(audio.length >= 2, 'the episode should have 2 audio tracks, the player sees ${audio.length}');
      final other = audio.firstWhere((t) => t.id != p.state.track.audio.id);
      await p.setAudioTrack(other);
      await _until(tester, () => p.state.track.audio.id == other.id, const Duration(seconds: 5),
          'audio track did not change');
      await _wait(tester, const Duration(seconds: 2));
    });

    await _step(tester, 'Turn on the styled (ASS) subtitles', () async {
      final p = openPlayer.value!;
      final subs = p.state.tracks.subtitle.where((t) => t.id != 'auto' && t.id != 'no').toList();
      _steps.last.notes['subtitleTracks'] = subs.length;
      _check(subs.isNotEmpty, 'the episode has subtitles, the player sees none');
      await p.setSubtitleTrack(subs.first);
      await _until(tester, () => p.state.track.subtitle.id == subs.first.id, const Duration(seconds: 5),
          'subtitle track did not change');
      await _wait(tester, const Duration(seconds: 4));
    }, shot: 'subtitles');

    await _step(tester, 'Jump ahead (Right arrow)', () async {
      final p = openPlayer.value!;
      final before = p.state.position;
      await _keys(tester, LogicalKeyboardKey.arrowRight, 1, gap: const Duration(milliseconds: 300));
      await _until(tester, () => p.state.position > before + const Duration(seconds: 5), const Duration(seconds: 6),
          'the position did not move forward');
      await _wait(tester, const Duration(seconds: 2));
    });

    await _step(tester, 'Leave the player (Back)', () async {
      for (var i = 0; i < 3 && openPlayer.value != null; i++) {
        await _keys(tester, LogicalKeyboardKey.escape, 1, gap: const Duration(milliseconds: 600));
      }
      await _until(tester, () => openPlayer.value == null && _shown(ShowScreen), const Duration(seconds: 10),
          'Back did not close the player');
      await _back(tester, ShowScreen);
    });

    await _step(tester, 'Play the 1080p film (20 s)', () async {
      await _playFor(tester, film1080, const Duration(seconds: 20));
    }, shot: 'film-1080p');

    await _step(tester, 'Play the 4K 10-bit HEVC film (20 s)', () async {
      await _playFor(tester, film4k, const Duration(seconds: 20));
    }, shot: 'film-4k');

    await _step(tester, 'Back on Home afterwards', () async {
      await _until(tester, () => _shown(HomeScreen), const Duration(seconds: 10), 'not back on Home');
      await _wait(tester, const Duration(seconds: 3));
      await _keys(tester, LogicalKeyboardKey.arrowDown, 1);
      await _keys(tester, LogicalKeyboardKey.arrowRight, 4);
    });

    _writeReport(rssStart);
  }, timeout: const Timeout(Duration(minutes: 12)));

  tearDownAll(() {
    // Built into Rollback.exe: close when done; the exit code says how it went.
    Timer(const Duration(milliseconds: 500), () => exit(_steps.every((s) => s.ok) && _steps.isNotEmpty ? 0 : 1));
  });
}

// ---------- Helpers ----------

/// Runs one step: timed, its frames measured, a failure written down (and the next steps go on).
Future<void> _step(WidgetTester tester, String name, Future<void> Function() body, {String? shot}) async {
  final s = _Step(name);
  _steps.add(s);
  final frames = _Frames();
  SchedulerBinding.instance.addTimingsCallback(frames.add);
  final sw = Stopwatch()..start();
  try {
    await body();
  } catch (e) {
    s.ok = false;
    s.error = e.toString().split('\n').first;
    await _shot(tester, 'FAILED-${_steps.length}');
    await _recover(tester);
  }
  s.ms = sw.elapsedMilliseconds;
  // Frame timings arrive in batches: give the last ones a moment.
  await _wait(tester, const Duration(milliseconds: 1200));
  SchedulerBinding.instance.removeTimingsCallback(frames.add);
  s.frames = frames.summary(_budgetMs);
  if (shot != null && s.ok) await _shot(tester, shot);
}

void _check(bool ok, String why) {
  if (!ok) throw why;
}

/// After a failed step: close any player and go back to Home, so the next steps can run.
Future<void> _recover(WidgetTester tester) async {
  try {
    final nav = _navigator(tester);
    nav?.popUntil((r) => r.isFirst);
    await _until(tester, () => openPlayer.value == null, const Duration(seconds: 8), '');
  } catch (_) {}
  await _wait(tester, const Duration(seconds: 1));
}

bool _shown(Type t) => find.byType(t).evaluate().isNotEmpty;

Future<void> _wait(WidgetTester tester, Duration d) async {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _until(WidgetTester tester, bool Function() done, Duration timeout, String why) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) throw why.isEmpty ? 'timed out' : why;
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Presses a key [times] times, a person's pace apart (a controller's d-pad, not a held key).
Future<void> _keys(WidgetTester tester, LogicalKeyboardKey key, int times,
    {Duration gap = const Duration(milliseconds: 350)}) async {
  for (var i = 0; i < times; i++) {
    await tester.sendKeyEvent(key);
    await _wait(tester, gap);
  }
}

NavigatorState? _navigator(WidgetTester tester) {
  final homes = find.byType(HomeScreen, skipOffstage: false).evaluate();
  if (homes.isEmpty) return null;
  return Navigator.of(homes.first);
}

/// Opens a screen the way Rollback does (straight to a known item instead of hunting for its card).
void _push(WidgetTester tester, Widget screen) {
  final nav = _navigator(tester);
  if (nav == null) throw 'Home is not open';
  nav.push(MaterialPageRoute(builder: (_) => screen));
}

/// Back (Esc / Circle) must leave [screen].
Future<void> _back(WidgetTester tester, Type screen) async {
  await _keys(tester, LogicalKeyboardKey.escape, 1, gap: const Duration(milliseconds: 500));
  await _until(tester, () => !_shown(screen), const Duration(seconds: 5), 'Back did not leave the $screen');
}

bool _episodeFocused(WidgetTester tester) {
  final f = FocusManager.instance.primaryFocus;
  if (f == null || f.context == null) return false;
  final size = tester.view.physicalSize / tester.view.devicePixelRatio;
  final r = f.rect;
  return r.height >= 100 && r.center.dy > size.height * 0.4;
}

Future<void> _playFor(WidgetTester tester, dynamic item, Duration d) async {
  _push(tester, playerScreen(_homeJf(tester), item));
  await _until(tester, () => openPlayer.value != null, const Duration(seconds: 15), 'the player never opened');
  final t0 = DateTime.now();
  await _until(tester, () => openPlayer.value!.state.position > const Duration(seconds: 1),
      const Duration(seconds: 40), 'the video never started playing');
  final s = _steps.last;
  s.notes['startSeconds'] = DateTime.now().difference(t0).inMilliseconds / 1000;
  // A person shows the controls once while watching.
  await _wait(tester, d ~/ 2);
  await _keys(tester, LogicalKeyboardKey.arrowUp, 1, gap: const Duration(seconds: 2));
  await _wait(tester, d ~/ 2);
  await _videoNotes(s);
  for (var i = 0; i < 3 && openPlayer.value != null; i++) {
    await _keys(tester, LogicalKeyboardKey.escape, 1, gap: const Duration(milliseconds: 600));
  }
  await _until(tester, () => openPlayer.value == null && !_shown(PlayerScreen), const Duration(seconds: 10),
      'Back did not close the player');
}

// The signed-in Home's server connection (the same sign-in the app uses).
Jellyfin _homeJf(WidgetTester tester) {
  final home = find.byType(HomeScreen, skipOffstage: false).evaluate();
  if (home.isEmpty) throw 'Home is not open';
  return (home.first.widget as HomeScreen).jf;
}

/// What the engine says about the video playing now: decoder, dropped frames, size.
Future<void> _videoNotes(_Step s) async {
  final p = openPlayer.value;
  if (p == null) return;
  final np = p.platform;
  if (np is! NativePlayer) return;
  Future<String> get(String name) async {
    try {
      return await np.getProperty(name);
    } catch (_) {
      return '?';
    }
  }

  s.notes['decoder'] = await get('hwdec-current');
  s.notes['codec'] = await get('video-codec');
  s.notes['size'] = '${await get('width')}x${await get('height')}';
  s.notes['droppedFrames'] = await get('frame-drop-count');
  s.notes['decoderDropped'] = await get('decoder-frame-drop-count');
  s.notes['audioOutput'] = await get('current-ao');
  s.notes['positionSeconds'] = p.state.position.inMilliseconds / 1000;
}

/// A picture of the window (the app's own drawing; the video itself may show black).
Future<void> _shot(WidgetTester tester, String name) async {
  try {
    final boundary = find
        .byType(RepaintBoundary)
        .evaluate()
        .map((e) => e.renderObject)
        .whereType<RenderRepaintBoundary>()
        .firstOrNull;
    if (boundary == null) return;
    final image = await boundary.toImage(pixelRatio: 0.6);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (png == null) return;
    File('${_out.path}/${_steps.length.toString().padLeft(2, '0')}-$name.png')
        .writeAsBytesSync(png.buffer.asUint8List());
  } catch (_) {}
}

void _writeReport(int rssStart) {
  final rssEnd = ProcessInfo.currentRss;
  final size = WidgetsBinding.instance.platformDispatcher.views.first.physicalSize;
  final report = {
    'started': _started.toIso8601String(),
    'seconds': DateTime.now().difference(_started).inSeconds,
    'window': '${size.width.round()}x${size.height.round()}',
    'memoryStartMB': rssStart ~/ (1024 * 1024),
    'memoryEndMB': rssEnd ~/ (1024 * 1024),
    'passed': _steps.where((s) => s.ok).length,
    'failed': _steps.where((s) => !s.ok).length,
    'steps': [for (final s in _steps) s.toJson()],
  };
  File('${_out.path}/report.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));

  final md = StringBuffer()
    ..writeln('## Rollback test: ${report['passed']} passed, ${report['failed']} failed')
    ..writeln()
    ..writeln('Window ${report['window']} · memory ${report['memoryStartMB']} MB at the start, '
        '${report['memoryEndMB']} MB at the end · ${report['seconds']} s in all. '
        'No graphics card on this machine: compare speeds between builds, not with a real PC.')
    ..writeln()
    ..writeln('| | Step | Time | Frames | Slow (>16.7 ms) | Median | Worst | Notes |')
    ..writeln('|---|---|---|---|---|---|---|---|');
  for (final s in _steps) {
    final f = s.frames;
    final notes = [
      if (s.error != null) '**${s.error}**',
      for (final e in s.notes.entries) '${e.key} ${e.value}',
    ].join(' · ');
    md.writeln('| ${s.ok ? '✅' : '❌'} | ${s.name} | ${(s.ms / 1000).toStringAsFixed(1)} s | ${f['frames'] ?? 0} '
        '| ${f['slow'] ?? '-'} (${f['slowPercent'] ?? '-'}%) | ${f['medianMs'] ?? '-'} ms | ${f['worstMs'] ?? '-'} ms '
        '| $notes |');
  }
  File('${_out.path}/report.md').writeAsStringSync(md.toString());
}
