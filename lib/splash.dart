// The start screen: the Rollback mark breathing, with soft rings going out like a heartbeat,
// while Rollback starts and reaches your server. Usually under a second, then it fades into
// Home. (Design: the "Start: the Rollback mark pulsing while it connects" board.)

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'ui.dart';

class RollbackSplash extends StatefulWidget {
  const RollbackSplash({super.key, this.serverName});

  /// Shown as "Connecting to <name>"; nothing under the name when there's no server yet.
  final String? serverName;

  @override
  State<RollbackSplash> createState() => _RollbackSplashState();
}

class _RollbackSplashState extends State<RollbackSplash> with TickerProviderStateMixin {
  // One breath of the mark, and one ring going out, every 1.8 s (a second ring half a beat later).
  late final AnimationController _beat =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();
  // The three dots after "Connecting to …", one after another, every 1.2 s.
  late final AnimationController _dots =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();

  @override
  void dispose() {
    _beat.dispose();
    _dots.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    if (reduceMotion) {
      _beat.stop();
      _dots.stop();
    }
    return ColoredBox(
      color: kBg,
      child: TvCanvas(
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            RepaintBoundary(
              child: SizedBox(
                width: 200,
                height: 200,
                child: AnimatedBuilder(
                  animation: _beat,
                  builder: (_, __) {
                    final t = _beat.value;
                    return Stack(alignment: Alignment.center, children: [
                      if (!reduceMotion) _ring(t),
                      if (!reduceMotion) _ring((t + 0.5) % 1),
                      Transform.scale(
                        // ease-in-out 1 → 1.06 → 1
                        scale: 1 + 0.06 * (0.5 - 0.5 * math.cos(2 * math.pi * t)),
                        child: const SizedBox(width: 150, height: 150, child: CustomPaint(painter: RollbackMarkPainter())),
                      ),
                    ]);
                  },
                ),
              ),
            ),
            const SizedBox(height: 44),
            Text('Rollback', style: tvDisplay(44)),
            const SizedBox(height: 14),
            SizedBox(
              height: 30,
              child: widget.serverName == null
                  ? null
                  : Row(mainAxisSize: MainAxisSize.min, children: [
                      Text('Connecting to ${widget.serverName}', style: tvBody(22, color: kMuted)),
                      const SizedBox(width: 10),
                      RepaintBoundary(
                        child: AnimatedBuilder(
                          animation: _dots,
                          builder: (_, __) => Row(children: [
                            for (var i = 0; i < 3; i++) ...[
                              if (i > 0) const SizedBox(width: 5),
                              _dot(reduceMotion ? 1 : _dotOpacity(_dots.value, i)),
                            ],
                          ]),
                        ),
                      ),
                    ]),
            ),
          ]),
        ),
      ),
    );
  }

  // A ring: from 90% to 190% of the mark's circle, fading from 55% to nothing (ease-out).
  Widget _ring(double t) {
    final e = Curves.easeOut.transform(t);
    return Opacity(
      opacity: 0.55 * (1 - e),
      child: Transform.scale(
        scale: 0.9 + 1.0 * e,
        child: Container(
          width: 200,
          height: 200,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: kFg.withOpacity(0.5), width: 2),
          ),
        ),
      ),
    );
  }

  // Each dot goes 25% → 100% → 25%, the next one 0.2 s after the one before.
  static double _dotOpacity(double v, int i) {
    final phase = (v - i * 0.2 / 1.2) % 1;
    return 0.25 + 0.75 * (0.5 - 0.5 * math.cos(2 * math.pi * phase));
  }

  static Widget _dot(double opacity) => Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(shape: BoxShape.circle, color: kMuted.withOpacity(opacity)),
      );
}

/// Rollback's mark (docs/logo/mark.svg), drawn: a cream card with three small windows down the
/// left and a big one on the right, topped with an orange strip.
class RollbackMarkPainter extends CustomPainter {
  const RollbackMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide / 64;
    canvas.save();
    canvas.translate((size.width - 64 * s) / 2, (size.height - 64 * s) / 2);
    canvas.scale(s);
    RRect r(double x, double y, double w, double h, double rad) =>
        RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(rad));
    final card = Path()
      ..fillType = PathFillType.evenOdd
      ..addRRect(r(8, 6, 48, 52, 3))
      ..addRRect(r(13, 13, 7, 7, 1))
      ..addRRect(r(13, 28.5, 7, 7, 1))
      ..addRRect(r(13, 44, 7, 7, 1))
      ..addRect(const Rect.fromLTWH(25, 13, 25, 38));
    canvas.drawPath(card, Paint()..color = const Color(0xFFF3ECE4));
    canvas.drawRect(const Rect.fromLTWH(25, 13, 25, 6), Paint()..color = const Color(0xFFE4A15A));
    canvas.restore();
  }

  @override
  bool shouldRepaint(RollbackMarkPainter old) => false;
}

/// Three small dots that light up one after another: "still working on it". Used after
/// "Connecting" on a server card.
class ConnectingDots extends StatefulWidget {
  const ConnectingDots({super.key, required this.color, this.size = 6});
  final Color color;
  final double size;

  @override
  State<ConnectingDots> createState() => _ConnectingDotsState();
}

class _ConnectingDotsState extends State<ConnectingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, __) => Row(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) SizedBox(width: widget.size * 0.8),
              Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withOpacity(_RollbackSplashState._dotOpacity(_c.value, i)),
                ),
              ),
            ],
          ]),
        ),
      );
}
