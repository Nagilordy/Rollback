// Shared look and behavior for every TV-style screen: colors, text styles, the 1920x1080 canvas,
// focusable cards and buttons, and the top tabs built from my Jellyfin libraries.

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:frame_video/frame_video.dart' show FrameVideo;
import 'package:window_manager/window_manager.dart';

import 'gamepad.dart' show padActive;
import 'images.dart' show ShadeOverlay, logoMatte;

// ---------- Full screen (PC only) ----------

final bool isDesktop = Platform.isLinux || Platform.isWindows || Platform.isMacOS;

// Whether the app is full screen right now, so the player button can show the right icon.
final ValueNotifier<bool> fullScreen = ValueNotifier(false);

// Full screen is a choice, never automatic (this is a PC app): F11 anywhere, the controller's
// touchpad / Create button (shown in the controller legend), the button in the player, or
// double-clicking the video.
Future<void> toggleFullScreen() => setFullScreen(!fullScreen.value);

// One change at a time: pressing F11 (or double-clicking) quickly used to start a new change
// while the window was still in the middle of the last one, and Windows could end up drawing
// the old "Windows Basic" title bar. Requests now wait their turn; only the last one counts.
Future<void> _fullScreenChain = Future.value();
Future<void> setFullScreen(bool on) {
  if (!isDesktop) return Future.value();
  fullScreen.value = on;
  return _fullScreenChain = _fullScreenChain.then((_) => _applyFullScreen());
}

Future<void> _applyFullScreen() async {
  final on = fullScreen.value; // the latest wish, if several came in meanwhile
  try {
    // Windows: in one step, with Rollback's own window code (see frame_video_plugin.cpp).
    if (Platform.isWindows) {
      if (on == _windowsFullScreen) return;
      if (await FrameVideo.setFullScreen(on)) {
        _windowsFullScreen = on;
        return;
      }
    }
    if (await windowManager.isFullScreen() == on) return;
    await windowManager.setFullScreen(on);
    if (!on && Platform.isWindows) {
      // window_manager can leave the old "Windows Basic" title bar; redraw the frame now and
      // once more when Windows has finished restyling the window.
      await FrameVideo.refreshFrame();
      await Future.delayed(const Duration(milliseconds: 250));
      await FrameVideo.refreshFrame();
    }
  } catch (e) {
    fullScreen.value = !on;
    debugPrint('Full screen failed: $e');
  }
}

bool _windowsFullScreen = false;

// ---------- Colors and text ----------

const kBg = Color(0xFF06080B);
const kFg = Color(0xFFF4F5F7);
const kMuted = Color(0xFFB9C0CB);
const kSoft = Color(0xFFD3D8E0);
const kDim = Color(0xFF8E97A6);
const kPlaceholder = Color(0xFF1C2230);

// Translucent buttons over artwork: grey glass that darkens bright pictures (white text stays
// readable on a white sky) and looks like a light veil on dark ones.
const kPillFill = Color(0x8C4A4E57);

// Text styles are made once and reused: screens ask for the same few sizes over and over.
final Map<String, TextStyle> _styleCache = {};

TextStyle tvBody(double size, {FontWeight weight = FontWeight.w500, Color color = kFg, double? height}) {
  final key = '$size|${weight.value}|${color.value}|$height';
  return _styleCache[key] ??= TextStyle(
      fontFamily: 'Hanken Grotesk',
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
      decoration: TextDecoration.none);
}

final Map<double, TextStyle> _displayCache = {};

TextStyle tvDisplay(double size) => _displayCache[size] ??= TextStyle(
    fontFamily: 'Sora',
    fontSize: size,
    fontWeight: FontWeight.w700,
    color: kFg,
    letterSpacing: -0.02 * size,
    height: 1.05,
    decoration: TextDecoration.none);

// ---------- Shading over backdrops ----------

// Darkens the left side so text stays readable on any artwork. Eases out gradually, so it
// reads as a shadow, not a bar.
const kShadeLeft = LinearGradient(
  colors: [Color(0xD906080B), Color(0xB806080B), Color(0x8506080B), Color(0x4D06080B), Color(0x1A06080B), Color(0x0006080B)],
  stops: [0, 0.2, 0.38, 0.54, 0.7, 0.82],
);

// Light fade at the top and bottom edges, always on, so the peeking rows stay readable.
const kShadeTopBottom = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Color(0x5906080B), Color(0x0006080B), Color(0x0006080B), Color(0x4006080B), Color(0xA606080B), Color(0xE606080B)],
  stops: [0, 0.18, 0.42, 0.58, 0.78, 1],
);

// A top-to-bottom dark shade that fades in and out by changing its own colours.
//
// Fading it with an opacity animation instead costs an extra full-screen layer on every frame
// of the fade (heavy at 4K). Changing the colours draws the same single gradient, just a
// little darker or lighter each frame; fully faded out, it isn't drawn at all.
class FadingShade extends StatelessWidget {
  const FadingShade({
    super.key,
    required this.visible,
    required this.duration,
    required this.curve,
    required this.alphas,
    required this.stops,
  });

  final bool visible;
  final Duration duration;
  final Curve curve;
  final List<double> alphas; // how dark at each stop when fully shown (0 to 1)
  final List<double> stops;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: visible ? 1 : 0),
        duration: duration,
        curve: curve,
        builder: (context, t, _) {
          if (t <= 0.001) return const SizedBox.shrink();
          // Drawn once at the window's size and faded as a picture (see ShadeOverlay): a live
          // full-screen gradient on every frame was heavy on integrated graphics.
          return ShadeOverlay(
            shades: [
              LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [for (final a in alphas) kBg.withOpacity(a.clamp(0.0, 1.0))],
                stops: stops,
              ),
            ],
            opacity: t.clamp(0.0, 1.0),
          );
        },
      ),
    );
  }
}

// ---------- Surfaces: everything that pops up ----------
//
// Rollback's design has two layers (the way TV interfaces from Google, Sony and Netflix work):
//  - over the artwork (Home, show pages, the player): translucent pill buttons; selected =
//    solid white.
//  - anything that pops up (menus, panels, the keyboard, notifications): one solid dark
//    surface with soft corners and a shadow, no blur, with the same pill buttons inside.
// A thin line in your profile's colour along the top ties a surface to you. Solid surfaces
// keep text readable over any picture, and they cost far less to draw than blur.

const kSurface = Color(0xFF1A1E25);

/// The profile colour of whoever is using Rollback (set when a profile opens Home).
Color kAccent = const Color(0xFF6F8CFF);

class Surface extends StatelessWidget {
  const Surface({super.key, required this.child, this.padding, this.radius = 18, this.accentLine = true, this.width});
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double radius;
  final bool accentLine;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final column = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (accentLine) Container(height: 4, color: kAccent),
      Flexible(child: Padding(padding: padding ?? EdgeInsets.zero, child: child)),
    ]);
    return Container(
      width: width,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: const [BoxShadow(color: Color(0x99000000), blurRadius: 100, offset: Offset(0, 40))],
      ),
      // With no width from its place on screen (a box pinned only by a corner, like the
      // player's info box), size to the content: stretching to an unlimited width fails and the
      // box doesn't show at all.
      child: LayoutBuilder(
        builder: (context, constraints) => constraints.hasBoundedWidth ? column : IntrinsicWidth(child: column),
      ),
    );
  }
}

/// A row inside a surface: a pill like the buttons on Home. Selected = solid white.
Widget surfaceRow(String label,
    {required bool focused, IconData? icon, bool selected = false, bool quiet = false, Widget? trailing, double height = 64}) {
  final fg = focused ? kBg : (quiet ? kMuted : kFg);
  return AnimatedContainer(
    duration: const Duration(milliseconds: 130),
    height: height,
    padding: const EdgeInsets.symmetric(horizontal: 22),
    decoration: BoxDecoration(
      color: focused ? kFg : (quiet ? Colors.transparent : kFg.withOpacity(0.08)),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(children: [
      if (icon != null) ...[Icon(icon, size: 26, color: fg), const SizedBox(width: 16)],
      Expanded(
        child: Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tvBody(23, weight: focused || selected ? FontWeight.w700 : FontWeight.w600, color: fg)),
      ),
      if (selected) Icon(Icons.check_rounded, size: 26, color: fg),
      if (trailing != null) trailing,
    ]),
  );
}

/// Kept for the screens that still say Frost: now the same solid surface (no blur).
/// [edgeLeft]: a panel along the right edge of the screen (square corners on that side).
class Frost extends StatelessWidget {
  const Frost({super.key, required this.child, this.padding, this.radius = 0, this.edgeLeft = false});
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double radius;
  final bool edgeLeft;

  @override
  Widget build(BuildContext context) =>
      Surface(radius: radius > 18 ? 18 : radius, padding: padding, child: child);
}

/// The soft drop shadow under a selected card (place it first in a Stack under the card). It
/// fades in and out instead of growing: the blurred shadow is then the same picture on every
/// frame, so the graphics chip draws it once and reuses it. Growing it redrew the blur on
/// every frame of the card's animation, one of the costliest things a small graphics chip
/// draws, above all in 4K. Same look.
class CardShadow extends StatelessWidget {
  const CardShadow({super.key, required this.on, this.radius = 12});
  final bool on;
  final double radius;

  @override
  Widget build(BuildContext context) => Positioned.fill(
        child: IgnorePointer(
          child: AnimatedOpacity(
            opacity: on ? 1 : 0,
            duration: const Duration(milliseconds: 160),
            child: RepaintBoundary(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius),
                  boxShadow: const [BoxShadow(color: Color(0x99000000), blurRadius: 40, offset: Offset(0, 20))],
                ),
              ),
            ),
          ),
        ),
      );
}

// ---------- Phones ----------
//
// On a phone (not a tablet, not a computer) the screens that have one use a touch layout in
// real phone sizes instead of the 1920x1080 TV canvas, upright or sideways. Screens that don't
// have one yet keep the TV canvas and turn the phone sideways while they're open.

bool isPhone(BuildContext context) => !isDesktop && MediaQuery.sizeOf(context).shortestSide < 600;
bool isUpright(BuildContext context) {
  final s = MediaQuery.sizeOf(context);
  return s.height > s.width;
}

/// A phone screen with a touch layout: upright and sideways both allowed.
void phoneAnyOrientation() {
  if (isDesktop) return;
  SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
}

/// A TV-style screen (or the player) on a phone: sideways only.
void phoneSidewaysOnly() {
  if (isDesktop) return;
  SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
}

/// Side margin on a phone: at least [min], more where the camera cutout or rounded corners are.
EdgeInsets phoneMargins(BuildContext context, {double min = 20}) {
  final p = MediaQuery.paddingOf(context);
  return EdgeInsets.only(left: p.left > min ? p.left : min, right: p.right > min ? p.right : min);
}

// ---------- The TV canvas ----------

// How much bigger (or smaller) the screen is than the 1920x1080 design, so images can be
// decoded at the size they're really shown. Same look on every device.
double tvDecodeScale = 1;
int tvPx(double designPixels) => (designPixels * tvDecodeScale).ceil();

/// Sets [tvDecodeScale] from the window's real scale, rounded up to steps of a quarter.
/// Without the steps, every size the window passes through (leaving full screen, dragging an
/// edge) asked for every picture on screen to be decoded again at a slightly different size:
/// on Windows that briefly piled up gigabytes of pictures and froze Home for seconds. Rounded
/// up, so pictures are never shown softer than before.
///
/// While the window is being resized (or going in or out of full screen, which passes through
/// several sizes), the new scale waits until the size has settled for 400 ms: pictures are then
/// decoded again once, not at every step of the drag. Meanwhile they're shown slightly scaled.
final tvDecodeScaleN = ValueNotifier<double>(1);
bool _tvDecodeScaleSet = false;
Timer? _tvDecodeScaleTimer;
void setTvDecodeScale(double raw) {
  final next = ((raw * 4).ceil() / 4).clamp(0.5, 2.0);
  if (!_tvDecodeScaleSet) {
    _tvDecodeScaleSet = true;
    tvDecodeScale = next;
    tvDecodeScaleN.value = next;
    return;
  }
  if (next == tvDecodeScale) {
    _tvDecodeScaleTimer?.cancel();
    return;
  }
  _tvDecodeScaleTimer?.cancel();
  _tvDecodeScaleTimer = Timer(const Duration(milliseconds: 400), () {
    tvDecodeScale = next;
    tvDecodeScaleN.value = next; // the screens rebuild their pictures at the new size
  });
}

// Rounds an image size up to a step of 160 px, so small window changes reuse the same saved
// artwork instead of downloading a slightly different size.
int sizeBucket(int px) => ((px + 159) ~/ 160) * 160;

// Lays out a screen as if it were 1920x1080, scaled to the window, and stretched to fill the
// window's real shape so wider or taller windows get more room instead of black bars.
/// Phones and tablets: how tall the on-screen keyboard is right now (0 when it's closed).
/// The app root takes the keyboard out of the layout (so screens are never squeezed and
/// rescaled when it opens) and reports its height here instead; TvCanvas then slides the
/// screen up just enough to keep the field being typed in above the keyboard.
final keyboardInset = ValueNotifier<double>(0);

class TvCanvas extends StatefulWidget {
  const TvCanvas({super.key, required this.child});
  final Widget child;

  @override
  State<TvCanvas> createState() => _TvCanvasState();
}

class _TvCanvasState extends State<TvCanvas> {
  double _shift = 0; // how far the screen is slid up for the keyboard

  @override
  void initState() {
    super.initState();
    // Phones: this screen has no upright layout yet, so it turns sideways.
    phoneSidewaysOnly();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // Rebuilt when the picture scale settles after a resize (see setTvDecodeScale).
    final canvas = ValueListenableBuilder<double>(
      valueListenable: tvDecodeScaleN,
      builder: (context, _, __) => LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth, h = box.maxHeight;
        final scale = (w / 1920) < (h / 1080) ? w / 1920 : h / 1080;
        setTvDecodeScale(scale * mq.devicePixelRatio);
        return FittedBox(
          fit: BoxFit.fill,
          child: SizedBox(width: w / scale, height: h / scale, child: widget.child),
        );
      }),
    );
    if (isDesktop) return canvas;
    return ValueListenableBuilder<double>(
      valueListenable: keyboardInset,
      builder: (context, inset, _) {
        var shift = 0.0;
        final r = inset > 0 ? FocusManager.instance.primaryFocus?.rect : null;
        if (r != null) {
          final visibleBottom = mq.size.height - inset;
          final bottom = r.bottom + _shift; // where the field is without the slide
          if (bottom + 24 > visibleBottom) shift = bottom + 24 - visibleBottom;
        }
        _shift = shift;
        return ClipRect(child: Transform.translate(offset: Offset(0, -shift), child: canvas));
      },
    );
  }
}

// ---------- Reading Jellyfin items ----------

String titleOf(dynamic item) =>
    (item['Type'] == 'Episode' ? item['SeriesName'] : item['Name'])?.toString() ?? 'Untitled';

// "S2 · E5 · The Jedi" for episodes, empty otherwise.
String episodeLine(dynamic item) {
  if (item['Type'] != 'Episode') return '';
  final s = item['ParentIndexNumber'];
  final e = item['IndexNumber'];
  return [if (s != null) 'S$s', if (e != null) 'E$e', item['Name'] ?? ''].join(' · ');
}

// "4K · Dolby Vision · 7.1"
String qualityLine(dynamic item) {
  final streams = (item['MediaStreams'] as List?) ?? [];
  final video = streams.cast<dynamic>().firstWhere((s) => s['Type'] == 'Video', orElse: () => null);
  final audio = streams.cast<dynamic>().firstWhere((s) => s['Type'] == 'Audio', orElse: () => null);
  final parts = <String>[];
  if (video != null) {
    final w = (video['Width'] ?? 0) as int;
    parts.add(w >= 3200 ? '4K' : w >= 1800 ? '1080p' : w >= 1200 ? '720p' : 'SD');
    final range = (video['VideoRangeType'] ?? '').toString();
    if (range.startsWith('DOVI')) {
      parts.add('Dolby Vision');
    } else if (range == 'HDR10Plus') {
      parts.add('HDR10+');
    } else if (range == 'HDR10' || range == 'HLG') {
      parts.add(range);
    }
  }
  if (audio != null) {
    final ch = audio['Channels'] ?? 0;
    parts.add(ch >= 8 ? '7.1' : ch >= 6 ? '5.1' : 'Stereo');
  }
  return parts.join(' · ');
}

// Short badge for a poster: "4K · DV", "4K · HDR10", "1080p".
String qualityBadge(dynamic item) => qualityLine(item)
    .replaceAll('Dolby Vision', 'DV')
    .replaceAll(RegExp(r' · (7\.1|5\.1|Stereo)$'), '');

double progressOf(dynamic item) {
  final pos = (item['UserData']?['PlaybackPositionTicks'] ?? 0) as int;
  final total = (item['RunTimeTicks'] ?? 0) as int;
  if (pos <= 0 || total <= 0) return 0;
  return (pos / total).clamp(0.0, 1.0);
}

bool isWatched(dynamic item) => item['UserData']?['Played'] == true;

int minutesLeft(dynamic item) {
  final pos = (item['UserData']?['PlaybackPositionTicks'] ?? 0) as int;
  final total = (item['RunTimeTicks'] ?? 0) as int;
  return ((total - pos) / 600000000).ceil().clamp(0, 1 << 30);
}

int runtimeMinutes(dynamic item) => (((item['RunTimeTicks'] ?? 0) as int) / 600000000).round();

// ---------- Anything you can move to with arrows and press with Enter ----------

class Focusable extends StatefulWidget {
  const Focusable({
    super.key,
    required this.builder,
    required this.onSelect,
    this.onFocus,
    this.autofocus = false,
    this.focusNode,
    this.scrollAlignment,
  });

  final Widget Function(bool focused) builder;
  final VoidCallback onSelect;
  // viaMouse is true when focus came from hovering, so callers can skip automatic scrolling.
  final void Function(bool viaMouse)? onFocus;
  final bool autofocus;
  final FocusNode? focusNode;
  // Where the focused item should land in its scrolling list (0 = start, 0.5 = middle).
  // Left empty, it lands at the 120 px left margin, which suits horizontal rows.
  final double? scrollAlignment;

  @override
  State<Focusable> createState() => _FocusableState();
}

class _FocusableState extends State<Focusable> {
  FocusNode? _own;
  FocusNode get _node => widget.focusNode ?? (_own ??= FocusNode());
  bool _focused = false;
  bool _hoverRequested = false;

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      focusNode: _node,
      autofocus: widget.autofocus,
      mouseCursor: SystemMouseCursors.click,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onSelect();
          return null;
        }),
      },
      onFocusChange: (f) {
        setState(() => _focused = f);
        if (f) {
          final viaMouse = _hoverRequested;
          _hoverRequested = false;
          widget.onFocus?.call(viaMouse);
          // Keyboard or controller: scroll so the focused item is in view.
          // Mouse: never scroll, or the list would move under the pointer and keep re-selecting.
          if (!viaMouse) {
            final position = Scrollable.maybeOf(context)?.position;
            final box = context.findRenderObject();
            if (position != null && box != null && position.hasViewportDimension) {
              position.ensureVisible(box,
                  alignment: widget.scrollAlignment ?? 120 / position.viewportDimension,
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic);
            }
          }
        }
      },
      // Hovering selects the item (highlight), without scrolling anything.
      onShowHoverHighlight: (hovering) {
        // While the controller is in use, the pointer never moves focus.
        if (hovering && !_node.hasFocus && !padActive.value) {
          _hoverRequested = true;
          _node.requestFocus();
        }
      },
      child: GestureDetector(onTap: widget.onSelect, child: widget.builder(_focused)),
    );
  }
}

// A rounded pill: tabs, filter chips, small buttons.
Widget tvPill(String label, {required bool focused, bool on = false, IconData? icon, double size = 22}) {
  final fill = focused ? kFg : (on ? kFg.withOpacity(0.18) : kFg.withOpacity(0.08));
  final color = focused ? kBg : (on ? kFg : kMuted);
  return AnimatedContainer(
    duration: const Duration(milliseconds: 140),
    height: 52,
    padding: const EdgeInsets.symmetric(horizontal: 22),
    decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(999)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      if (icon != null) ...[Icon(icon, size: size, color: color), const SizedBox(width: 8)],
      Text(label, style: tvBody(size, weight: on || focused ? FontWeight.w700 : FontWeight.w500, color: color)),
    ]),
  );
}

// ---------- Fixed Up / Down / Left / Right jumps between parts of a screen ----------

// Flutter normally guesses where an arrow goes from where things sit on screen. That breaks
// when parts slide around (hero layout) or aren't lined up (buttons far left, rows far right).
// A section wrapped in FocusLinks sends an arrow to a chosen place instead. Each callback
// returns true if it moved focus; false lets Flutter guess as usual.
class FocusLinks extends StatelessWidget {
  const FocusLinks({super.key, this.up, this.down, this.left, this.right, required this.child});
  final bool Function()? up, down, left, right;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        final go = key == LogicalKeyboardKey.arrowUp
            ? up
            : key == LogicalKeyboardKey.arrowDown
                ? down
                : key == LogicalKeyboardKey.arrowLeft
                    ? left
                    : key == LogicalKeyboardKey.arrowRight
                        ? right
                        : null;
        if (go != null && go()) return KeyEventResult.handled;
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}

// Names for focus nodes, printed in the terminal when they get focus (debug names are
// stripped from release builds, so they're kept here instead).
final Expando<String> focusLabels = Expando('focus label');

FocusNode namedNode(String name) {
  final n = FocusNode();
  focusLabels[n] = name;
  return n;
}

// Moves focus to a node if it's on screen. Returns false if it can't.
bool focusOn(FocusNode? node) {
  if (node == null || node.context == null || !node.canRequestFocus) return false;
  node.requestFocus();
  return true;
}

// A list of focus nodes, one per item, that grows as needed and keeps each node when the
// list reloads, so focus stays put after coming back from a video.
class FocusNodeList {
  FocusNodeList([this.name = 'item']);
  final String name;
  final List<FocusNode> _nodes = [];
  FocusNode operator [](int i) {
    while (_nodes.length <= i) {
      _nodes.add(namedNode('$name ${_nodes.length + 1}'));
    }
    return _nodes[i];
  }

  bool get anyFocused => _nodes.any((n) => n.hasFocus);

  // The first one that is currently on screen.
  bool focusFirstVisible() {
    for (final n in _nodes) {
      if (focusOn(n)) return true;
    }
    return false;
  }

  void dispose() {
    for (final n in _nodes) {
      n.dispose();
    }
  }
}

// ---------- Something went wrong: a short message and a Retry button ----------

class TvError extends StatelessWidget {
  const TvError({super.key, required this.message, required this.onRetry, this.label = 'Retry'});
  final String message;
  final VoidCallback onRetry;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Text(message, style: tvBody(28, color: kSoft, height: 1.35)),
      ),
      const SizedBox(height: 24),
      Focusable(
        autofocus: true,
        onSelect: onRetry,
        builder: (f) => tvPill(label, focused: f, icon: label == 'Retry' ? Icons.refresh_rounded : Icons.login_rounded, size: 24),
      ),
    ]);
  }
}

// Turns any error into a sentence for the screen.
String errorText(Object e) {
  final s = e.toString();
  return s.startsWith('Exception: ') ? s.substring(11) : s;
}

// ---------- Top tabs: Home + one tab per Jellyfin library ----------

class NavBar extends StatelessWidget {
  const NavBar({
    super.key,
    required this.libraries,
    required this.currentId,
    required this.onHome,
    required this.onLibrary,
    this.onFocus,
  });

  final List<dynamic> libraries;
  final String? currentId; // null = Home
  final VoidCallback onHome;
  final void Function(dynamic library) onLibrary;
  final void Function(bool viaMouse)? onFocus;

  @override
  Widget build(BuildContext context) {
    Widget tab(String label, bool selected, VoidCallback onSelect) => Focusable(
          onSelect: onSelect,
          onFocus: onFocus,
          builder: (f) => AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
            decoration: BoxDecoration(
              color: f ? kFg : (selected ? kPillFill : Colors.transparent),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(label,
                style: tvBody(24,
                    weight: selected || f ? FontWeight.w700 : FontWeight.w500,
                    color: f ? kBg : (selected ? kFg : kMuted))),
          ),
        );

    return FocusTraversalGroup(
      child: Wrap(spacing: 8, children: [
        tab('Home', currentId == null, onHome),
        for (final lib in libraries)
          tab(lib['Name']?.toString() ?? 'Library', lib['Id'] == currentId, () => onLibrary(lib)),
      ]),
    );
  }
}

// ---------- Warming up the graphics (desktop) ----------
//
// The first time each kind of drawing is used (rounded pictures, gradients, see-through layers,
// the soft glow, text in each font…), the graphics card first has to prepare a small program
// for it, which can take tens of milliseconds each: that was most of Home's stutter in its
// first 20–30 seconds. This draws one of each, off screen and out of sight, while Rollback
// starts, so Home's first moves find them ready. Runs once; costs a fraction of a second on
// the graphics thread, before Home is shown.
bool _warmedUp = false;

Future<void> warmUpDrawing() async {
  if (_warmedUp || !isDesktop) return;
  _warmedUp = true;
  try {
    // A small picture to draw, like the artwork.
    final art = ui.PictureRecorder();
    Canvas(art).drawRect(const Rect.fromLTWH(0, 0, 64, 96),
        Paint()..shader = ui.Gradient.linear(Offset.zero, const Offset(64, 96), [const Color(0xFF335577), const Color(0xFF884422)]));
    final image = await art.endRecording().toImage(64, 96);

    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder);
    const box = Rect.fromLTWH(0, 0, 400, 300);
    // Backdrop and its shading (left and top/bottom gradients, see-through black).
    c.drawImageRect(image, const Rect.fromLTWH(0, 0, 64, 96), box, Paint()..filterQuality = FilterQuality.low);
    c.drawImageRect(image, const Rect.fromLTWH(0, 0, 64, 96), box, Paint()..filterQuality = FilterQuality.none);
    c.drawImageRect(image, const Rect.fromLTWH(0, 0, 64, 96), box, Paint()..filterQuality = FilterQuality.medium);
    c.drawRect(box, Paint()..shader = kShadeLeft.createShader(box));
    c.drawRect(box, Paint()..shader = kShadeTopBottom.createShader(box));
    c.drawRect(box, Paint()..shader = ui.Gradient.radial(box.center, 200, [const Color(0x00000000), const Color(0xCC000000)]));
    // A card: rounded artwork with its selection ring and lift.
    final card = RRect.fromRectAndRadius(const Rect.fromLTWH(40, 40, 120, 180), const Radius.circular(18));
    c.drawRRect(card.inflate(5), Paint()..color = const Color(0x38F4F5F7));
    c.save();
    c.clipRRect(card);
    c.drawImageRect(image, const Rect.fromLTWH(0, 0, 64, 96), card.outerRect, Paint()..filterQuality = FilterQuality.low);
    c.restore();
    c.drawRRect(card, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = kFg);
    // Cards fading at the row's edge (a gradient mask over a layer).
    c.saveLayer(const Rect.fromLTWH(200, 40, 160, 180), Paint());
    c.drawImageRect(image, const Rect.fromLTWH(0, 0, 64, 96), const Rect.fromLTWH(200, 40, 160, 180), Paint());
    c.drawRect(const Rect.fromLTWH(200, 40, 160, 180), Paint()
      ..blendMode = BlendMode.dstIn
      ..shader = ui.Gradient.linear(const Offset(200, 0), const Offset(360, 0), [const Color(0xFFFFFFFF), const Color(0x00FFFFFF)]));
    c.restore();
    // Fades (see-through layers) and the soft glow behind logos.
    c.saveLayer(box, Paint()..color = const Color(0x80FFFFFF));
    c.drawImage(image, const Offset(10, 10), Paint());
    c.restore();
    c.saveLayer(box, Paint()
      ..colorFilter = const ColorFilter.mode(Color(0x99000000), BlendMode.srcIn)
      ..imageFilter = ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12));
    c.drawImage(image, const Offset(100, 100), Paint());
    c.restore();
    c.saveLayer(box, Paint()..colorFilter = logoMatte);
    c.drawImage(image, const Offset(220, 120), Paint());
    c.restore();
    // Shadows under panels and dialogs.
    c.drawRRect(card.shift(const Offset(150, 0)), Paint()
      ..color = const Color(0x99000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 20));
    // Text in Rollback's fonts and the usual weights.
    var y = 0.0;
    for (final style in [
      tvDisplay(44),
      tvBody(22),
      tvBody(28, weight: FontWeight.w700),
      tvBody(19, weight: FontWeight.w600, color: kMuted),
    ]) {
      final p = TextPainter(
        text: TextSpan(text: 'Rollback Continue watching 0123456789 ·', style: style),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 400);
      p.paint(c, Offset(0, y));
      y += p.height;
      p.dispose();
    }
    final picture = recorder.endRecording();
    final drawn = await picture.toImage(400, 300);
    drawn.dispose();
    picture.dispose();
    image.dispose();
  } catch (_) {
    // A warm-up that fails only means the first moves are a little slower, as before.
  }
}

/// Fades a card out softly where it reaches the left or right edge of its row, the way a
/// gradient mask over the whole row would, but only for a card that actually overlaps an
/// edge (usually one or two per row): every other card is drawn as is, with no extra layer.
/// (A mask over the whole row redrew it into a see-through layer the width of the screen on
/// every frame a card moved: costly at 4K, above all on Windows.)
///
/// [edge] is the width of the fade in the row's units, or [fraction] of the row's width.
/// [sides], if given, says whether each side fades right now (there's more to see that way);
/// without it both sides always fade. Put a RepaintBoundary inside, around the card, and turn
/// off the list's own boundaries (addRepaintBoundaries: false), so scrolling updates the fade.
class EdgeFade extends SingleChildRenderObjectWidget {
  const EdgeFade({super.key, this.edge = 0, this.fraction = 0, this.sides, super.child});
  final double edge;
  final double fraction;
  final ValueListenable<(bool, bool)>? sides;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderEdgeFade(edge, fraction, sides);

  @override
  void updateRenderObject(BuildContext context, _RenderEdgeFade renderObject) => renderObject
    ..edge = edge
    ..fraction = fraction
    ..sides = sides;
}

class _RenderEdgeFade extends RenderProxyBox {
  _RenderEdgeFade(this._edge, this._fraction, this._sides);
  double _edge, _fraction;
  ValueListenable<(bool, bool)>? _sides;

  set edge(double v) {
    if (v == _edge) return;
    _edge = v;
    markNeedsPaint();
  }

  set fraction(double v) {
    if (v == _fraction) return;
    _fraction = v;
    markNeedsPaint();
  }

  set sides(ValueListenable<(bool, bool)>? v) {
    if (v == _sides) return;
    if (attached) _sides?.removeListener(markNeedsPaint);
    _sides = v;
    if (attached) _sides?.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _sides?.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _sides?.removeListener(markNeedsPaint);
    super.detach();
  }

  final _mask = LayerHandle<ShaderMaskLayer>();

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final viewport = RenderAbstractViewport.maybeOf(this);
    if (viewport is! RenderBox || !hasSize) {
      _mask.layer = null;
      context.paintChild(child, offset);
      return;
    }
    final rowWidth = (viewport as RenderBox).size.width;
    final fade = _edge > 0 ? _edge : _fraction * rowWidth;
    final (leftOn, rightOn) = _sides?.value ?? (true, true);
    final left = localToGlobal(Offset.zero, ancestor: viewport).dx;
    final right = left + size.width;
    final touchesLeft = leftOn && left < fade;
    final touchesRight = rightOn && right > rowWidth - fade;
    if (fade <= 0 || (!touchesLeft && !touchesRight)) {
      _mask.layer = null; // no fade here: no layer
      context.paintChild(child, offset);
      return;
    }
    // The row's fade, placed so it lines up with the row (in this card's own coordinates).
    final rowRect = Rect.fromLTWH(offset.dx - left, offset.dy, rowWidth, size.height);
    final e = (fade / rowWidth).clamp(0.0, 0.5);
    final layer = _mask.layer ??= ShaderMaskLayer();
    layer
      ..shader = LinearGradient(
        colors: [
          leftOn ? const Color(0x00FFFFFF) : const Color(0xFFFFFFFF),
          const Color(0xFFFFFFFF),
          const Color(0xFFFFFFFF),
          rightOn ? const Color(0x00FFFFFF) : const Color(0xFFFFFFFF),
        ],
        stops: [0.0, e, 1 - e, 1.0],
      ).createShader(rowRect)
      // A little larger than the card, so its glow when selected fades with it.
      ..maskRect = (offset & size).inflate(40)
      ..blendMode = BlendMode.dstIn;
    context.pushLayer(layer, (c, o) => c.paintChild(child, o), offset);
  }

  @override
  void dispose() {
    _mask.layer = null;
    super.dispose();
  }
}
