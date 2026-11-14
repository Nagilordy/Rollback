// Built-in controller support: PS5, Xbox, Steam Controller and most others, no Steam needed.
//
// The controller is turned into the same keys the app already understands, sent to whatever
// is selected on screen, so every screen works with it without its own controller code:
//   D-pad or left stick  -> arrow keys (held = repeats, like a TV remote)
//   Cross / A            -> Enter (select)
//   Circle / B           -> Escape (back)
//   Options / Menu       -> play or pause (in the player)
//   Triangle / Y         -> the menu of the screen (Home: your profile; player: info)
//   Square / X           -> delete a letter (on-screen keyboard)
//   L1 / R1  (LB / RB)   -> skip back 10 s / forward 30 s (in the player)
//
// While a controller is in use, a small legend in the bottom right shows which button does
// what, with PlayStation or Xbox symbols to match the controller. Moving the mouse or typing
// hides it again.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:frame_video/frame_video.dart';
import 'package:gamepads/gamepads.dart';

import 'banners.dart' show bannerHandlesKey;
import 'ui.dart' show toggleFullScreen, focusLabels, fullScreen, isDesktop;

enum PadStyle { playstation, xbox }

enum PadButton { select, back, playPause, skip, fullScreen, menu, delete, tabs }

class PadHint {
  const PadHint(this.button, this.label);
  final PadButton button;
  final String label;
}

/// True while the controller is the last thing used.
final ValueNotifier<bool> padActive = ValueNotifier(false);

/// Which symbols to draw in the legend.
final ValueNotifier<PadStyle> padStyle = ValueNotifier(PadStyle.playstation);

/// "PlayStation controller connected" and the like, when a controller connects or
/// disconnects while Rollback is open (main.dart shows it as a short notice).
final ValueNotifier<String?> padNotice = ValueNotifier(null);

// ---------- Reading the controller ----------

class GamepadInput {
  static StreamSubscription<NormalizedGamepadEvent>? _events;
  static final Map<String, PadStyle> _styles = {};
  static final Set<String> _ignored = {};
  static final Set<String> _touchpads = {};
  static bool _touchpadDown = false;
  static final Set<GamepadButton> _down = {};
  // Which controller holds which button. Every controller (and each copy of one) keeps its own
  // presses, so one that disappears, or gets ignored halfway, can't leave a button stuck
  // "down" and swallow the next presses of the same button on another controller.
  static final Map<String, Set<GamepadButton>> _downBy = {};
  static String? _stickFrom; // which controller the stick values came from
  static Timer? _repeat;
  static LogicalKeyboardKey? _held; // direction currently held, from the d-pad or the stick
  static LogicalKeyboardKey? _stickDir;
  static double _lx = 0, _ly = 0;
  static double _drift = 0;
  static LogicalKeyboardKey? _hatV, _hatH; // d-pad directions held, when it's an axis
  static const _dpad = {
    GamepadButton.dpadUp,
    GamepadButton.dpadDown,
    GamepadButton.dpadLeft,
    GamepadButton.dpadRight,
  };
  static FocusNode? _lastLogged;
  static LogicalKeyboardKey? _hatDir; // PlayStation d-pad direction held (Windows reader)
  static String? _namesPending;
  static final Set<String> _listed = {}; // ids the library's controller list has shown
  static final Map<String, int> _askedAbout = {};
  // Keys some other program types for the controller (Steam's desktop layout turns the d-pad
  // into arrow keys and A / B into Enter / Escape). Rollback already reads the controller, so
  // those copies would move twice, or fight the controller's own presses.
  static final Map<LogicalKeyboardKey, DateTime> _padSentAt = {};
  static final Map<LogicalKeyboardKey, DateTime> _keyboardAt = {};
  static final Set<PhysicalKeyboardKey> _echoDown = {};
  static DateTime _lastPadUse = DateTime(0);
  static const _echoWindow = Duration(milliseconds: 250);
  // Mouse movement that isn't the person moving the mouse: the window moving or resizing under a
  // still cursor (full screen, a monitor change) makes Windows report a jump.
  static DateTime _ignorePointerUntil = DateTime(0);
  static DateTime _lastPointerMove = DateTime(0);
  static Size? _lastViewSize;

  static const _firstRepeat = Duration(milliseconds: 380);
  static const _nextRepeat = Duration(milliseconds: 110);

  static void start() {
    if (_events != null) return;
    try {
      _events = Gamepads.normalizedEvents.listen(_onEvent, onError: (e) => debugPrint('Controller: $e'));
      Gamepads.onConnected.listen((_) {
        _readNames();
        _notice('Controller connected');
      });
      // The touchpad is its own device: its movement is ignored, but a press of it switches
      // full screen, if Linux passes the press to us at all.
      Gamepads.events.listen((e) {
        if (!_touchpads.contains(e.gamepadId) || e.type != KeyType.button) return;
        final pressed = e.value.abs() > 0.5;
        if (pressed == _touchpadDown) return;
        _touchpadDown = pressed;
        debugPrint('Controller: touchpad ${pressed ? 'pressed' : 'released'} (button ${e.key})');
        if (pressed) {
          padActive.value = true;
          toggleFullScreen();
        }
      }, onError: (_) {});
      // A controller that turns off (or runs out of battery) mid-press would otherwise leave
      // a direction held down, scrolling forever.
      Gamepads.onDisconnected.listen((c) {
        _forget(c.gamepadId);
        // Linux reads the d-pad as two axes, not buttons: let go of those too.
        if (_hatV != null) _direction(_hatV!, false);
        if (_hatH != null) _direction(_hatH!, false);
        _hatV = null;
        _hatH = null;
        _styles.remove(c.gamepadId); // identified again if it comes back
        _listed.remove(c.gamepadId);
        _askedAbout.remove(c.gamepadId);
        if (_downBy.isEmpty) releaseAll();
        _notice('Controller disconnected');
      });
      _readNames();
      // Windows: PS5 and PS4 controllers are read by Rollback itself (the library only sees
      // Xbox-style ones there).
      if (Platform.isWindows) {
        FrameVideo.startPads(_onSonyPad).then((ok) => debugPrint('Controller: PlayStation reader ${ok ? 'on' : 'unavailable'}'));
      }
    } catch (e) {
      debugPrint('Controller support unavailable: $e');
      return;
    }
    // Real mouse use switches back to mouse mode: a click, the wheel, or moving it a good
    // distance. A little drift (a bumped desk, the controller's touchpad) is ignored, so it
    // can't steal focus from the controller.
    fullScreen.addListener(_windowChanged);
    GestureBinding.instance.pointerRouter.addGlobalRoute((event) {
      if (!padActive.value) return;
      final now = DateTime.now();
      final views = WidgetsBinding.instance.platformDispatcher.views;
      final size = views.isEmpty ? null : views.first.physicalSize;
      if (size != _lastViewSize) {
        _lastViewSize = size;
        _windowChanged();
      }
      if (event is PointerDownEvent || event is PointerScrollEvent) {
        padActive.value = false;
      } else if (event is PointerHoverEvent || event is PointerMoveEvent) {
        if (event.synthesized || now.isBefore(_ignorePointerUntil)) return;
        // It has to be one real movement, not little nudges added up over minutes.
        if (now.difference(_lastPointerMove) > const Duration(milliseconds: 400)) _drift = 0;
        _lastPointerMove = now;
        _drift += event.delta.distance;
        if (_drift > 200) padActive.value = false;
      }
    });
    padActive.addListener(() {
      if (padActive.value) _drift = 0;
    });
    HardwareKeyboard.instance.addHandler((e) {
      if (!_isEcho(e)) padActive.value = false;
      return false;
    });
    // Copies of the controller typed by another program never reach the screens.
    final keyManager = ServicesBinding.instance.keyEventManager;
    final previous = keyManager.keyMessageHandler;
    keyManager.keyMessageHandler = (message) {
      if (message.events.isNotEmpty && message.events.every(_isEcho)) return true;
      return previous?.call(message) ?? false;
    };
    // Log what's selected after each change, so a navigation problem shows up in the terminal.
    FocusManager.instance.addListener(() {
      final f = FocusManager.instance.primaryFocus;
      if (f != _lastLogged) {
        _lastLogged = f;
        final label = f == null ? null : focusLabels[f];
        debugPrint('Focus: ${label ?? f?.context?.widget.runtimeType ?? 'nothing'}');
      }
    });
  }

  static Future<void> _readNames() async {
    try {
      for (final pad in await Gamepads.list()) {
        _listed.add(pad.id);
        final name = '${pad.name}'.toLowerCase();
        // The PS5 controller also shows up as a touchpad and a motion sensor. Those aren't
        // for navigating and send updates nonstop, so they're ignored entirely.
        if (['touchpad', 'motion', 'accelerometer', 'gyro'].any(name.contains)) {
          _ignored.add(pad.id);
          _forget(pad.id);
          if (name.contains('touchpad')) _touchpads.add(pad.id);
          debugPrint('Controller part ignored: ${pad.name}');
          continue;
        }
        // Valve (Steam Controller, Steam Deck) uses A/B/X/Y like Xbox, so it gets the letters.
        final valve = pad.vendorId == 0x28de || ['steam', 'valve'].any(name.contains);
        final sony = !valve &&
            (pad.vendorId == 0x054c ||
                ['sony', 'playstation', 'dualsense', 'dualshock', 'wireless controller'].any(name.contains));
        // Windows: Rollback reads PlayStation controllers itself. Newer Windows can also hand
        // the same controller to the library; two copies of every press made the d-pad skip
        // or stop, so the library's copy is ignored.
        if (sony && Platform.isWindows) {
          _ignored.add(pad.id);
          _forget(pad.id);
          debugPrint('Controller: ${pad.name} is read by Rollback directly');
          continue;
        }
        _styles[pad.id] = sony ? PadStyle.playstation : PadStyle.xbox;
        final kind = valve ? 'Steam' : (sony ? 'PlayStation' : 'Xbox-style');
        debugPrint('Controller found: ${pad.name} ($kind, vendor ${pad.vendorId})');
      }
    } catch (e) {
      debugPrint('Controller list failed: $e');
    }
  }

  static void _onEvent(NormalizedGamepadEvent e) {
    // The controller sends a constant stream of tiny updates (sticks resting slightly off
    // center, triggers, touchpad, motion sensors). Drop everything that isn't a button or
    // the left stick right away, before doing any work.
    if (_ignored.contains(e.gamepadId)) return;
    // Windows, a controller not identified yet: it may be a PlayStation controller's copy
    // (which Rollback reads directly), even while the real one is being unplugged and plugged
    // back in, so wait until its name is known (a split second).
    if (Platform.isWindows && !_styles.containsKey(e.gamepadId)) {
      if (_namesPending != e.gamepadId) {
        final id = e.gamepadId;
        _namesPending = id;
        Future.delayed(const Duration(seconds: 2), () {
          if (_namesPending == id) _namesPending = null; // ask again later if it's still unknown
        });
        // Not in the list after all: it's its own controller, so it counts from now on.
        final tries = _askedAbout[id] = (_askedAbout[id] ?? 0) + 1;
        _readNames().then((_) {
          // Not listed yet: ask again on its next press. After a few tries it counts anyway,
          // so a controller the list never shows still works.
          if (!_ignored.contains(id) && (_listed.contains(id) || tries >= 3)) {
            _styles.putIfAbsent(id, () => PadStyle.xbox);
          }
        });
      }
      return;
    }
    final axis = e.axis;
    // L2 / R2: pressed past 60%, released below 30% (so a resting finger can't repeat it).
    if (axis == GamepadAxis.leftTrigger || axis == GamepadAxis.rightTrigger) {
      final left = axis == GamepadAxis.leftTrigger;
      final down = left ? _l2 : _r2;
      if (!down && e.value > 0.6) {
        _trigger(left, true, 'axis');
      } else if (down && e.value < 0.3) {
        _trigger(left, false, 'axis');
      }
      return;
    }
    if (axis != null && axis != GamepadAxis.leftStickX && axis != GamepadAxis.leftStickY) return;
    if (axis != null) {
      if (axis == GamepadAxis.leftStickX) _lx = e.value;
      if (axis == GamepadAxis.leftStickY) _ly = e.value;
      _stickFrom = e.gamepadId;
      // Resting near the center with no direction held: nothing to do.
      if (_stickDir == null && _lx.abs() < 0.6 && _ly.abs() < 0.6) return;
      _onStick();
      return;
    }

    final style = _styles[e.gamepadId];
    if (style != null && padStyle.value != style) padStyle.value = style;

    final button = e.button;

    // L2 / R2's on/off button (raw buttons 6 and 7 on the PS5 controller under Linux) isn't in
    // the controller library's mapping, so it hands them over as a d-pad: L2 came out as Right
    // and R2 as Down, moving the selection with every trigger press. The real d-pad never uses
    // those raw buttons (it's an axis), so they're read here as the triggers they are.
    if (button != null &&
        _dpad.contains(button) &&
        e.rawEvent.type == KeyType.button &&
        (e.rawEvent.key == '6' || e.rawEvent.key == '7')) {
      // The library sends a pair (Left + Right, or Up + Down) for each one: use one of them.
      if (button == GamepadButton.dpadRight || button == GamepadButton.dpadDown) {
        _trigger(e.rawEvent.key == '6', e.rawEvent.value.abs() > 0.5, 'button');
      }
      return;
    }

    // On Linux the PlayStation d-pad is one up/down axis and one left/right axis, not four
    // buttons. Read its raw direction (minus = up or left, plus = down or right) so Up can
    // never come out as Down.
    if (button != null && _dpad.contains(button) && e.rawEvent.type == KeyType.analog) {
      final raw = e.rawEvent.value;
      final vertical = button == GamepadButton.dpadUp || button == GamepadButton.dpadDown;
      final LogicalKeyboardKey? dir = raw < -0.5
          ? (vertical ? LogicalKeyboardKey.arrowUp : LogicalKeyboardKey.arrowLeft)
          : raw > 0.5
              ? (vertical ? LogicalKeyboardKey.arrowDown : LogicalKeyboardKey.arrowRight)
              : null;
      final held = vertical ? _hatV : _hatH;
      if (dir == held) return;
      debugPrint('Controller: d-pad ${dir?.keyLabel ?? 'released'} (axis, raw $raw)');
      if (held != null) _direction(held, false);
      if (vertical) {
        _hatV = dir;
      } else {
        _hatH = dir;
      }
      if (dir != null) {
        padActive.value = true;
        _direction(dir, true);
      }
      return;
    }

    if (button != null) {
      // Some controllers report the d-pad as -1 / +1 instead of 0 / 1, so either counts as pressed.
      _press(e.gamepadId, button, e.value.abs() > 0.5);
    }
  }

  static void _windowChanged() {
    _drift = 0;
    _ignorePointerUntil = DateTime.now().add(const Duration(milliseconds: 800));
  }

  static final _echoKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.escape,
  };

  // Whether a keyboard key is really the controller, typed again by another program (Steam).
  // Only while a controller is being used; a real keyboard always works.
  static bool isEcho(KeyEvent e) => _isEcho(e);
  static final Expando<bool> _echoSeen = Expando();
  static bool _isEcho(KeyEvent e) {
    final seen = _echoSeen[e];
    if (seen != null) return seen;
    bool echo = false;
    final now = DateTime.now();
    if (e is KeyUpEvent) {
      echo = _echoDown.contains(e.physicalKey);
      if (echo) scheduleMicrotask(() => _echoDown.remove(e.physicalKey));
    } else if (e is KeyRepeatEvent) {
      echo = _echoDown.contains(e.physicalKey) || (_held != null && _held == e.logicalKey);
    } else if (_echoKeys.contains(e.logicalKey) && now.difference(_lastPadUse) < const Duration(seconds: 2)) {
      final sent = _padSentAt[e.logicalKey];
      echo = (sent != null && now.difference(sent) < _echoWindow) || _held == e.logicalKey;
      if (echo) {
        _echoDown.add(e.physicalKey);
        debugPrint('Controller: ignored ${e.logicalKey.keyLabel} typed by another program');
      } else {
        _keyboardAt[e.logicalKey] = now;
      }
    }
    _echoSeen[e] = echo;
    return echo;
  }

  static void _press(String from, GamepadButton button, bool pressed) {
    final mine = _downBy.putIfAbsent(from, () => <GamepadButton>{});
    if (pressed == mine.contains(button)) return; // ignore repeats of the same state
    pressed ? mine.add(button) : mine.remove(button);
    // Pressed if any controller holds it; only a change of that counts as a press or a release.
    final held = _downBy.values.any((b) => b.contains(button));
    if (held == _down.contains(button)) return;
    debugPrint('Controller: ${button.name} ${held ? 'down' : 'up'} ($from)');
    held ? _down.add(button) : _down.remove(button);
    _lastPadUse = DateTime.now();
    padActive.value = true;
    _onButton(button, held);
  }

  /// A controller went away (or turned out to be a copy of another): let go of whatever it held,
  /// without touching what other controllers hold.
  static void _forget(String from) {
    final mine = _downBy.remove(from);
    for (final button in mine ?? const <GamepadButton>{}) {
      if (_downBy.values.any((b) => b.contains(button))) continue;
      if (_down.remove(button)) _onButton(button, false);
    }
    if (_stickFrom == from) {
      _stickFrom = null;
      _lx = 0;
      _ly = 0;
      if (_stickDir != null) _onStick();
    }
    if (mine != null && mine.isNotEmpty) debugPrint('Controller: let go of ${mine.map((b) => b.name).join(', ')} ($from)');
  }

  // ---------- PS5 / PS4 controllers on Windows (read by frame_video) ----------
  //
  // Windows numbers a PlayStation controller's buttons like this (USB and Bluetooth alike):
  // 0 Square, 1 Cross, 2 Circle, 3 Triangle, 4 L1, 5 R1, 6 L2, 7 R2, 8 Create / Share,
  // 9 Options, 10 L3, 11 R3, 12 PS, 13 touchpad. The d-pad is a hat, in hundredths of degrees
  // (0 = up, 9000 = right…, 65535 = released).
  static const _sonyButtons = {
    1: GamepadButton.a,
    2: GamepadButton.b,
    0: GamepadButton.x,
    3: GamepadButton.y,
    4: GamepadButton.leftBumper,
    5: GamepadButton.rightBumper,
    6: GamepadButton.leftTrigger,
    7: GamepadButton.rightTrigger,
    8: GamepadButton.back,
    9: GamepadButton.start,
    13: GamepadButton.touchpad,
  };
  static final Set<int> _sonyPads = {};

  static void _onSonyPad(Map<Object?, Object?> pad) {
    final id = pad['id'] as int? ?? 0;
    if (pad['gone'] == true) {
      _sonyPads.remove(id);
      debugPrint('Controller: PlayStation controller $id disconnected');
      _forget('ps$id');
      _hatDir = null;
      if (_downBy.isEmpty) releaseAll(); // nothing else connected: start completely fresh
      _notice('PlayStation controller disconnected');
      return;
    }
    if (_sonyPads.add(id)) {
      debugPrint('Controller found: PlayStation controller $id');
      _notice('PlayStation controller connected');
    }
    final buttons = pad['buttons'] as int? ?? 0;
    // The button guide switches to PlayStation symbols when it's used, not just connected
    // (someone may be using an Xbox controller or the keyboard with a PS controller nearby).
    final used = buttons != 0 ||
        (pad['pov'] as int? ?? 65535) <= 36000 ||
        (pad['lx'] as int? ?? 0).abs() >= 60 ||
        (pad['ly'] as int? ?? 0).abs() >= 60;
    if (used && padStyle.value != PadStyle.playstation) padStyle.value = PadStyle.playstation;
    final from = 'ps$id';
    _sonyButtons.forEach((bit, button) => _press(from, button, buttons & (1 << bit) != 0));
    // The d-pad: one direction at a time. A thumb rolling onto a diagonal (very easy on the
    // PS5 d-pad) keeps the direction already held instead of adding a second one, so Left can't
    // turn into Up halfway through. A diagonal from nothing waits for the real direction.
    final pov = pad['pov'] as int? ?? 65535;
    final keys = [GamepadButton.dpadUp, GamepadButton.dpadRight, GamepadButton.dpadDown, GamepadButton.dpadLeft];
    GamepadButton? hat;
    if (pov <= 36000) {
      final step = ((pov + 2250) ~/ 4500) % 8; // 0 up, 1 up-right, 2 right… 7 up-left
      if (step.isEven) {
        hat = keys[step ~/ 2];
      } else {
        final a = keys[step ~/ 2], b = keys[(step ~/ 2 + 1) % 4];
        final current = _hatDir == null ? null : _dpadOf(_hatDir!);
        hat = (current == a || current == b) ? current : null;
      }
    }
    _hatDir = hat == null ? null : _keyOf(hat);
    for (final k in keys) {
      if (k != hat) _press(from, k, false); // let go first, so the new direction is the one held
    }
    if (hat != null) _press(from, hat, true);
    // Left stick: -100..100, Windows' down is positive; Rollback's up is positive.
    final lx = (pad['lx'] as int? ?? 0) / 100.0;
    final ly = -(pad['ly'] as int? ?? 0) / 100.0;
    if (lx != _lx || ly != _ly) {
      _lx = lx;
      _ly = ly;
      _stickFrom = from;
      if (_stickDir != null || _lx.abs() >= 0.6 || _ly.abs() >= 0.6) _onStick();
    }
  }

  static GamepadButton _dpadOf(LogicalKeyboardKey key) => switch (key) {
        LogicalKeyboardKey.arrowUp => GamepadButton.dpadUp,
        LogicalKeyboardKey.arrowRight => GamepadButton.dpadRight,
        LogicalKeyboardKey.arrowDown => GamepadButton.dpadDown,
        _ => GamepadButton.dpadLeft,
      };
  static LogicalKeyboardKey _keyOf(GamepadButton b) => switch (b) {
        GamepadButton.dpadUp => LogicalKeyboardKey.arrowUp,
        GamepadButton.dpadRight => LogicalKeyboardKey.arrowRight,
        GamepadButton.dpadDown => LogicalKeyboardKey.arrowDown,
        _ => LogicalKeyboardKey.arrowLeft,
      };

  static void _onButton(GamepadButton button, bool pressed) {
    switch (button) {
      case GamepadButton.dpadUp:
        _direction(LogicalKeyboardKey.arrowUp, pressed);
      case GamepadButton.dpadDown:
        _direction(LogicalKeyboardKey.arrowDown, pressed);
      case GamepadButton.dpadLeft:
        _direction(LogicalKeyboardKey.arrowLeft, pressed);
      case GamepadButton.dpadRight:
        _direction(LogicalKeyboardKey.arrowRight, pressed);
      case GamepadButton.a:
        if (pressed) _send(LogicalKeyboardKey.enter);
      case GamepadButton.b:
        if (pressed) _send(LogicalKeyboardKey.escape);
      case GamepadButton.y:
        if (pressed) _send(LogicalKeyboardKey.contextMenu);
      case GamepadButton.x:
        if (pressed) _send(LogicalKeyboardKey.delete);
      case GamepadButton.start:
        if (pressed) _send(LogicalKeyboardKey.mediaPlayPause);
      case GamepadButton.leftBumper:
        if (pressed) _send(LogicalKeyboardKey.mediaRewind);
      case GamepadButton.rightBumper:
        if (pressed) _send(LogicalKeyboardKey.mediaFastForward);
      case GamepadButton.leftTrigger:
        _trigger(true, pressed, 'button');
      case GamepadButton.rightTrigger:
        _trigger(false, pressed, 'button');
      // Create (PlayStation) or View (Xbox) switches full screen. The touchpad press counts
      // too when Linux passes it to the controller (often it goes to the mouse instead).
      case GamepadButton.touchpad:
      case GamepadButton.back:
        if (pressed) toggleFullScreen();
      default:
        break;
    }
  }

  // L2 / R2 switch tabs (Home, Anime, Movies…; seasons on a show page): sent as Page Up /
  // Page Down, which a real keyboard can use too. Each press counts once, whether the
  // trigger arrives as a button, an analog axis, or both.
  // The trigger's button and its pressure reading can disagree for a moment (one says
  // released while the other still reads pressed), which counted one press twice. So a press
  // also needs 250 ms since the last one on that side.
  static bool _l2 = false, _r2 = false;
  static DateTime _l2At = DateTime(0), _r2At = DateTime(0);
  static void _trigger(bool left, bool pressed, String from) {
    if ((left ? _l2 : _r2) == pressed) return;
    if (left) {
      _l2 = pressed;
    } else {
      _r2 = pressed;
    }
    if (!pressed) return;
    final now = DateTime.now();
    if (now.difference(left ? _l2At : _r2At) < const Duration(milliseconds: 250)) return;
    if (left) {
      _l2At = now;
    } else {
      _r2At = now;
    }
    padActive.value = true;
    debugPrint('Controller: ${left ? 'L2' : 'R2'} ($from)');
    _send(left ? LogicalKeyboardKey.pageUp : LogicalKeyboardKey.pageDown);
  }

  // Lets go of everything: no direction held, no repeat running.
  // A short notice when a controller connects or disconnects (shown by main.dart, on any
  // screen, the player included), so you can see it was picked up. Not in the first few
  // seconds after Rollback starts: the controllers already connected then are expected.
  static final Stopwatch _since = Stopwatch()..start();
  static void _notice(String text) {
    if (_since.elapsed < const Duration(seconds: 4)) return;
    padNotice.value = text;
  }

  static void releaseAll() {
    _l2 = false;
    _r2 = false;
    _repeat?.cancel();
    _repeat = null;
    _held = null;
    _stickDir = null;
    _hatV = null;
    _hatH = null;
    _hatDir = null;
    _echoDown.clear();
    _lx = 0;
    _ly = 0;
    _down.clear();
    _downBy.clear();
    _stickFrom = null;
  }

  // The stick counts as a direction once pushed past 60%, and lets go below 35%,
  // so it never flickers between two directions.
  static void _onStick() {
    LogicalKeyboardKey? dir = _stickDir;
    final ax = _lx.abs(), ay = _ly.abs();
    if (ax < 0.35 && ay < 0.35) {
      dir = null;
    } else if (ax > 0.6 || ay > 0.6) {
      if (ax > ay) {
        dir = _lx > 0 ? LogicalKeyboardKey.arrowRight : LogicalKeyboardKey.arrowLeft;
      } else {
        dir = _ly > 0 ? LogicalKeyboardKey.arrowUp : LogicalKeyboardKey.arrowDown;
      }
    }
    if (dir == _stickDir) return;
    if (_stickDir != null) _direction(_stickDir!, false);
    _stickDir = dir;
    if (dir != null) {
      padActive.value = true;
      _direction(dir, true);
    }
  }

  static void _direction(LogicalKeyboardKey key, bool pressed) {
    if (pressed) {
      _repeat?.cancel();
      _held = key;
      _send(key);
      _repeat = Timer(_firstRepeat, () {
        _repeat = Timer.periodic(_nextRepeat, (_) {
          if (_held == key) _send(key, repeat: true);
        });
      });
    } else if (_held == key) {
      _held = null;
      _repeat?.cancel();
      _repeat = null;
    }
  }

  static final Map<LogicalKeyboardKey, PhysicalKeyboardKey> _physical = {
    LogicalKeyboardKey.arrowUp: PhysicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown: PhysicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft: PhysicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight: PhysicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.enter: PhysicalKeyboardKey.enter,
    LogicalKeyboardKey.escape: PhysicalKeyboardKey.escape,
    LogicalKeyboardKey.contextMenu: PhysicalKeyboardKey.contextMenu,
    LogicalKeyboardKey.delete: PhysicalKeyboardKey.delete,
    LogicalKeyboardKey.mediaPlayPause: PhysicalKeyboardKey.mediaPlayPause,
    LogicalKeyboardKey.mediaRewind: PhysicalKeyboardKey.mediaRewind,
    LogicalKeyboardKey.mediaFastForward: PhysicalKeyboardKey.mediaFastForward,
    LogicalKeyboardKey.pageUp: PhysicalKeyboardKey.pageUp,
    LogicalKeyboardKey.pageDown: PhysicalKeyboardKey.pageDown,
  };

  // Hands the key to the selected widget, then to each widget around it, exactly the way
  // Flutter delivers a real key press, stopping at the first one that uses it.

  static void _send(LogicalKeyboardKey key, {bool repeat = false}) {
    // A notification banner with an action (Triangle) comes first, whatever is selected.
    if (!repeat && bannerHandlesKey(key)) return;
    final now = DateTime.now();
    _lastPadUse = now;
    if (!repeat && _echoKeys.contains(key)) {
      // Another program's copy of this press got here first and already did it.
      final typed = _keyboardAt.remove(key);
      _padSentAt[key] = now;
      if (typed != null && now.difference(typed) < _echoWindow) {
        debugPrint('Controller: ${key.keyLabel} already typed by another program');
        return;
      }
    }
    final physical = _physical[key]!;
    final time = Duration(milliseconds: DateTime.now().millisecondsSinceEpoch);
    final KeyEvent event = repeat
        ? KeyRepeatEvent(physicalKey: physical, logicalKey: key, timeStamp: time)
        : KeyDownEvent(physicalKey: physical, logicalKey: key, timeStamp: time);

    // Safety net: if nothing on screen is selected (focus got lost), the first press just
    // selects something again instead of doing nothing.
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null || (primary is FocusScopeNode && primary.focusedChild == null)) {
      debugPrint('Controller: focus was lost, selecting the first item again');
      final scope = primary is FocusScopeNode ? primary : FocusManager.instance.rootScope;
      final first = scope.traversalDescendants.where((n) => n.canRequestFocus && n.context != null);
      if (first.isNotEmpty) first.first.requestFocus();
      return;
    }

    FocusNode? node = primary;
    while (node != null) {
      final handler = node.onKeyEvent;
      if (handler != null) {
        final result = handler(node, event);
        if (result == KeyEventResult.handled || result == KeyEventResult.skipRemainingHandlers) return;
      }
      node = node.parent;
    }
  }
}

// ---------- Which hints each screen shows ----------

class _HintsEntry {
  _HintsEntry(this.hints);
  List<PadHint> hints;
}

final List<_HintsEntry> _hintStack = [];
final ValueNotifier<int> _hintsChanged = ValueNotifier(0);

/// "Full screen" or "Window", depending on which one the touchpad / View button switches to.
PadHint fullScreenHint() => PadHint(PadButton.fullScreen, fullScreen.value ? 'Window' : 'Full screen');

/// Lets a screen choose its own legend. The newest screen on top wins.
/// An empty list hides the legend (the player does this while the video is clean).
class PadHints extends StatefulWidget {
  const PadHints({super.key, required this.hints, required this.child});
  final List<PadHint> hints;
  final Widget child;

  @override
  State<PadHints> createState() => _PadHintsState();
}

class _PadHintsState extends State<PadHints> {
  late final _HintsEntry _entry = _HintsEntry(widget.hints);

  @override
  void initState() {
    super.initState();
    _hintStack.add(_entry);
    _bump();
  }

  @override
  void didUpdateWidget(PadHints old) {
    super.didUpdateWidget(old);
    // Only redraw the legend when the hints really changed, not every time the screen redraws.
    final same = old.hints.length == widget.hints.length &&
        List.generate(old.hints.length, (i) => i).every(
            (i) => old.hints[i].button == widget.hints[i].button && old.hints[i].label == widget.hints[i].label);
    _entry.hints = widget.hints;
    if (!same) _bump();
  }

  @override
  void dispose() {
    _hintStack.remove(_entry);
    _bump();
    super.dispose();
  }

  void _bump() => WidgetsBinding.instance.addPostFrameCallback((_) => _hintsChanged.value++);

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Tells the legend when screens open and close, so Back only shows when there is somewhere to go.
class PadRouteWatcher extends NavigatorObserver {
  void _changed() => WidgetsBinding.instance.addPostFrameCallback((_) => _hintsChanged.value++);
  @override
  void didPush(Route route, Route? previousRoute) => _changed();
  @override
  void didPop(Route route, Route? previousRoute) => _changed();
  @override
  void didRemove(Route route, Route? previousRoute) => _changed();
  @override
  void didReplace({Route? newRoute, Route? oldRoute}) => _changed();
}

// ---------- The legend ----------

/// Sits above every screen. Shows the hints only while the controller is being used.
class PadLegend extends StatelessWidget {
  const PadLegend({super.key, required this.navigatorKey});
  final GlobalKey<NavigatorState> navigatorKey;

  List<PadHint> _current() {
    if (_hintStack.isNotEmpty) return _hintStack.last.hints;
    final canGoBack = navigatorKey.currentState?.canPop() ?? false;
    return [
      const PadHint(PadButton.select, 'Select'),
      if (canGoBack) const PadHint(PadButton.back, 'Back'),
      if (!canGoBack) const PadHint(PadButton.menu, 'Profile'),
      const PadHint(PadButton.tabs, 'Tabs'),
      if (isDesktop) fullScreenHint(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final s = (size.height / 1080).clamp(0.6, 2.0);
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: Listenable.merge([padActive, padStyle, _hintsChanged, fullScreen]),
        builder: (context, _) {
          // The full screen hint always shows what the button will do right now.
          final hints = [
            for (final h in _current()) h.button == PadButton.fullScreen ? fullScreenHint() : h,
          ];
          final show = padActive.value && hints.isNotEmpty;
          return Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: EdgeInsets.only(right: 40 * s, bottom: 28 * s),
              child: AnimatedOpacity(
                opacity: show ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 18 * s, vertical: 10 * s),
                  decoration: BoxDecoration(
                    color: const Color(0xFF06080B).withOpacity(0.72),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    for (var i = 0; i < hints.length; i++) ...[
                      if (i > 0) SizedBox(width: 26 * s),
                      PadGlyph(hints[i].button, style: padStyle.value, size: 30 * s),
                      SizedBox(width: 10 * s),
                      Text(
                        hints[i].label,
                        style: TextStyle(fontFamily: 'Hanken Grotesk', 
                          fontSize: 19 * s,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFFF4F5F7),
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ],
                  ]),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// One button symbol: PlayStation shapes or Xbox letters, drawn so they look the same everywhere.
class PadGlyph extends StatelessWidget {
  const PadGlyph(this.button, {super.key, required this.style, required this.size});
  final PadButton button;
  final PadStyle style;
  final double size;

  @override
  Widget build(BuildContext context) {
    const fg = Color(0xFFF4F5F7);
    const bg = Color(0x2EF4F5F7);
    final ps = style == PadStyle.playstation;

    Widget pill(String text) => Container(
          height: size,
          padding: EdgeInsets.symmetric(horizontal: size * 0.32),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(size * 0.3)),
          child: Text(text,
              style: TextStyle(fontFamily: 'Hanken Grotesk', 
                  fontSize: size * 0.46, fontWeight: FontWeight.w800, color: fg, decoration: TextDecoration.none)),
        );

    switch (button) {
      case PadButton.playPause:
        return Container(
          height: size,
          padding: EdgeInsets.symmetric(horizontal: size * 0.22),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(size * 0.3)),
          child: Icon(Icons.menu_rounded, size: size * 0.62, color: fg),
        );
      // The Create button (PlayStation: the small oval left of the touchpad) or the View
      // button (Xbox: two overlapping squares).
      case PadButton.fullScreen:
        return ps
            ? Container(
                width: size,
                height: size,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: bg, shape: BoxShape.circle),
                child: Container(
                  width: size * 0.3,
                  height: size * 0.56,
                  decoration: BoxDecoration(
                    border: Border.all(color: fg, width: size * 0.07),
                    borderRadius: BorderRadius.circular(size),
                  ),
                ),
              )
            : Container(
                width: size,
                height: size,
                decoration: const BoxDecoration(color: bg, shape: BoxShape.circle),
                child: Icon(Icons.filter_none_rounded, size: size * 0.5, color: fg),
              );
      case PadButton.skip:
        return Row(mainAxisSize: MainAxisSize.min, children: [
          pill(ps ? 'L1' : 'LB'),
          SizedBox(width: size * 0.18),
          pill(ps ? 'R1' : 'RB'),
        ]);
      case PadButton.tabs:
        return Row(mainAxisSize: MainAxisSize.min, children: [
          pill(ps ? 'L2' : 'LT'),
          SizedBox(width: size * 0.18),
          pill(ps ? 'R2' : 'RT'),
        ]);
      case PadButton.delete:
        return Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(color: bg, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: ps
              ? Container(
                  width: size * 0.42,
                  height: size * 0.42,
                  decoration: BoxDecoration(
                    border: Border.all(color: fg, width: size * 0.07),
                    borderRadius: BorderRadius.circular(size * 0.04),
                  ),
                )
              : Text('X',
                  style: TextStyle(fontFamily: 'Hanken Grotesk',
                      fontSize: size * 0.52, fontWeight: FontWeight.w800, color: fg, decoration: TextDecoration.none)),
        );
      case PadButton.menu:
        return Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(color: bg, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: ps
              ? CustomPaint(size: Size.square(size * 0.48), painter: _PsTriangle())
              : Text('Y',
                  style: TextStyle(fontFamily: 'Hanken Grotesk',
                      fontSize: size * 0.52, fontWeight: FontWeight.w800, color: fg, decoration: TextDecoration.none)),
        );
      case PadButton.select:
      case PadButton.back:
        return Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(color: bg, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: ps
              ? CustomPaint(size: Size.square(size * 0.46), painter: _PsShape(button == PadButton.select))
              : Text(button == PadButton.select ? 'A' : 'B',
                  style: TextStyle(fontFamily: 'Hanken Grotesk', 
                      fontSize: size * 0.52, fontWeight: FontWeight.w800, color: fg, decoration: TextDecoration.none)),
        );
    }
  }
}

class _PsShape extends CustomPainter {
  _PsShape(this.cross);
  final bool cross;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFF4F5F7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.16
      ..strokeCap = StrokeCap.round;
    if (cross) {
      canvas.drawLine(Offset.zero, Offset(size.width, size.height), paint);
      canvas.drawLine(Offset(size.width, 0), Offset(0, size.height), paint);
    } else {
      canvas.drawCircle(size.center(Offset.zero), size.width / 2, paint);
    }
  }

  @override
  bool shouldRepaint(_PsShape old) => old.cross != cross;
}

class _PsTriangle extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFF4F5F7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.14
      ..strokeJoin = StrokeJoin.round;
    final h = size.height;
    canvas.drawPath(
        Path()
          ..moveTo(size.width / 2, h * 0.08)
          ..lineTo(size.width, h * 0.92)
          ..lineTo(0, h * 0.92)
          ..close(),
        paint);
  }

  @override
  bool shouldRepaint(_PsTriangle old) => false;
}
