import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:guidechannel/guidechannel.dart' show genreColors, textWidth, fit, sanitize;
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

/// Archive item ids we accept in /thumb URLs (anything else is refused, never touches the disk).
final thumbIdPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$');

/// Returns the Archive thumbnail bytes; null = the item has none (permanent); throws = try again later.
typedef ThumbFetch = Future<Uint8List?> Function(String itemId);

/// GET https://archive.org/services/img/<id> (redirects followed), 20 s timeout, no retries.
ThumbFetch archiveThumbFetch({http.Client? client, String userAgent = 'ArchiveTV-Server/0.1 (personal retro TV tuner)'}) {
  final c = client ?? http.Client();
  return (id) async {
    final r = await c.get(Uri.https('archive.org', '/services/img/$id'),
        headers: {'User-Agent': userAgent}).timeout(const Duration(seconds: 20));
    if (r.statusCode == 200) return r.bodyBytes;
    if (r.statusCode == 404 || r.statusCode == 403) return null;
    throw HttpException('services/img $id: HTTP ${r.statusCode}');
  };
}

/// The decoded thumbnail when it is worth showing, else null: under 3,000 bytes (Archive's placeholder),
/// undecodable, or on a 64x64 downscale mean luminance < 25 (black) or stddev < 12 (flat frame).
img.Image? usableThumb(Uint8List? bytes) {
  if (bytes == null || bytes.length < 3000) return null;
  final im = img.decodeImage(bytes);
  if (im == null || im.width < 16 || im.height < 16) return null;
  final s = img.copyResize(im, width: 64, height: 64, interpolation: img.Interpolation.average);
  var sum = 0.0, sq = 0.0;
  for (final p in s) {
    final y = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
    sum += y;
    sq += y * y;
  }
  final mean = sum / 4096, sd = math.sqrt(math.max(0, sq / 4096 - mean * mean));
  return mean < 25 || sd < 12 ? null : im;
}

final _navy = img.ColorRgb8(0x10, 0x1A, 0x5C), _navyDark = img.ColorRgb8(0x0B, 0x13, 0x48);
final _edge = img.ColorRgb8(0x3A, 0x4E, 0xB0), _white = img.ColorRgb8(255, 255, 255);
final _pale = img.ColorRgb8(0xB8, 0xC6, 0xFF), _shadow = img.ColorRgb8(0, 0, 0x18);

void _rect(img.Image im, int x0, int y0, int x1, int y1, img.Color c) =>
    img.fillRect(im, x1: x0, y1: y0, x2: x1 - 1, y2: y1 - 1, color: c);

void _frame(img.Image im, int inset, int w, img.Color c) {
  for (var i = 0; i < w; i++) {
    img.drawRect(im, x1: inset + i, y1: inset + i, x2: im.width - 1 - inset - i, y2: im.height - 1 - inset - i, color: c);
  }
}

/// [s] in [f], [scale]x, centred on [cx] (or left at [x]), with a 1 px shadow.
void _text(img.Image im, String s, img.BitmapFont f, int y, img.Color c, {int? cx, int x = 0, int scale = 1}) {
  if (s.isEmpty) return;
  final w = textWidth(f, s) + 2, h = f.lineHeight + 2;
  var t = img.Image(width: w, height: h, numChannels: 4);
  img.drawString(t, s, font: f, x: 1, y: 1, color: _shadow);
  img.drawString(t, s, font: f, x: 0, y: 0, color: c);
  if (scale > 1) t = img.copyResize(t, width: w * scale, height: h * scale, interpolation: img.Interpolation.linear);
  img.compositeImage(im, t, dstX: cx == null ? x : cx - t.width ~/ 2, dstY: y);
}

/// The biggest of arial48 / arial24 / arial14 that fits [maxW] (cut with "..." in the smallest).
(img.BitmapFont, String) _fitFont(String s, int maxW) {
  for (final f in [img.arial48, img.arial24]) {
    if (textWidth(f, s) <= maxW) return (f, s);
  }
  return (img.arial14, fit(s, maxW, (t) => textWidth(img.arial14, t)));
}

/// [src] resized to fit inside maxW x maxH, aspect kept (never stretched).
img.Image _contain(img.Image src, int maxW, int maxH) {
  final k = math.min(maxW / src.width, maxH / src.height);
  return img.copyResize(src,
      width: math.max(1, (src.width * k).round()),
      height: math.max(1, (src.height * k).round()),
      interpolation: img.Interpolation.average);
}

void _stripes(img.Image im) {
  for (var y = 0; y < im.height; y += 3) {
    _rect(im, 0, y, im.width, y + 1, _navyDark);
  }
}

/// Channel card: navy, the channel's 4x3 logo, number and name. Portrait 600x900 or [wide] 960x540.
img.Image drawCard(Channel c, img.Image? logo, {bool wide = false}) {
  final im = img.Image(width: wide ? 960 : 600, height: wide ? 540 : 900);
  img.fill(im, color: _navy);
  _stripes(im);
  _frame(im, 10, 3, _edge);
  final name = sanitize(c.name).toUpperCase(), genre = sanitize(c.genre).toUpperCase();
  final (bg, fg) = genreColors(c.genre);
  if (wide) {
    if (logo != null) {
      final l = _contain(logo, 480, 360);
      img.compositeImage(im, l, dstX: 50 + (480 - l.width) ~/ 2, dstY: 90 + (360 - l.height) ~/ 2);
    }
    const cx = 750, room = 340;
    _rect(im, cx - 90, 130, cx + 90, 250, bg);
    _text(im, '${c.number}', img.arial48, 140, fg, cx: cx, scale: 2);
    final (f, n) = _fitFont(name, room);
    _text(im, n, f, 280, _white, cx: cx);
    _text(im, fit(genre, room, (t) => textWidth(img.arial24, t)), img.arial24, 350, _pale, cx: cx);
  } else {
    if (logo != null) {
      final l = _contain(logo, 520, 390);
      img.compositeImage(im, l, dstX: 40 + (520 - l.width) ~/ 2, dstY: 110 + (390 - l.height) ~/ 2);
    }
    _rect(im, 210, 560, 390, 680, bg);
    _text(im, '${c.number}', img.arial48, 570, fg, cx: 300, scale: 2);
    final (f, n) = _fitFont(name, 520);
    _text(im, n, f, 715, _white, cx: 300);
    _text(im, fit(genre, 520, (t) => textWidth(img.arial24, t)), img.arial24, 790, _pale, cx: 300);
  }
  return im;
}

/// Portrait 600x900 programme poster: [thumb] contained in the middle (never cropped or stretched) over a
/// blurred, darkened copy of itself; the channel logo as a badge in the top band (above the picture);
/// channel number and name on a genre-coloured strip at the bottom.
img.Image drawPoster(Channel c, img.Image thumb, img.Image? logo) {
  const w = 600, h = 900, top = 130, strip = 120;
  // background: the thumbnail covering the poster, blurred (down to 1/10 and back up) and darkened
  final k = math.max(w / thumb.width, h / thumb.height);
  final cw = (thumb.width * k).round(), ch = (thumb.height * k).round();
  final small = img.copyResize(thumb,
      width: math.max(1, cw ~/ 12), height: math.max(1, ch ~/ 12), interpolation: img.Interpolation.average);
  final cover = img.copyResize(small, width: cw, height: ch, interpolation: img.Interpolation.linear);
  final im = img.copyCrop(cover, x: (cw - w) ~/ 2, y: (ch - h) ~/ 2, width: w, height: h);
  for (final p in im) {
    p
      ..r = p.r * 0.35
      ..g = p.g * 0.35
      ..b = p.b * 0.35;
  }
  // main picture between the top band and the strip
  final pic = _contain(thumb, w, h - top - strip - 20);
  final py = top + (h - top - strip - pic.height) ~/ 2;
  img.compositeImage(im, pic, dstX: (w - pic.width) ~/ 2, dstY: py);
  // badge: logo on a dark plate, top-left, inside the top band
  if (logo != null) {
    final l = _contain(logo, 136, 102);
    _rect(im, 14, 12, 14 + l.width + 16, 12 + l.height + 12, _navyDark);
    img.drawRect(im, x1: 14, y1: 12, x2: 14 + l.width + 15, y2: 12 + l.height + 11, color: _edge);
    img.compositeImage(im, l, dstX: 22, dstY: 18);
  }
  // bottom strip
  final (bg, fg) = genreColors(c.genre);
  _rect(im, 0, h - strip, w, h, _navy);
  _rect(im, 0, h - strip, w, h - strip + 4, bg);
  final num = '${c.number}';
  final nw = textWidth(img.arial48, num) * 2 + 24;
  _rect(im, 0, h - strip + 4, nw + 8, h, bg);
  _text(im, num, img.arial48, h - strip + 10, fg, x: 12, scale: 2);
  final (f, n) = _fitFont(sanitize(c.name).toUpperCase(), w - nw - 40);
  _text(im, n, f, h - strip + (strip - f.lineHeight) ~/ 2, _white, x: nw + 24);
  _frame(im, 0, 2, _edge);
  return im;
}

/// Programme thumbnails and channel cards for the XMLTV guide, cached under `<data>/thumbs` and `<data>/cards`.
/// Thumbnails are fetched from the Archive at most [concurrency] at a time, once per item: a usable one is
/// composed into a poster per channel (`thumbs/<ch>/<id>.jpg`), an unusable one is remembered
/// (`thumbs/_bad/<id>`) and the channel card is served instead. Fetch errors (timeouts, 5xx) are not
/// remembered on disk, only for an hour in memory. The thumbs folder is kept under [capBytes] (oldest first).
class Thumbs {
  final Directory dir;
  final Channel? Function(int number) channel;
  final String? Function(Channel) logoFile;
  final ThumbFetch fetch;
  final int capBytes, concurrency;
  final void Function(String)? log;

  Thumbs(this.dir,
      {required this.channel,
      required this.logoFile,
      ThumbFetch? fetch,
      this.capBytes = 200 << 20,
      this.concurrency = 2,
      this.log})
      : fetch = fetch ?? archiveThumbFetch() {
    // cards are cheap to redraw: start clean so a new logo or name shows after a deploy
    final cards = Directory('${dir.path}/cards');
    if (cards.existsSync()) cards.deleteSync(recursive: true);
  }

  int fetches = 0;
  int _active = 0;
  final _waiting = <Completer<void>>[];
  final _inFlight = <String, Future<Uint8List>>{};
  final _failedAt = <String, DateTime>{};
  final _logos = <int, img.Image?>{};
  int? _size;
  int _writes = 0;

  img.Image? _logo(Channel c) => _logos.putIfAbsent(c.number, () {
        final p = logoFile(c);
        try {
          return p == null ? null : img.decodeImage(File(p).readAsBytesSync());
        } on Object {
          return null;
        }
      });

  /// The channel card as PNG ([wide] 960x540, else 600x900), or as JPEG ([jpg], portrait; served by /thumb).
  Future<Uint8List> card(Channel c, {bool wide = false, bool jpg = false}) async {
    final f = File('${dir.path}/cards/${c.number}${wide ? '-wide' : ''}.${jpg ? 'jpg' : 'png'}');
    if (f.existsSync()) return f.readAsBytesSync();
    final im = drawCard(c, _logo(c), wide: wide && !jpg);
    final bytes = jpg ? img.encodeJpg(im, quality: 88) : img.encodePng(im);
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes);
    return bytes;
  }

  /// The programme poster JPEG for [itemId] on [c] (the channel card when the item has no usable thumbnail).
  /// Also returns whether the answer is final (cacheable for long).
  Future<(Uint8List, bool)> poster(Channel c, String itemId) async {
    final out = File('${dir.path}/thumbs/${c.number}/$itemId.jpg');
    if (out.existsSync()) return (out.readAsBytesSync(), true);
    if (File('${dir.path}/thumbs/_bad/$itemId').existsSync()) return (await card(c, jpg: true), true);
    final failed = _failedAt[itemId];
    if (failed != null && DateTime.now().difference(failed) < const Duration(hours: 1)) return (await card(c, jpg: true), false);
    final key = '${c.number}/$itemId';
    try {
      return (
        await (_inFlight[key] ??= _make(c, itemId, out).whenComplete(() {
          _inFlight.remove(key); // block body: returning the removed future would make whenComplete wait on itself
        })),
        true
      );
    } on Object catch (e) {
      _failedAt[itemId] = DateTime.now();
      log?.call('thumb $itemId: $e');
      return (await card(c, jpg: true), false);
    }
  }

  Future<Uint8List> _make(Channel c, String itemId, File out) async {
    final bytes = await _limited(() => fetch(itemId));
    fetches++;
    final thumb = usableThumb(bytes);
    if (thumb == null) {
      File('${dir.path}/thumbs/_bad/$itemId')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('');
      return card(c, jpg: true);
    }
    final jpg = img.encodeJpg(drawPoster(c, thumb, _logo(c)), quality: 85);
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(jpg);
    _size = (_size ?? _measure()) + jpg.length;
    if (_size! > capBytes || ++_writes % 200 == 0) _prune();
    return jpg;
  }

  Future<T> _limited<T>(Future<T> Function() f) async {
    while (_active >= concurrency) {
      final w = Completer<void>();
      _waiting.add(w);
      await w.future;
    }
    _active++;
    try {
      return await f();
    } finally {
      _active--;
      if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
    }
  }

  List<File> _posters() {
    final d = Directory('${dir.path}/thumbs');
    if (!d.existsSync()) return [];
    return [
      for (final e in d.listSync(recursive: true))
        if (e is File && e.path.endsWith('.jpg')) e
    ];
  }

  int _measure() => _posters().fold(0, (a, f) => a + f.lengthSync());

  /// Deletes the oldest posters until the folder is under 90% of [capBytes].
  void _prune() {
    final files = [for (final f in _posters()) (f, f.statSync())]..sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    var total = files.fold(0, (a, f) => a + f.$2.size);
    var n = 0;
    for (final (f, s) in files) {
      if (total <= capBytes * 0.9) break;
      try {
        f.deleteSync();
        total -= s.size;
        n++;
      } on Object {
        // in use or gone: skip
      }
    }
    _size = total;
    if (n > 0) log?.call('thumbs: pruned $n posters (${total >> 20} MB left)');
  }

  /// Serves `/cards/<n>.png`, `/cards/<n>-wide.png` and `/thumb/<n>/<itemId>.jpg`; false = not one of these paths.
  Future<bool> serve(HttpRequest req) async {
    final res = req.response, path = req.uri.path;
    void cache(bool long) => res.headers.set('Cache-Control', long ? 'public, max-age=2592000' : 'public, max-age=3600');
    if (RegExp(r'^/cards/(\d+)(-wide)?\.png$').firstMatch(path) case final m?) {
      final c = channel(int.parse(m[1]!));
      if (c == null) {
        res.statusCode = 404;
      } else {
        final b = await card(c, wide: m[2] != null);
        res.headers.contentType = ContentType('image', 'png');
        cache(true);
        res.add(b);
      }
      return true;
    }
    if (RegExp(r'^/thumb/(\d+)/([^/]+)\.jpg$').firstMatch(path) case final m?) {
      final c = channel(int.parse(m[1]!));
      if (!thumbIdPattern.hasMatch(m[2]!)) {
        res.statusCode = 400;
      } else if (c == null) {
        res.statusCode = 404;
      } else {
        final (b, long) = await poster(c, m[2]!);
        res.headers.contentType = ContentType('image', 'jpeg');
        cache(long);
        res.add(b);
      }
      return true;
    }
    if (path.startsWith('/thumb/') || path.startsWith('/cards/')) {
      res.statusCode = 400;
      return true;
    }
    return false;
  }
}
