part of 'renderer.dart';

/// The weather channel's screens, in order. [alerts] only when there are active alerts; [none] alone
/// when there is no data at all yet.
enum WeatherPage { alerts, current, hourly, today, extended, none }

/// The pages shown for [w].
List<WeatherPage> weatherPages(Weather? w) => w == null
    ? const [WeatherPage.none]
    : [if (w.alerts.isNotEmpty) WeatherPage.alerts, WeatherPage.current, WeatherPage.hourly, WeatherPage.today, WeatherPage.extended];

/// Which page shows after [seconds] of playback, the next one, and how far (0-1, eased) the slide to it is:
/// each page holds [hold] s, then slides left over [slide] s; loops forever.
({int page, int next, double f}) weatherPhase(double seconds, int pages, {double hold = 9, double slide = 1}) {
  final cycle = hold + slide;
  final n = (seconds / cycle).floor();
  final phase = seconds - n * cycle;
  var f = phase <= hold ? 0.0 : ((phase - hold) / slide).clamp(0.0, 1.0);
  f = f * f * (3 - 2 * f);
  return (page: n % pages, next: (n + 1) % pages, f: f);
}

/// Greedy word wrap of [s] into at most [maxLines] lines of [maxWidth]; the last line gets "..." if cut.
List<String> wrapText(String s, int maxWidth, int Function(String) width, {int maxLines = 2}) {
  final lines = <String>[];
  var cur = '';
  final words = s.split(' ').where((w) => w.isNotEmpty).toList();
  for (var i = 0; i < words.length; i++) {
    final t = cur.isEmpty ? words[i] : '$cur ${words[i]}';
    if (width(t) <= maxWidth || cur.isEmpty) {
      cur = t;
      continue;
    }
    lines.add(cur);
    cur = words[i];
    if (lines.length == maxLines) {
      lines[maxLines - 1] = fit('${lines.last} ${words.sublist(i).join(' ')}', maxWidth, width);
      return lines;
    }
  }
  if (cur.isNotEmpty) lines.add(cur);
  return [for (final l in lines) fit(l, maxWidth, width)];
}

const _weatherTabs = {
  WeatherPage.alerts: 'ALERTS',
  WeatherPage.current: 'NOW',
  WeatherPage.hourly: 'HOURLY',
  WeatherPage.today: 'TODAY',
  WeatherPage.extended: 'EXTENDED',
  WeatherPage.none: 'WEATHER',
};

const _weatherTitles = {
  WeatherPage.alerts: 'WEATHER ALERTS',
  WeatherPage.current: 'CURRENT CONDITIONS',
  WeatherPage.hourly: 'HOURLY FORECAST',
  WeatherPage.today: "TODAY'S FORECAST",
  WeatherPage.extended: 'EXTENDED FORECAST',
  WeatherPage.none: 'LOCAL WEATHER',
};

final _red = img.ColorRgb8(0xB7, 0x1C, 0x1C);
final _orange = img.ColorRgb8(0xFF, 0x98, 0x00);
final _blue = img.ColorRgb8(0x4F, 0xC3, 0xF7);
final _cloud = img.ColorRgb8(0xEC, 0xEF, 0xF1);
final _darkCloud = img.ColorRgb8(0x90, 0xA4, 0xAE);
const _bodyH = frameHeight - gridTop; // 324

/// Draws the weather channel (640x480): the guide's top band (wordmark, WEATHER, clock), a box with the
/// place, the page title and the "updated" time, a tab bar, and pages that hold [hold] s and slide.
/// [data] is read every frame (e.g. a [WeatherFeed]'s current report): new data shows at once.
class WeatherRenderer implements FrameSource {
  final Weather? Function() data;
  final String? logoPath;
  final double hold, slide;

  /// The place shown before any data arrived.
  final String place;

  WeatherRenderer(this.data, {this.logoPath, this.place = '', this.hold = 9, this.slide = 1});

  final img.Image _logoMark = img.decodePng(base64Decode(headerLogoPngBase64))!;
  final Map<String, img.Image?> _logos = {};
  final img.Image _head = img.Image(width: frameWidth, height: gridTop);
  String? _headKey;
  Uint8List? _headYuv;
  final Map<WeatherPage, ({img.Image rgb, Uint8List yuv})> _pages = {};
  String? _pagesKey;
  final Uint8List _frameY = Uint8List(frameWidth * frameHeight * 3 ~/ 2);
  String? _frameKey;

  ({List<WeatherPage> pages, int page, int next, double f, Weather? w}) _update(DateTime now, double seconds) {
    final w = data();
    final pages = weatherPages(w);
    final ph = weatherPhase(seconds, pages.length, hold: hold, slide: slide);
    final l = now.toLocal();
    final pKey = '${identityHashCode(w)}|${l.year}-${l.month}-${l.day}-${l.hour}';
    if (_pagesKey != pKey) {
      _pages.clear();
      _pagesKey = pKey;
    }
    final hKey = '${l.toString().substring(0, 19)}|$pKey|${ph.page}';
    if (_headKey != hKey) {
      _drawHead(now, w, pages, pages[ph.page]);
      _headKey = hKey;
      _headYuv = null;
    }
    return (pages: pages, page: ph.page, next: ph.next, f: ph.f, w: w);
  }

  ({img.Image rgb, Uint8List yuv}) _page(WeatherPage p, Weather? w, DateTime now) => _pages.putIfAbsent(p, () {
        final im = _drawPage(p, w, now);
        return (rgb: im, yuv: _toYuv(im));
      });

  @override
  Uint8List frameYuv(DateTime now, double seconds) {
    final u = _update(now, seconds);
    final dx = (u.f * frameWidth).round() & ~1;
    final fKey = '$_headKey|$_pagesKey|${u.page}|$dx';
    if (_frameKey == fKey) return _frameY;
    _frameKey = fKey;
    final h = _headYuv ??= _toYuv(_head);
    final a = _page(u.pages[u.page], u.w, now).yuv;
    final b = dx == 0 ? a : _page(u.pages[u.next], u.w, now).yuv;
    const w = frameWidth, cw = frameWidth ~/ 2, yN = w * frameHeight, cN = cw * frameHeight ~/ 2;
    // per plane: head rows, then body rows = page A shifted left by dx, page B coming in from the right
    void plane(int dst, int src, int srcBody, int width, int headRows, int bodyRows, int shift) {
      _frameY.setRange(dst, dst + width * headRows, h, src);
      for (var r = 0; r < bodyRows; r++) {
        final o = dst + width * (headRows + r), s = srcBody + r * width;
        _frameY.setRange(o, o + width - shift, a, s + shift);
        if (shift > 0) _frameY.setRange(o + width - shift, o + width, b, s);
      }
    }

    plane(0, 0, 0, w, gridTop, _bodyH, dx);
    final hY = w * gridTop, hC = cw * gridTop ~/ 2, bY = w * _bodyH, bC = cw * _bodyH ~/ 2;
    for (var k = 0; k < 2; k++) {
      plane(yN + k * cN, hY + k * hC, bY + k * bC, cw, gridTop ~/ 2, _bodyH ~/ 2, dx ~/ 2);
    }
    return _frameY;
  }

  /// The frame as an RGB image (PNG screenshots).
  img.Image frameImage(DateTime now, double seconds) {
    final u = _update(now, seconds);
    final dx = (u.f * frameWidth).round() & ~1;
    final out = img.Image(width: frameWidth, height: frameHeight);
    img.compositeImage(out, _head);
    img.compositeImage(out, _page(u.pages[u.page], u.w, now).rgb, dstX: -dx, dstY: gridTop);
    if (dx > 0) img.compositeImage(out, _page(u.pages[u.next], u.w, now).rgb, dstX: frameWidth - dx, dstY: gridTop);
    return out;
  }

  void _drawHead(DateTime now, Weather? w, List<WeatherPage> pages, WeatherPage page) {
    final h = _head;
    _topBand(h, _logoMark, 'WEATHER', now);
    const x0 = 228, y0 = 8, x1 = 632, y1 = 118;
    _rect(h, x0 - 2, y0 - 2, x1 + 2, y1 + 2, _yellow);
    _rect(h, x0, y0, x1, y1, _cell);
    var tx = x0 + 10;
    final logo = _loadLogo(_logos, logoPath);
    if (logo != null) {
      _rect(h, x0 + 6, y0 + 6, x0 + 106, y0 + 82, _navyDark);
      img.compositeImage(h, logo, dstX: x0 + 6 + (100 - logo.width) ~/ 2, dstY: y0 + 8 + (72 - logo.height) ~/ 2);
      tx = x0 + 114;
    }
    final room = x1 - 8 - tx;
    _text(h, fit(sanitize(w?.place ?? place).toUpperCase(), room, (s) => textWidth(_big, s)), _big, tx, y0 + 6, _white);
    _text(h, fit(_weatherTitles[page]!, room, (s) => textWidth(_big, s)), _big, tx, y0 + 38, _yellow);
    if (w != null) {
      final age = now.difference(w.fetched);
      final old = age > const Duration(hours: 1);
      final f = w.fetched.toLocal();
      final when = '${old && age > const Duration(hours: 20) ? '${_months[f.month - 1]} ${f.day} ' : ''}${clock12(f)} ${ampm(f)}';
      _text(h, fit(old ? 'LAST UPDATED $when' : 'UPDATED $when', room, (s) => textWidth(_small, s)), _small, tx, y0 + 80,
          old ? _orange : _pale);
    }

    // tab bar: the date, then one tab per page (the shown one highlighted)
    final l = now.toLocal();
    _rect(h, 0, topHeight, frameWidth, gridTop, _bar);
    _rect(h, 0, topHeight, frameWidth, topHeight + 2, _yellow);
    _text(h, '${_days[l.weekday - 1]} ${_months[l.month - 1]} ${l.day}', _small, 10, topHeight + 9, _yellow);
    var x = frameWidth - 8;
    for (final p in pages.reversed) {
      final t = _weatherTabs[p]!, tw = textWidth(_small, t);
      x -= tw + 16;
      if (x < 120) break;
      if (p == page) _rect(h, x, topHeight + 5, x + tw + 12, gridTop - 3, p == WeatherPage.alerts ? _red : _now);
      _text(h, t, _small, x + 6, topHeight + 9, p == page ? _yellow : _pale);
    }
  }

  img.Image _drawPage(WeatherPage p, Weather? w, DateTime now) {
    final im = img.Image(width: frameWidth, height: _bodyH);
    _rect(im, 0, 0, frameWidth, _bodyH, _line);
    switch (p) {
      case WeatherPage.none:
        _panel(im, 10, 10, 630, 314);
        _center(im, 'WEATHER DATA NOT AVAILABLE', _big, 320, 120, _yellow);
        _center(im, 'Checking again in a few minutes.', _small, 320, 160, _white);
      case WeatherPage.alerts:
        _alerts(im, w!);
      case WeatherPage.current:
        _current(im, w!);
      case WeatherPage.hourly:
        _hourly(im, w!, now);
      case WeatherPage.today:
        _today(im, w!, now);
      case WeatherPage.extended:
        _extended(im, w!, now);
    }
    return im;
  }

  void _panel(img.Image im, int x0, int y0, int x1, int y1) => _rect(im, x0, y0, x1, y1, _cell);

  void _center(img.Image im, String s, img.BitmapFont f, int cx, int y, img.Color c) =>
      _text(im, s, f, cx - textWidth(f, s) ~/ 2, y, c);

  /// "72" with a degree mark; returns the width drawn.
  int _temp(img.Image im, double v, img.BitmapFont f, int x, int y, img.Color c) {
    final s = '${v.round()}';
    _text(im, s, f, x, y, c);
    final w = textWidth(f, s), r = f == _small ? 2 : (f == img.arial48 ? 5 : 3);
    for (final rr in [r, r - 1]) {
      img.drawCircle(im, x: x + w + r + 2, y: y + r + 4, radius: rr, color: c);
    }
    return w + 2 * r + 4;
  }

  int _tempWidth(double v, img.BitmapFont f) => textWidth(f, '${v.round()}') + 2 * (f == _small ? 2 : (f == img.arial48 ? 5 : 3)) + 4;

  /// Label left, value right, in a panel row.
  void _row(img.Image im, int x0, int x1, int y, String label, String value) {
    _text(im, label, _small, x0 + 12, y + 8, _pale);
    final v = fit(value, x1 - x0 - 24 - textWidth(_small, label) - 12, (s) => textWidth(_big, s));
    _text(im, v, _big, x1 - 12 - textWidth(_big, v), y + 2, _white);
  }

  String _condition(int code, bool day) => !day && code <= 1 ? (code == 0 ? 'Clear' : 'Mostly Clear') : wmoText(code);

  void _current(img.Image im, Weather w) {
    _panel(im, 10, 10, 300, 314);
    _icon(im, w.code, 155, 86, 64, day: w.isDay);
    final tw = _tempWidth(w.temp, img.arial48);
    _temp(im, w.temp, img.arial48, 155 - tw ~/ 2, 150, _white);
    _center(im, fit(_condition(w.code, w.isDay), 270, (s) => textWidth(_big, s)), _big, 155, 214, _yellow);
    final feels = 'FEELS LIKE ';
    final fw = textWidth(_small, feels) + _tempWidth(w.feels, _small);
    _text(im, feels, _small, 155 - fw ~/ 2, 256, _pale);
    _temp(im, w.feels, _small, 155 - fw ~/ 2 + textWidth(_small, feels), 256, _pale);
    _panel(im, 310, 10, 630, 314);
    final u = w.imperial;
    final rows = [
      ('HUMIDITY', '${w.humidity}%'),
      ('DEW POINT', '${w.dew.round()}'),
      ('WIND', w.windSpeed.round() == 0 ? 'Calm' : '${w.wind} ${w.speedUnit}'),
      if (w.gusts != null && w.gusts!.round() > w.windSpeed.round() + 4) ('GUSTS', '${w.gusts!.round()} ${w.speedUnit}'),
      ('PRESSURE', u ? '${w.pressure.toStringAsFixed(2)} in' : '${w.pressure.round()} hPa'),
      ('VISIBILITY', '${w.visibility < 10 ? w.visibility.toStringAsFixed(1) : w.visibility.round()} ${u ? 'mi' : 'km'}'),
    ];
    for (final (i, (label, value)) in rows.indexed) {
      final y = 18 + i * 48;
      if (label == 'DEW POINT') {
        _text(im, label, _small, 322, y + 8, _pale);
        _temp(im, w.dew, _big, 618 - _tempWidth(w.dew, _big), y + 2, _white);
      } else {
        _row(im, 310, 630, y, label, value);
      }
      if (i < rows.length - 1) _rect(im, 322, y + 40, 618, y + 41, _line);
    }
  }

  void _hourly(img.Image im, Weather w, DateTime now) {
    final from = DateTime(now.year, now.month, now.day, now.hour);
    final hours = w.hours.where((h) => !h.time.isBefore(from)).take(8).toList();
    _panel(im, 10, 6, 630, 30);
    _text(im, 'TIME', _small, 22, 11, _yellow);
    _text(im, 'TEMP', _small, 150, 11, _yellow);
    _text(im, 'CONDITIONS', _small, 236, 11, _yellow);
    _text(im, 'RAIN', _small, 552, 11, _yellow);
    if (hours.isEmpty) {
      _panel(im, 10, 34, 630, 314);
      _center(im, 'Hourly forecast not available', _big, 320, 150, _pale);
      return;
    }
    for (final (i, hf) in hours.indexed) {
      final y = 34 + i * 35;
      _panel(im, 10, y, 630, y + 33);
      final t = hf.time.toLocal();
      _text(im, '${t.hour % 12 == 0 ? 12 : t.hour % 12} ${ampm(t)}', _big, 22, y + 4, i == 0 ? _yellow : _white);
      _temp(im, hf.temp, _big, 150, y + 4, _white);
      _icon(im, hf.code, 214, y + 16, 22, day: t.hour >= 6 && t.hour < 19);
      _text(im, fit(_condition(hf.code, t.hour >= 6 && t.hour < 19), 300, (s) => textWidth(_big, s)), _big, 236, y + 4, _white);
      if (hf.rainChance != null) _text(im, '${hf.rainChance}%', _big, 552, y + 4, hf.rainChance! >= 50 ? _blue : _pale);
    }
  }

  DayForecast? _dayOf(Weather w, DateTime now) {
    final l = now.toLocal();
    for (final d in w.days) {
      final t = d.date.toLocal();
      if (t.year == l.year && t.month == l.month && t.day == l.day) return d;
    }
    return w.days.firstOrNull;
  }

  void _today(img.Image im, Weather w, DateTime now) {
    final d = _dayOf(w, now);
    if (d == null) {
      _panel(im, 10, 10, 630, 314);
      _center(im, "Today's forecast not available", _big, 320, 150, _pale);
      return;
    }
    _panel(im, 10, 10, 300, 314);
    _icon(im, d.code, 155, 86, 64);
    _center(im, fit(wmoText(d.code), 270, (s) => textWidth(_big, s)), _big, 155, 150, _yellow);
    final hiW = textWidth(_small, 'HIGH ') + _tempWidth(d.hi, img.arial48);
    _text(im, 'HIGH', _small, 155 - hiW ~/ 2, 214, _pale);
    _temp(im, d.hi, img.arial48, 155 - hiW ~/ 2 + textWidth(_small, 'HIGH '), 192, _white);
    final loW = textWidth(_small, 'LOW ') + _tempWidth(d.lo, _big);
    _text(im, 'LOW', _small, 155 - loW ~/ 2, 262, _pale);
    _temp(im, d.lo, _big, 155 - loW ~/ 2 + textWidth(_small, 'LOW '), 256, _pale);
    _panel(im, 310, 10, 630, 314);
    String t(DateTime? x) => x == null ? '--' : '${clock12(x)} ${ampm(x)}';
    final rows = [
      ('CHANCE OF RAIN', d.rainChance == null ? '--' : '${d.rainChance}%'),
      ('SUNRISE', t(d.sunrise)),
      ('SUNSET', t(d.sunset)),
      ('UV INDEX', d.uvMax == null ? '--' : '${d.uvMax!.round()}'),
      ('WIND UP TO', d.windMax == null ? '--' : '${d.windMax!.round()} ${w.speedUnit}'),
    ];
    for (final (i, (label, value)) in rows.indexed) {
      final y = 22 + i * 56;
      _row(im, 310, 630, y, label, value);
      if (i < rows.length - 1) _rect(im, 322, y + 44, 618, y + 45, _line);
    }
  }

  void _extended(img.Image im, Weather w, DateTime now) {
    final l = now.toLocal();
    final days = w.days.where((d) => d.date.toLocal().isAfter(DateTime(l.year, l.month, l.day, 12))).take(6).toList();
    if (days.isEmpty) {
      _panel(im, 10, 10, 630, 314);
      _center(im, 'Extended forecast not available', _big, 320, 150, _pale);
      return;
    }
    final cw = 620 ~/ days.length;
    for (final (i, d) in days.indexed) {
      final x0 = 10 + i * cw, x1 = x0 + cw - 4, cx = (x0 + x1) ~/ 2;
      final t = d.date.toLocal();
      _panel(im, x0, 10, x1, 314);
      _center(im, _days[t.weekday - 1], _big, cx, 18, _yellow);
      _center(im, '${_months[t.month - 1]} ${t.day}', _small, cx, 46, _pale);
      _icon(im, d.code, cx, 100, 34);
      for (final (k, line) in wrapText(wmoText(d.code), x1 - x0 - 8, (s) => textWidth(_small, s)).indexed) {
        _center(im, line, _small, cx, 146 + k * 18, _white);
      }
      final hw = _tempWidth(d.hi, _big), lw = _tempWidth(d.lo, _big);
      _text(im, 'HI', _small, cx - 20, 190, _pale);
      _temp(im, d.hi, _big, cx - hw ~/ 2, 206, _white);
      _text(im, 'LO', _small, cx - 20, 236, _pale);
      _temp(im, d.lo, _big, cx - lw ~/ 2, 252, _pale);
      if (d.rainChance != null) _center(im, 'RAIN ${d.rainChance}%', _small, cx, 290, d.rainChance! >= 50 ? _blue : _pale);
    }
  }

  void _alerts(img.Image im, Weather w) {
    _panel(im, 10, 10, 630, 314);
    var y = 18;
    var shown = 0;
    for (final a in w.alerts) {
      final head = fit(sanitize(a.event).toUpperCase(), 596, (s) => textWidth(_big, s));
      final lines = wrapText(sanitize(a.headline), 596, (s) => textWidth(_small, s), maxLines: 3);
      final need = 32 + lines.length * 18 + 10;
      if (y + need > 290 && shown > 0) break;
      _rect(im, 18, y, 622, y + 30, _red);
      _text(im, head, _big, 24, y + 3, _white);
      y += 34;
      for (final line in lines) {
        _text(im, line, _small, 24, y, _white);
        y += 18;
      }
      y += 10;
      shown++;
    }
    final more = w.alerts.length - shown;
    if (more > 0) _text(im, '+ $more MORE ALERT${more == 1 ? '' : 'S'}', _small, 24, 292, _yellow);
  }

  /// A simple weather symbol for WMO [code], centred on (cx, cy), about [s] px wide.
  void _icon(img.Image im, int code, int cx, int cy, int s, {bool day = true}) {
    final r = s ~/ 2;
    void sun(int x, int y, int rr) {
      for (var k = 0; k < 8; k++) {
        final a = k * math.pi / 4, c = math.cos(a), sn = math.sin(a);
        img.drawLine(im,
            x1: x + (c * rr * 1.35).round(), y1: y + (sn * rr * 1.35).round(),
            x2: x + (c * rr * 1.75).round(), y2: y + (sn * rr * 1.75).round(),
            color: _yellow, thickness: rr > 12 ? 3 : 2);
      }
      img.fillCircle(im, x: x, y: y, radius: rr, color: _yellow);
    }

    void moon(int x, int y, int rr) {
      img.fillCircle(im, x: x, y: y, radius: rr, color: _pale);
      img.fillCircle(im, x: x + rr ~/ 2, y: y - rr ~/ 3, radius: rr, color: _cell);
    }

    void cloud(int x, int y, int w, img.Color c) {
      final h = w ~/ 2;
      img.fillCircle(im, x: x - w * 3 ~/ 10, y: y, radius: h * 6 ~/ 10, color: c);
      img.fillCircle(im, x: x + w ~/ 12, y: y - h * 3 ~/ 10, radius: h * 8 ~/ 10, color: c);
      img.fillCircle(im, x: x + w * 3 ~/ 10, y: y + h ~/ 10, radius: h * 5 ~/ 10, color: c);
      _rect(im, x - w * 3 ~/ 10, y, x + w * 3 ~/ 10 + 1, y + h * 6 ~/ 10, c);
    }

    void drops(img.Color c, {bool snow = false}) {
      for (var k = -1; k <= 1; k++) {
        final x = cx + k * r * 2 ~/ 3, y = cy + r * 2 ~/ 3;
        if (snow) {
          img.fillCircle(im, x: x, y: y + 2, radius: (r ~/ 8).clamp(1, 4), color: c);
        } else {
          img.drawLine(im, x1: x + 2, y1: y, x2: x - 2, y2: y + r ~/ 2, color: c, thickness: 2);
        }
      }
    }

    switch (code) {
      case 0 || 1:
        day ? sun(cx, cy, r * 6 ~/ 10) : moon(cx, cy, r * 7 ~/ 10);
        if (code == 1) cloud(cx + r ~/ 2, cy + r ~/ 3, s * 6 ~/ 10, _cloud);
      case 2:
        day ? sun(cx - r ~/ 3, cy - r ~/ 3, r * 5 ~/ 10) : moon(cx - r ~/ 3, cy - r ~/ 3, r * 5 ~/ 10);
        cloud(cx + r ~/ 6, cy + r ~/ 6, s * 8 ~/ 10, _cloud);
      case 45 || 48:
        for (var k = -1; k <= 1; k++) {
          _rect(im, cx - r, cy + k * r * 5 ~/ 10, cx + r, cy + k * r * 5 ~/ 10 + (r ~/ 5).clamp(2, 8), _darkCloud);
        }
      case 51 || 53 || 55 || 56 || 57 || 61 || 63 || 66 || 80 || 81:
        cloud(cx, cy - r ~/ 4, s, _cloud);
        drops(_blue);
      case 65 || 67 || 82:
        cloud(cx, cy - r ~/ 4, s, _darkCloud);
        drops(_blue);
      case 71 || 73 || 75 || 77 || 85 || 86:
        cloud(cx, cy - r ~/ 4, s, _cloud);
        drops(_white, snow: true);
      case 95 || 96 || 99:
        cloud(cx, cy - r ~/ 4, s, _darkCloud);
        img.fillPolygon(im, vertices: [
          img.Point(cx + r ~/ 6, cy + r ~/ 6),
          img.Point(cx - r ~/ 4, cy + r * 3 ~/ 5),
          img.Point(cx, cy + r * 3 ~/ 5),
          img.Point(cx - r ~/ 6, cy + r),
          img.Point(cx + r ~/ 3, cy + r * 2 ~/ 5),
          img.Point(cx + r ~/ 12, cy + r * 2 ~/ 5),
        ], color: _yellow);
      default:
        cloud(cx, cy, s, _cloud);
    }
  }
}
