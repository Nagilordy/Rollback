// Artwork from Jellyfin, kept on disk so it's instant the next time (and after restarting
// the app). The first time, it downloads once and saves a copy. Saved copies older than a
// few days are refreshed quietly in the background, so changed artwork shows up eventually.

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'main.dart' show Jellyfin;

class _DiskCache {
  static Future<Directory>? _dir;
  static Future<Directory> get dir => _dir ??= () async {
        final base = await getApplicationSupportDirectory();
        final d = Directory('${base.path}/artwork');
        await d.create(recursive: true);
        return d;
      }();

  // A short, file-safe name for each address (64-bit FNV-1a hash).
  static String nameFor(String url) {
    var h = 0xcbf29ce484222325;
    for (final c in url.codeUnits) {
      h ^= c;
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return h.toUnsigned(64).toRadixString(16);
  }

  static const _refreshAfter = Duration(days: 3);
  // The same picture asked for twice at once is downloaded once; both get the same answer.
  static final Map<String, Future<Uint8List>> _inFlight = {};
  static int _tmpCounter = 0;

  static Future<Uint8List> load(String url) async {
    File? file;
    try {
      file = File('${(await dir).path}/${nameFor(url)}');
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) {
          final age = DateTime.now().difference(await file.lastModified());
          if (age > _refreshAfter) unawaited(download(url, file).then((_) {}, onError: (_) {}));
          return bytes;
        }
      }
    } catch (_) {
      // Disk trouble: just download it.
    }
    return download(url, file);
  }

  // (The braces matter: written as `() => _inFlight.remove(url)`, the cleanup would hand back
  // the download itself, and the download would wait for itself forever.)
  static Future<Uint8List> download(String url, File? file) => _inFlight[url] ??= _fetch(url, file).whenComplete(() {
        _inFlight.remove(url);
      });

  static Future<Uint8List> _fetch(String url, File? file) async {
    final started = DateTime.now();
    final http.Response res;
    try {
      res = await Jellyfin.client.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
    } catch (e) {
      debugPrint('Image: failed after ${DateTime.now().difference(started).inMilliseconds} ms: $e  ($url)');
      rethrow;
    }
    final ms = DateTime.now().difference(started).inMilliseconds;
    if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
      debugPrint('Image: server answered ${res.statusCode} after $ms ms  ($url)');
      throw Exception('Image not available (${res.statusCode})');
    }
    // Slow ones are worth knowing about: usually the NAS making that size for the first time.
    if (ms > 1500) debugPrint('Image: slow, $ms ms  ($url)');
    if (file != null) {
      try {
        // Written under a temporary name first, so a half-written file is never used.
        final tmp = File('${file.path}.${_tmpCounter++}.part');
        await tmp.writeAsBytes(res.bodyBytes, flush: true);
        await tmp.rename(file.path);
      } catch (_) {
        // Couldn't save it: still show it.
      }
    }
    return res.bodyBytes;
  }

  // A saved file that turned out to be damaged: delete it so it's downloaded again.
  static Future<void> forget(String url) async {
    try {
      await File('${(await dir).path}/${nameFor(url)}').delete();
    } catch (_) {}
  }

  // Keeps the saved artwork under 600 MB: at each startup, the least recently saved
  // pictures are removed until it fits. Runs in the background.
  static const _maxBytes = 600 * 1024 * 1024;
  static Future<void> tidy() async {
    try {
      final d = await dir;
      final files = <(File, FileStat)>[];
      var total = 0;
      await for (final e in d.list()) {
        if (e is! File) continue;
        final stat = await e.stat();
        if (e.path.endsWith('.part') && DateTime.now().difference(stat.modified).inHours > 1) {
          await e.delete(); // leftovers from a crash
          continue;
        }
        files.add((e, stat));
        total += stat.size;
      }
      if (total <= _maxBytes) return;
      files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      for (final (file, stat) in files) {
        if (total <= _maxBytes * 0.8) break;
        try {
          await file.delete();
          total -= stat.size;
        } catch (_) {}
      }
    } catch (_) {}
  }
}

/// Tidies the saved artwork in the background (call once at startup).
void tidyArtworkCache() => unawaited(_DiskCache.tidy());

/// Like NetworkImage, but saved on disk.
@immutable
class CachedNetImage extends ImageProvider<CachedNetImage> {
  const CachedNetImage(this.url);
  final String url;

  @override
  Future<CachedNetImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(CachedNetImage key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _load(decode),
      scale: 1,
      debugLabel: url,
    );
  }

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final bytes = await _DiskCache.load(url);
    try {
      return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    } catch (e) {
      debugPrint('Image: could not be read ($e), downloading it again  ($url)');
      // The saved copy is damaged (or the server sent something broken): throw it away and
      // download it once more, so a bad file can't stick forever.
      await _DiskCache.forget(url);
      final fresh = await _DiskCache.download(url, null);
      return decode(await ui.ImmutableBuffer.fromUint8List(fresh));
    }
  }

  @override
  bool operator ==(Object other) => other is CachedNetImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

/// Loads and decodes a picture now, exactly as netImage will show it (same size, same saved
/// copy), so it appears without waiting when it's needed.
void precacheNet(BuildContext context, String url, {int? cacheWidth, int? cacheHeight}) {
  precacheImage(ResizeImage.resizeIfNeeded(cacheWidth, cacheHeight, CachedNetImage(url)), context,
      onError: (_, __) {});
}

/// Drop-in replacement for Image.network that keeps the artwork on disk.
Widget netImage(
  String url, {
  int? cacheWidth,
  int? cacheHeight,
  double? width,
  double? height,
  BoxFit? fit,
  AlignmentGeometry alignment = Alignment.center,
  bool gaplessPlayback = false,
  ImageErrorWidgetBuilder? errorBuilder,
  Key? key,
}) {
  return Image(
    key: key,
    image: ResizeImage.resizeIfNeeded(cacheWidth, cacheHeight, CachedNetImage(url)),
    width: width,
    height: height,
    fit: fit,
    alignment: alignment,
    gaplessPlayback: gaplessPlayback,
    errorBuilder: errorBuilder,
    filterQuality: netFilterQuality(cacheWidth, cacheHeight),
  );
}

/// How a picture is smoothed when drawn. Flutter's default ("medium") first builds a set of
/// smaller copies of every picture (mipmaps) for when it's shown much smaller than it is; on
/// weak graphics that was a big part of Home's slow frames each time new artwork appeared.
/// A picture decoded at the size it's shown (cacheWidth / cacheHeight) never needs them, and
/// plain smoothing looks the same. Pictures without a decode size keep the default.
FilterQuality netFilterQuality(int? cacheWidth, int? cacheHeight) =>
    cacheWidth != null || cacheHeight != null ? FilterQuality.low : FilterQuality.medium;

/// A full-screen picture that cross-fades when it changes: the same fade as an AnimatedSwitcher
/// (old fading out while the new one fades in, both partly see-through halfway), but each picture
/// is drawn straight with its see-through amount. AnimatedSwitcher's fade first draws each one
/// into an off-screen copy of the whole screen, every frame of the fade: two full-screen copies
/// per frame, heavy on integrated graphics.
class NetImageCrossfade extends StatefulWidget {
  const NetImageCrossfade({
    super.key,
    required this.url,
    required this.cacheWidth,
    this.duration = const Duration(milliseconds: 450),
    this.alignment = Alignment.center,
    this.fit = BoxFit.cover,
    this.empty = Colors.black,
    this.error = Colors.black,
  });

  /// The picture's address; null shows [empty].
  final String? url;
  final int? cacheWidth;
  final Duration duration;
  final AlignmentGeometry alignment;
  final BoxFit fit;
  final Color empty;
  final Color error;

  @override
  State<NetImageCrossfade> createState() => _NetImageCrossfadeState();
}

class _NetImageCrossfadeState extends State<NetImageCrossfade> with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(vsync: this, duration: widget.duration, value: 1)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed && _previous != null && mounted) setState(() => _previous = null);
    });
  String? _previous;
  double _previousFrom = 1;

  @override
  void didUpdateWidget(NetImageCrossfade old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      // A change mid-fade: the outgoing picture fades on from where it was.
      _previousFrom = _fade.value;
      _previous = old.url;
      _fade.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  Widget _picture(String? url, Animation<double> opacity) {
    if (url == null) {
      return FadeTransition(opacity: opacity, child: ColoredBox(color: widget.empty, child: const SizedBox.expand()));
    }
    return Image(
      key: ValueKey(url),
      image: ResizeImage.resizeIfNeeded(widget.cacheWidth, null, CachedNetImage(url)),
      width: double.infinity,
      height: double.infinity,
      fit: widget.fit,
      alignment: widget.alignment,
      opacity: opacity,
      gaplessPlayback: true,
      filterQuality: netFilterQuality(widget.cacheWidth, null),
      errorBuilder: (_, __, ___) =>
          FadeTransition(opacity: opacity, child: ColoredBox(color: widget.error, child: const SizedBox.expand())),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fading = _fade.isAnimating || _previous != null;
    return Stack(fit: StackFit.expand, children: [
      if (fading) _picture(_previous, _fade.drive(Tween(begin: _previousFrom, end: 0.0))),
      _picture(widget.url, fading ? _fade : const AlwaysStoppedAnimation(1.0)),
    ]);
  }
}

// ---------- Title logos ----------
//
// Some logos on Jellyfin are pictures with a solid black background instead of a see-through
// one, which shows as a black box over the artwork. Rollback checks the edges of each logo once:
// if they're solid black, it turns black into see-through (bright parts stay, dark parts fade
// away), so the logo sits on the artwork like a proper one.

final Map<String, bool> _matteCache = {};

/// Black stays black and see-through; everything else keeps its colour and shows.
const ColorFilter logoMatte = ColorFilter.matrix(<double>[
  1, 0, 0, 0, 0, //
  0, 1, 0, 0, 0, //
  0, 0, 1, 0, 0, //
  0.85, 0.85, 0.85, 0, 0, // alpha from brightness (white = solid, black = see-through)
]);

/// True when the logo's edges are solid black (no see-through background).
Future<bool> logoNeedsMatte(String url, ui.Image image) async {
  final known = _matteCache[url];
  if (known != null) return known;
  var result = false;
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data != null) {
      // A proper logo always has see-through areas. If every spot checked across the
      // picture is solid, and its border is mostly dark, the background is a black box.
      final w = image.width, h = image.height;
      int at(int x, int y) => (y.clamp(0, h - 1).toInt() * w + x.clamp(0, w - 1).toInt()) * 4;
      var seeThrough = false;
      for (var gy = 0; gy < 16 && !seeThrough; gy++) {
        for (var gx = 0; gx < 16; gx++) {
          if (data.getUint8(at((w - 1) * gx ~/ 15, (h - 1) * gy ~/ 15) + 3) < 200) {
            seeThrough = true;
            break;
          }
        }
      }
      var dark = 0, border = 0;
      for (var k = 0; k <= 20; k++) {
        for (final (x, y) in [
          ((w - 1) * k ~/ 20, 0), ((w - 1) * k ~/ 20, h - 1), (0, (h - 1) * k ~/ 20), (w - 1, (h - 1) * k ~/ 20),
        ]) {
          final i = at(x, y);
          border++;
          if (data.getUint8(i) < 60 && data.getUint8(i + 1) < 60 && data.getUint8(i + 2) < 60) dark++;
        }
      }
      result = !seeThrough && dark >= border * 0.4;
    }
  } catch (e) {
    debugPrint('Logo: could not check $url: $e');
  }
  if (result) debugPrint('Logo: black background made see-through ($url)');
  _matteCache[url] = result;
  return result;
}

/// A title logo: drawn as is, or with its black background made see-through.
class LogoImage extends StatefulWidget {
  const LogoImage({super.key, required this.url, required this.height, this.cacheHeight, this.alignment = Alignment.bottomLeft, required this.fallback});
  final String url;
  final double height;
  final int? cacheHeight;
  final Alignment alignment;
  final Widget fallback; // the title as text, if the logo can't load

  @override
  State<LogoImage> createState() => _LogoImageState();
}

class _LogoImageState extends State<LogoImage> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageInfo? _info;
  bool _matte = false;
  bool _failed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(LogoImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.cacheHeight != widget.cacheHeight) _resolve();
  }

  void _resolve() {
    final provider = ResizeImage.resizeIfNeeded(null, widget.cacheHeight, CachedNetImage(widget.url));
    final stream = provider.resolve(createLocalImageConfiguration(context));
    if (_stream != null && stream.key == _stream!.key) return;
    _stop();
    _stream = stream;
    final url = widget.url;
    _listener = ImageStreamListener((info, _) async {
      final known = _matteCache[url];
      final matte = known ?? await logoNeedsMatte(url, info.image);
      if (!mounted || url != widget.url) {
        info.dispose();
        return;
      }
      setState(() {
        _info?.dispose();
        _info = info;
        _matte = matte;
        _failed = false;
      });
    }, onError: (_, __) {
      if (mounted) setState(() => _failed = true);
    });
    stream.addListener(_listener!);
  }

  void _stop() {
    if (_stream != null && _listener != null) _stream!.removeListener(_listener!);
  }

  @override
  void dispose() {
    _stop();
    _info?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return widget.fallback;
    final info = _info;
    if (info == null) return SizedBox(height: widget.height);
    final image = RawImage(
      image: info.image,
      height: widget.height,
      fit: BoxFit.contain,
      alignment: widget.alignment,
      filterQuality: FilterQuality.medium,
    );
    return _matte ? ColorFiltered(colorFilter: logoMatte, child: image) : image;
  }
}

/// The soft dark glow behind a title logo, blurred once and kept as a picture.
///
/// Blurring live means re-blurring on every frame of any animation on screen (Flutter's
/// drawing engine on Linux doesn't keep a saved copy). This makes the glow once per logo,
/// then just draws that picture: same look, almost no cost.
///
/// Place it in a Stack (Positioned.fill) behind the logo; it spills out around the logo.
class BakedGlow extends StatefulWidget {
  const BakedGlow({super.key, required this.url, this.cacheHeight, this.sigma = 16, this.opacity = 0.75});
  final String url;
  final int? cacheHeight;
  final double sigma; // blur size, in layout units (same as ImageFilter.blur on screen)
  final double opacity;

  @override
  State<BakedGlow> createState() => _BakedGlowState();
}

class _BakedGlowState extends State<BakedGlow> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ui.Image? _glow;
  double _padFraction = 0; // padding around the logo, as a fraction of the logo's height
  int _job = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(BakedGlow old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.cacheHeight != widget.cacheHeight) _resolve();
  }

  void _resolve() {
    final provider = ResizeImage.resizeIfNeeded(null, widget.cacheHeight, CachedNetImage(widget.url));
    final stream = provider.resolve(createLocalImageConfiguration(context));
    if (_stream != null && stream.key == _stream!.key) return;
    _stopListening();
    _stream = stream;
    _listener = ImageStreamListener((info, _) {
      // Keep our own handle on the picture while the glow is being made.
      _bake(info.image.clone());
      info.dispose();
    }, onError: (_, __) {});
    stream.addListener(_listener!);
  }

  void _stopListening() {
    if (_stream != null && _listener != null) _stream!.removeListener(_listener!);
  }

  Future<void> _bake(ui.Image original) async {
    final job = ++_job;
    // A logo on solid black: glow around the letters, not around the black box.
    var logo = original;
    if (await logoNeedsMatte(widget.url, original)) {
      final r = ui.PictureRecorder();
      Canvas(r).drawImage(original, Offset.zero, Paint()..colorFilter = logoMatte);
      final p = r.endRecording();
      logo = await p.toImage(original.width, original.height);
      p.dispose();
      original.dispose();
    }
    // The logo is shown about 120 units tall; work out the blur in the picture's own pixels.
    const shownHeight = 120.0;
    final pxPerUnit = logo.height / shownHeight;
    final sigmaPx = widget.sigma * pxPerUnit;
    final pad = (sigmaPx * 3).ceil();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()
      ..colorFilter = ColorFilter.mode(Colors.black.withOpacity(widget.opacity), BlendMode.srcIn)
      ..imageFilter = ui.ImageFilter.blur(sigmaX: sigmaPx, sigmaY: sigmaPx);
    canvas.drawImage(logo, Offset(pad.toDouble(), pad.toDouble()), paint);
    final picture = recorder.endRecording();
    final glow = await picture.toImage(logo.width + pad * 2, logo.height + pad * 2);
    picture.dispose();
    logo.dispose();
    if (!mounted || job != _job) {
      glow.dispose();
      return;
    }
    setState(() {
      _glow?.dispose();
      _glow = glow;
      _padFraction = pad / logo.height;
    });
  }

  @override
  void dispose() {
    _stopListening();
    _glow?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final glow = _glow;
    if (glow == null) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth < 1 || box.maxHeight < 1 || !box.maxHeight.isFinite) return const SizedBox.shrink();
      final pad = _padFraction * box.maxHeight;
      return Stack(clipBehavior: Clip.none, children: [
        Positioned(
          left: -pad,
          top: -pad,
          right: -pad,
          bottom: -pad,
          child: RawImage(image: glow, fit: BoxFit.fill),
        ),
      ]);
    });
  }
}

/// A full-screen backdrop with its shading painted in, made once and kept as one picture.
///
/// Drawn the usual way, the backdrop plus each shading layer is a separate full-screen draw,
/// repeated on every frame of any animation (at 4K that's a lot of pixels). Here they're
/// painted together once (again only if the window changes size), and every frame just
/// draws that one picture. Same look.
class BakedBackdrop extends StatefulWidget {
  const BakedBackdrop({
    super.key,
    required this.url,
    required this.cacheWidth,
    required this.pixelScale,
    this.shades = const [],
    this.alignment = Alignment.topCenter,
    this.fallback = const Color(0xFF1C2230),
  });

  final String url;
  final int cacheWidth;
  final double pixelScale; // real screen pixels per layout unit
  final List<Gradient> shades; // painted over the picture, in order
  final Alignment alignment;
  final Color fallback; // shown if the picture can't load

  @override
  State<BakedBackdrop> createState() => _BakedBackdropState();
}

class _BakedBackdropState extends State<BakedBackdrop> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ui.Image? _source;
  ui.Image? _baked;
  Size? _bakedSize;
  bool _failed = false;
  int _job = 0;
  Timer? _resizeTimer;
  bool _scheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(BakedBackdrop old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.cacheWidth != widget.cacheWidth) _resolve();
  }

  void _resolve() {
    final provider = ResizeImage.resizeIfNeeded(widget.cacheWidth, null, CachedNetImage(widget.url));
    final stream = provider.resolve(createLocalImageConfiguration(context));
    if (_stream != null && stream.key == _stream!.key) return;
    _stopListening();
    _stream = stream;
    _listener = ImageStreamListener((info, _) {
      final image = info.image.clone();
      info.dispose();
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _source?.dispose();
        _source = image;
        _bakedSize = null; // new picture: paint it again
        _failed = false;
      });
    }, onError: (_, __) {
      if (mounted) setState(() => _failed = true);
    });
    stream.addListener(_listener!);
  }

  void _stopListening() {
    if (_stream != null && _listener != null) _stream!.removeListener(_listener!);
  }

  Future<void> _bake(Size size) async {
    final source = _source;
    if (source == null || size.isEmpty) return;
    final job = ++_job;
    final k = widget.pixelScale;
    final rect = Offset.zero & size;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(k);
    paintImage(
      canvas: canvas,
      rect: rect,
      image: source,
      fit: BoxFit.cover,
      alignment: widget.alignment,
      filterQuality: FilterQuality.medium,
    );
    for (final shade in widget.shades) {
      canvas.drawRect(rect, Paint()..shader = shade.createShader(rect));
    }
    final picture = recorder.endRecording();
    final baked = await picture.toImage((size.width * k).round(), (size.height * k).round());
    picture.dispose();
    if (!mounted || job != _job) {
      baked.dispose();
      return;
    }
    setState(() {
      _baked?.dispose();
      _baked = baked;
      _bakedSize = size;
    });
  }

  @override
  void dispose() {
    _stopListening();
    _resizeTimer?.cancel();
    _source?.dispose();
    _baked?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final size = box.biggest;
      if (_source != null && size.isFinite && size != _bakedSize) {
        if (_baked == null) {
          // First paint of this picture: right after this frame.
          if (!_scheduled) {
            _scheduled = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _scheduled = false;
              if (mounted && size != _bakedSize) _bake(size);
            });
          }
        } else {
          // Window is changing size: repaint once it settles, stretching the old one meanwhile.
          _resizeTimer?.cancel();
          _resizeTimer = Timer(const Duration(milliseconds: 120), () {
            if (mounted && size != _bakedSize) _bake(size);
          });
        }
      }
      final baked = _baked;
      if (baked != null) return RawImage(image: baked, width: size.width, height: size.height, fit: BoxFit.fill);
      if (_failed) return ColoredBox(color: widget.fallback);
      return const SizedBox.expand();
    });
  }
}

/// The shading over a backdrop (dark on the left, soft fade top and bottom).
///
/// The gradients are smoothed (dithered) by the graphics card, so dark fades stay seamless; a
/// small pre-made picture stretched to 4K showed visible steps ("bars"). But drawing them live
/// cost the graphics card about 10 ms on every frame on Windows (more than everything else on
/// Home together). So they're drawn once, smoothed, into a picture exactly the window's size in
/// pixels, and that picture is shown one-to-one: nothing is stretched, so it looks the same, and
/// each frame only shows a finished picture. Made half a second after the window settles, shared
/// by every screen; until then (and while the window is resized) the live gradients are used.
class ShadeOverlay extends StatefulWidget {
  const ShadeOverlay({super.key, required this.shades, this.opacity = 1});
  final List<Gradient> shades;

  /// How much of it shows (0 to 1), for fading it in and out: the finished picture is simply
  /// drawn more see-through, which costs nothing extra.
  final double opacity;

  @override
  State<ShadeOverlay> createState() => _ShadeOverlayState();
}

class _BakedShade {
  _BakedShade(this.size, this.image);
  final Size size; // in pixels
  final ui.Image image;
}

final Map<int, _BakedShade> _bakedShades = {};
final _shadesBaked = ValueNotifier<int>(0);
final Map<int, Timer> _shadeTimers = {};

void _bakeShades(int key, List<Gradient> shades, Size px) {
  _shadeTimers[key]?.cancel();
  _shadeTimers[key] = Timer(const Duration(milliseconds: 500), () async {
    try {
      final w = px.width.round(), h = px.height.round();
      if (w <= 0 || h <= 0 || w > 8192 || h > 8192) return;
      final rect = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, rect);
      for (final g in shades) {
        canvas.drawRect(rect, Paint()..shader = g.createShader(rect));
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(w, h);
      picture.dispose();
      final old = _bakedShades[key];
      _bakedShades[key] = _BakedShade(Size(w.toDouble(), h.toDouble()), image);
      _shadesBaked.value++;
      // The old picture may still be on screen for this frame: let it go after the next one.
      if (old != null) WidgetsBinding.instance.addPostFrameCallback((_) => old.image.dispose());
    } catch (_) {
      // Only a speed-up: the live gradients stay.
    }
  });
}

class _ShadeOverlayState extends State<ShadeOverlay> {
  @override
  Widget build(BuildContext context) {
    final key = Object.hashAll(widget.shades);
    final px = MediaQuery.sizeOf(context) * MediaQuery.devicePixelRatioOf(context);
    return IgnorePointer(
      child: RepaintBoundary(
        child: ValueListenableBuilder<int>(
          valueListenable: _shadesBaked,
          builder: (context, _, __) {
            final baked = _bakedShades[key];
            final fits = baked != null &&
                (baked.size.width - px.width).abs() < 1.5 &&
                (baked.size.height - px.height).abs() < 1.5;
            if (fits) {
              return RawImage(
                image: baked.image,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.none,
                opacity: widget.opacity >= 1 ? null : AlwaysStoppedAnimation(widget.opacity),
              );
            }
            _bakeShades(key, widget.shades, px);
            // While the window changes size (dragging an edge, full screen on or off), the last
            // picture is stretched to fit: no steps can be seen while things move, and drawing
            // the gradients live here was what made resizing heavy. The exact picture follows
            // half a second after the size settles.
            if (baked != null) {
              return RawImage(
                image: baked.image,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.low,
                opacity: widget.opacity >= 1 ? null : AlwaysStoppedAnimation(widget.opacity),
              );
            }
            final live = Stack(fit: StackFit.expand, children: [
              for (final s in widget.shades) DecoratedBox(decoration: BoxDecoration(gradient: s)),
            ]);
            return widget.opacity >= 1 ? live : Opacity(opacity: widget.opacity, child: live);
          },
        ),
      ),
    );
  }
}
