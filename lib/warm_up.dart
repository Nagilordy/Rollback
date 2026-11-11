// Draws, once and off-screen, every kind of effect Rollback's screens use (soft shadows, the
// fades at the edges of rows, see-through layers, rounded corners, pictures scaled down), right
// after the first screen appears.
//
// Why: the first time the graphics card draws an effect, it first has to prepare it, and on
// Windows with integrated graphics that took 100–360 ms per effect: Home stuttered for its first
// ~20 seconds, then was smooth. Drawn here first, behind the start screen, they're ready by the
// time Home opens. Nothing is shown; the picture is thrown away.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

Future<void> warmUpDrawing() async {
  try {
    const size = 512.0;
    // A small picture to draw scaled, like artwork.
    final art = await _picture(64, 64, (c) {
      c.drawRect(const Rect.fromLTWH(0, 0, 64, 64), Paint()..color = const Color(0xFF4A6FA5));
      c.drawCircle(const Offset(32, 32), 20, Paint()..color = const Color(0xFFE4A15A));
    });

    final image = await _picture(size.toInt(), size.toInt(), (c) {
      final card = RRect.fromRectAndRadius(const Rect.fromLTWH(96, 96, 200, 300), const Radius.circular(12));

      // Soft shadow (BoxShadow with a blur), at a few sizes.
      for (final sigma in [4.0, 12.0, 24.0, 40.0]) {
        c.drawRRect(card.shift(const Offset(0, 20)),
            Paint()
              ..color = const Color(0x99000000)
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma));
      }

      // Rounded clip with a scaled picture inside (cards, posters), smooth and sharp scaling.
      for (final q in [FilterQuality.low, FilterQuality.medium, FilterQuality.high]) {
        c.save();
        c.clipRRect(card, doAntiAlias: true);
        c.drawImageRect(art, const Rect.fromLTWH(0, 0, 64, 64), card.outerRect, Paint()..filterQuality = q);
        c.restore();
      }

      // A see-through layer (fading things in and out).
      c.saveLayer(const Rect.fromLTWH(0, 0, size, size), Paint()..color = const Color(0x80FFFFFF));
      c.drawRRect(card, Paint()..color = const Color(0xFFFFFFFF));
      c.restore();

      // The fade at a row's edges (ShaderMask: a gradient cutting into a layer).
      c.saveLayer(const Rect.fromLTWH(0, 0, size, size), Paint());
      c.drawImageRect(art, const Rect.fromLTWH(0, 0, 64, 64), const Rect.fromLTWH(0, 0, size, size), Paint());
      c.drawRect(
          const Rect.fromLTWH(0, 0, size, size),
          Paint()
            ..blendMode = BlendMode.dstIn
            ..shader = const LinearGradient(
              colors: [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
              stops: [0.0, 0.2, 0.8, 1.0],
            ).createShader(const Rect.fromLTWH(0, 0, size, size)));
      c.restore();

      // Shading gradients over backdrops, and the ring around a selected card.
      c.drawRect(
          const Rect.fromLTWH(0, 0, size, size),
          Paint()
            ..shader = const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x00000000), Color(0xCC000000)],
            ).createShader(const Rect.fromLTWH(0, 0, size, size)));
      c.drawRRect(
          card.inflate(4),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4
            ..color = const Color(0xE6FFFFFF));
    });
    art.dispose();
    image.dispose();
  } catch (_) {
    // Only a head start: if it fails, effects are prepared when first shown, as before.
  }
}

Future<ui.Image> _picture(int w, int h, void Function(Canvas) draw) {
  final recorder = ui.PictureRecorder();
  draw(Canvas(recorder, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble())));
  final picture = recorder.endRecording();
  return picture.toImage(w, h).whenComplete(picture.dispose);
}
