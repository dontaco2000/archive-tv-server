import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'layout.dart';
import 'snapshot.dart';
import 'header_logo.dart';
import 'weather.dart';

part 'weather_renderer.dart';

final _navy = img.ColorRgb8(0x10, 0x1A, 0x5C);
final _navyDark = img.ColorRgb8(0x0B, 0x13, 0x48);
final _line = img.ColorRgb8(0x05, 0x09, 0x2A);
final _cell = img.ColorRgb8(0x1E, 0x2C, 0x8A);
final _now = img.ColorRgb8(0x2E, 0x45, 0xC8);
final _bar = img.ColorRgb8(0x08, 0x0F, 0x3E);
final _yellow = img.ColorRgb8(0xFF, 0xEB, 0x3B);
final _white = img.ColorRgb8(0xFF, 0xFF, 0xFF);
final _pale = img.ColorRgb8(0xB8, 0xC6, 0xFF);
final _shadow = img.ColorRgb8(0x00, 0x00, 0x18);

final _small = img.arial14, _big = img.arial24;

/// (background, text) for a channel's name cell, by genre (same palette as the Archive TV app guide).
(img.Color, img.Color) genreColors(String genre) => switch (genre) {
      'Kids & Animation' => (img.ColorRgb8(0xD3, 0x2F, 0x2F), _yellow),
      'Movies' => (img.ColorRgb8(0x5E, 0x1A, 0x7A), img.ColorRgb8(0xFF, 0x4F, 0xD8)),
      'Comedy & Variety' => (img.ColorRgb8(0x00, 0x79, 0x6B), img.ColorRgb8(0xFF, 0x98, 0x00)),
      'Drama & Classic TV' => (img.ColorRgb8(0x4E, 0x34, 0x2E), img.ColorRgb8(0xFF, 0xD1, 0x80)),
      'TV' => (img.ColorRgb8(0x00, 0x79, 0x6B), img.ColorRgb8(0xFF, 0x98, 0x00)),
      'News & Docs' => (img.ColorRgb8(0x0D, 0x1B, 0x4A), img.ColorRgb8(0xFF, 0xC9, 0x4D)),
      'Music' => (img.ColorRgb8(0xE9, 0x1E, 0x8C), img.ColorRgb8(0x00, 0xE5, 0xFF)),
      'Sports' => (img.ColorRgb8(0x2E, 0x7D, 0x32), img.ColorRgb8(0xFF, 0xEB, 0x3B)),
      'World & Lifestyle' => (img.ColorRgb8(0xC6, 0x28, 0x28), _white),
      'International' => (img.ColorRgb8(0xC6, 0x28, 0x28), _white),
      _ => (img.ColorRgb8(0x37, 0x47, 0x4F), _white),
    };

int textWidth(img.BitmapFont f, String s) {
  var w = 0;
  for (final c in s.codeUnits) {
    w += f.characters[c]?.xAdvance ?? 0;
  }
  return w;
}

const _days = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
const _months = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];

/// Something that draws 640x480 yuv420p frames for [GuideChannel]: the guide listings or the weather.
abstract interface class FrameSource {
  Uint8List frameYuv(DateTime now, double seconds);
}

/// Draws guide frames (640x480 RGB24). The scrolling grid is pre-rendered as one tall strip and
/// only redrawn when the minute or the snapshot changes; the top band is redrawn once a second;
/// each frame is just two memcpy's.
class GuideRenderer implements FrameSource {
  Snapshot _snap;
  final img.Image _logoMark = img.decodePng(base64Decode(headerLogoPngBase64))!;
  final Map<String, img.Image?> _logos = {};

  /// Seconds each page holds still, and seconds the slide to the next page takes.
  final double hold, scroll;

  /// Seconds each channel stays in the info strip.
  final double infoSeconds;

  GuideRenderer(this._snap, {this.hold = 7, this.scroll = 1, this.infoSeconds = 5});

  img.Image? _strip;
  String? _stripKey;
  final img.Image _head = img.Image(width: frameWidth, height: gridTop);
  String? _headKey;
  final Uint8List _frame = Uint8List(frameWidth * frameHeight * 3);
  final Uint8List _frameY = Uint8List(frameWidth * frameHeight * 3 ~/ 2);
  Uint8List? _headYuv, _stripYuv;
  String? _frameKey;

  Snapshot get snapshot => _snap;

  /// Takes effect at the next frame; the stream keeps running.
  set snapshot(Snapshot s) {
    _snap = s;
    _stripKey = _headKey = _frameKey = null;
    _headYuv = _stripYuv = null;
  }

  /// Redraws whatever changed for [now]/[seconds]; returns the scroll offset (even in [yuv] mode).
  int _update(DateTime now, double seconds, {bool even = false}) {
    final n = _snap.channels.length;
    final ws = windowStart(now);
    final sKey = now.toLocal().toString().substring(0, 16); // the grid changes at most once a minute
    if (_stripKey != sKey) {
      _strip = _drawStrip(now, ws);
      _stripKey = sKey;
      _stripYuv = null;
    }
    final info = n == 0 ? 0 : (seconds / infoSeconds).floor() % n;
    final hKey = '${now.toLocal().toString().substring(0, 19)}|$info'; // clock ticks once a second
    if (_headKey != hKey) {
      _drawHead(now, ws, info);
      _headKey = hKey;
      _headYuv = null;
    }
    final off = scrollOffset(seconds, n, hold: hold, scroll: scroll);
    return even ? off & ~1 : off;
  }

  /// The frame for wall-clock [now], [seconds] into playback (drives paging and the info strip),
  /// as RGB24. The returned buffer is reused by the next call.
  Uint8List frame(DateTime now, double seconds) {
    final off = _update(now, seconds);
    final fKey = '$_headKey|$_stripKey|$off|rgb';
    if (_frameKey == fKey) return _frame;
    _frameKey = fKey;
    final head = _head.buffer.asUint8List();
    _frame.setRange(0, head.length, head);
    _ring(
        _frame, head.length, _strip!.buffer.asUint8List(), frameWidth * 3, _strip!.height, off, frameHeight - gridTop);
    return _frame;
  }

  /// Same frame as planar yuv420p (BT.601 limited range), what ffmpeg is fed: no colour conversion
  /// in ffmpeg and half the pipe bytes of RGB24. The scroll offset is rounded to even lines.
  Uint8List frameYuv(DateTime now, double seconds) {
    final off = _update(now, seconds, even: true);
    final fKey = '$_headKey|$_stripKey|$off|yuv';
    if (_frameKey == fKey) return _frameY;
    _frameKey = fKey;
    final h = _headYuv ??= _toYuv(_head);
    final st = _stripYuv ??= _toYuv(_strip!);
    const w = frameWidth, cw = frameWidth ~/ 2;
    final ringH = _strip!.height, gridH = frameHeight - gridTop;
    // Y plane
    _frameY.setRange(0, w * gridTop, h, 0);
    _ring(_frameY, w * gridTop, st, w, ringH, off, gridH);
    // U and V planes
    final yN = w * frameHeight, cN = cw * frameHeight ~/ 2;
    final hY = w * gridTop, hC = cw * gridTop ~/ 2;
    final sY = w * ringH, sC = cw * ringH ~/ 2;
    for (var k = 0; k < 2; k++) {
      final dst = yN + k * cN;
      _frameY.setRange(dst, dst + hC, h, hY + k * hC);
      _ring(_frameY, dst + hC, Uint8List.sublistView(st, sY + k * sC, sY + (k + 1) * sC), cw, ringH ~/ 2, off ~/ 2,
          gridH ~/ 2);
    }
    return _frameY;
  }

  /// [frame] as an image (for PNG screenshots).
  img.Image frameImage(DateTime now, double seconds) => img.Image.fromBytes(
      width: frameWidth, height: frameHeight, bytes: Uint8List.fromList(frame(now, seconds)).buffer, numChannels: 3);

  void _drawHead(DateTime now, DateTime ws, int info) {
    final h = _head;
    _topBand(h, _logoMark, 'GUIDE', now);
    final l = now.toLocal();

    // info strip: one channel at a time, now and next
    const x0 = 228, y0 = 8, x1 = 632, y1 = 118;
    _rect(h, x0 - 2, y0 - 2, x1 + 2, y1 + 2, _yellow);
    _rect(h, x0, y0, x1, y1, _cell);
    if (_snap.channels.isNotEmpty) {
      final c = _snap.channels[info];
      final (bg, fg) = genreColors(c.genre);
      var tx = x0 + 10;
      final logo = _loadLogo(_logos, c.logo);
      if (logo != null) {
        _rect(h, x0 + 6, y0 + 6, x0 + 106, y0 + 82, _navyDark);
        img.compositeImage(h, logo, dstX: x0 + 6 + (100 - logo.width) ~/ 2, dstY: y0 + 8 + (72 - logo.height) ~/ 2);
        tx = x0 + 114;
      }
      final w = x1 - 8 - tx;
      final head = '${c.number}  ${sanitize(c.name).toUpperCase()}';
      _rect(h, tx - 4, y0 + 6, tx + textWidth(_big, head) + 6, y0 + 34, bg);
      _text(h, head, _big, tx, y0 + 8, fg);
      final genre = sanitize(c.genre).toUpperCase();
      _text(h, fit(genre, x1 - 8 - (tx + textWidth(_big, head) + 14), (s) => textWidth(_small, s)), _small,
          tx + textWidth(_big, head) + 14, y0 + 14, _pale);
      final cur = c.at(now);
      final next = c.after(cur?.end ?? now);
      _text(h, 'NOW', _small, tx, y0 + 46, _yellow);
      _text(h, fit(sanitize(cur?.title ?? 'Listings not available'), w - 44, (s) => textWidth(_big, s)), _big, tx + 44,
          y0 + 40, _white);
      if (next != null) {
        final label = 'NEXT ${clock12(next.start)}';
        _text(h, label, _small, tx, y0 + 80, _yellow);
        final lw = textWidth(_small, label) + 8;
        _text(h, fit(sanitize(next.title), w - lw, (s) => textWidth(_small, s)), _small, tx + lw, y0 + 80, _white);
      }
    }

    // time bar
    _rect(h, 0, topHeight, frameWidth, gridTop, _bar);
    _rect(h, 0, topHeight, frameWidth, topHeight + 2, _yellow);
    _text(h, '${_days[l.weekday - 1]} ${_months[l.month - 1]} ${l.day}', _small, 10, topHeight + 9, _yellow);
    for (var i = 0; i < columns; i++) {
      final t = ws.add(Duration(minutes: i * columnMinutes));
      final x = channelWidth + i * columnWidth;
      _rect(h, x, topHeight + 2, x + 2, gridTop, _line);
      final s = clock12(t);
      _text(h, s, _big, x + 8, topHeight + 4, _yellow);
      _text(h, ampm(t), _small, x + 12 + textWidth(_big, s), topHeight + 10, _yellow);
    }
  }

  img.Image _drawStrip(DateTime now, DateTime ws) {
    final chans = _snap.channels;
    final rows = ringRows(chans.length);
    final s = img.Image(width: frameWidth, height: rows * rowHeight);
    _rect(s, 0, 0, frameWidth, s.height, _line);
    for (final (i, c) in chans.indexed) {
      final y = i * rowHeight;
      // channel cell
      final (bg, fg) = genreColors(c.genre);
      _rect(s, 2, y + 2, channelWidth - 2, y + rowHeight, bg);
      _text(s, '${c.number}', _big, 10, y + 4, fg);
      final name = sanitize(c.name);
      if (textWidth(_big, name) <= channelWidth - 16) {
        _text(s, name, _big, 10, y + 26, _white);
      } else {
        _text(s, fit(name.toUpperCase(), channelWidth - 16, (t) => textWidth(_small, t)), _small, 10, y + 32, _white);
      }
      // programme cells
      var any = false;
      for (final p in c.programmes) {
        final on = p.airsAt(now);
        // the airing programme fills any gap back to the window start (snapshots may start at "now")
        final sp = span(on && !any && p.start.isAfter(ws) ? ws : p.start, p.end, ws);
        if (sp == null) continue;
        any = true;
        final x0 = sp.x0, x1 = sp.x1 - 2;
        if (x1 - x0 < 6) continue;
        _rect(s, x0, y + 2, x1, y + rowHeight, on ? _now : _cell);
        var tx = x0 + 6;
        if (sp.cutLeft) {
          _arrow(s, x0 + 4, y + 8, true, _yellow);
          tx += 10;
        }
        final right = sp.cutRight ? 14 : 4;
        // big font when at least 6 characters fit, else small; nothing at all rather than a lone "X..."
        final title = sanitize(p.title), room = x1 - right - tx;
        final big = fit(title, room, (t) => textWidth(_big, t));
        final small = fit(title, room, (t) => textWidth(_small, t));
        final useBig = big == title || big.length >= 9;
        final shown = useBig ? big : small;
        if (shown == title || shown.length >= 6) {
          _text(s, shown, useBig ? _big : _small, tx, useBig ? y + 6 : y + 12, on ? _yellow : _white);
        }
        if (sp.cutRight) _arrow(s, x1 - 11, y + 8, false, _yellow);
        final sub = on ? 'ON NOW' : '${clock12(p.start)} ${ampm(p.start)}';
        if (textWidth(_small, sub) <= x1 - right - tx) _text(s, sub, _small, tx, y + 34, on ? _yellow : _pale);
      }
      if (!any) {
        _rect(s, channelWidth, y + 2, frameWidth, y + rowHeight, _cell);
        _text(s, 'Listings not available', _big, channelWidth + 8, y + 14, _pale);
      }
    }
    // filler rows: end-of-listings banner
    final fy = chans.length * rowHeight, fh = rows * rowHeight - fy;
    _rect(s, 2, fy + 2, frameWidth - 2, fy + fh, _navy);
    _stripes(s, 2, fy + 2, frameWidth - 2, fy + fh);
    _rect(s, 2, fy + 2, frameWidth - 2, fy + 4, _yellow);
    final lines = [
      ('${chans.length} CHANNELS OF CLASSIC TV', _big, _yellow),
      ('All programs come from the Internet Archive', _small, _white),
      ('(archive.org) and its uploaders. Archive TV is not', _small, _white),
      ('affiliated with or endorsed by the Internet Archive.', _small, _pale),
    ];
    final logoFits = fh >= _logoMark.height + 12;
    final tx = logoFits ? 240 : 16;
    if (logoFits) img.compositeImage(s, _logoMark, dstX: 18, dstY: fy + (fh - _logoMark.height) ~/ 2 + 1);
    final textH = lines.fold(0, (a, l) => a + l.$2.lineHeight + 2);
    var ty = fy + 4 + ((fh - 4 - textH) ~/ 2).clamp(2, 1000);
    for (final (t, f, c) in lines) {
      if (ty + f.lineHeight > fy + fh) break;
      _text(s, t, f, tx, ty, c);
      ty += f.lineHeight + 2;
    }
    return s;
  }
}

/// The top band's left part: navy stripes, the Archive TV wordmark, [label] and the ticking clock under it.
void _topBand(img.Image h, img.Image logoMark, String label, DateTime now) {
  _rect(h, 0, 0, frameWidth, topHeight, _navy);
  _stripes(h, 0, 0, frameWidth, topHeight);
  img.compositeImage(h, logoMark, dstX: 8, dstY: 4);
  final l = now.toLocal();
  final t = '${clock12(l)}:${l.second.toString().padLeft(2, '0')}';
  final cx = 216 - textWidth(_big, t) - textWidth(_small, ampm(l)) - 4;
  // a label too long for the big font beside the clock (WEATHER) uses the small one
  final big = 14 + textWidth(_big, label) + 6 <= 216 - textWidth(_big, '12:00:00') - textWidth(_small, 'PM') - 4;
  _text(h, label, big ? _big : _small, 14, big ? 90 : 98, _yellow);
  _text(h, t, _big, cx, 90, _white);
  _text(h, ampm(l), _small, 216 - textWidth(_small, ampm(l)), 98, _yellow);
}

/// Copies [lines] lines of [lineBytes] from the looping [src] (ring of [ringLines]) starting at line [y].
void _ring(Uint8List dst, int at, Uint8List src, int lineBytes, int ringLines, int y, int lines) {
  while (lines > 0) {
    final take = lines < ringLines - y ? lines : ringLines - y;
    dst.setRange(at, at + take * lineBytes, src, y * lineBytes);
    at += take * lineBytes;
    lines -= take;
    y = 0;
  }
}

/// RGB image (even width/height) -> I420 planes Y, U, V back to back.
Uint8List _toYuv(img.Image im) {
  final w = im.width, h = im.height, rgb = im.buffer.asUint8List();
  final out = Uint8List(w * h * 3 ~/ 2);
  final uAt = w * h, vAt = uAt + w * h ~/ 4, cw = w ~/ 2;
  for (var i = 0, p = 0; i < w * h; i++, p += 3) {
    out[i] = ((66 * rgb[p] + 129 * rgb[p + 1] + 25 * rgb[p + 2] + 128) >> 8) + 16;
  }
  for (var y = 0; y < h; y += 2) {
    for (var x = 0; x < w; x += 2) {
      var r = 0, g = 0, b = 0;
      for (final p in [(y * w + x) * 3, (y * w + x + 1) * 3, ((y + 1) * w + x) * 3, ((y + 1) * w + x + 1) * 3]) {
        r += rgb[p];
        g += rgb[p + 1];
        b += rgb[p + 2];
      }
      final c = (y ~/ 2) * cw + x ~/ 2;
      out[uAt + c] = (((-38 * r - 74 * g + 112 * b) >> 2) + 128 >> 8) + 128;
      out[vAt + c] = (((112 * r - 94 * g - 18 * b) >> 2) + 128 >> 8) + 128;
    }
  }
  return out;
}

void _text(img.Image im, String s, img.BitmapFont f, int x, int y, img.Color c, {bool shadow = true}) {
  if (shadow) img.drawString(im, s, font: f, x: x + 1, y: y + 1, color: _shadow);
  img.drawString(im, s, font: f, x: x, y: y, color: c);
}

void _rect(img.Image im, int x0, int y0, int x1, int y1, img.Color c) =>
    img.fillRect(im, x1: x0, y1: y0, x2: x1 - 1, y2: y1 - 1, color: c);

void _stripes(img.Image im, int x0, int y0, int x1, int y1) {
  for (var y = y0; y < y1; y += 2) {
    _rect(im, x0, y, x1, y + 1, _navyDark);
  }
}

// Left-pointing / right-pointing arrow: the programme continues outside the window.
void _arrow(img.Image im, int x, int y, bool left, img.Color c) {
  for (var i = 0; i < 7; i++) {
    final xx = left ? x + i : x + 6 - i;
    _rect(im, xx, y + 7 - i, xx + 1, y + 8 + i, c);
  }
}

img.Image? _loadLogo(Map<String, img.Image?> cache, String? path) {
  if (path == null) return null;
  return cache.putIfAbsent(path, () {
    try {
      final f = File(path);
      if (!f.existsSync()) return null;
      final src = img.decodeImage(f.readAsBytesSync());
      if (src == null) return null;
      const maxW = 96, maxH = 72;
      final k = (maxW / src.width) < (maxH / src.height) ? maxW / src.width : maxH / src.height;
      return img.copyResize(src,
          width: (src.width * k).round(), height: (src.height * k).round(), interpolation: img.Interpolation.average);
    } on Object {
      return null; // a broken logo never stops the channel
    }
  });
}
