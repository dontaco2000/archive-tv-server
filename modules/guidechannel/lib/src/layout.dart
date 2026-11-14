/// Pure layout, paging and time-window math for the guide channel (no drawing).
library;

const frameWidth = 640;
const frameHeight = 480;

/// Top band (wordmark, clock, info strip) and the time bar under it.
const topHeight = 126;
const timeBarHeight = 30;
const gridTop = topHeight + timeBarHeight; // 156
const rowHeight = 54;
const rowsPerPage = 6; // 6 * 54 = 324 = 480 - 156
const channelWidth = 148;
const columns = 3; // 3 x 30 min = a 90-minute window
const columnMinutes = 30;
const columnWidth = (frameWidth - channelWidth) ~/ columns; // 164

/// The guide window starts at the half hour at or before [now] (local clock).
DateTime windowStart(DateTime now) {
  final l = now.toLocal();
  return DateTime(l.year, l.month, l.day, l.hour, l.minute - l.minute % columnMinutes);
}

DateTime windowEnd(DateTime start) => start.add(const Duration(minutes: columns * columnMinutes));

/// Horizontal placement of a programme cell inside the window.
class Span {
  final int x0, x1;

  /// The programme started before / ends after the window (draw an arrow).
  final bool cutLeft, cutRight;
  const Span(this.x0, this.x1, this.cutLeft, this.cutRight);
}

int _x(DateTime t, DateTime ws) =>
    channelWidth + (t.difference(ws).inSeconds * columnWidth / (columnMinutes * 60)).round();

/// Where [start]..[end] lands in the window from [ws], or null if it is outside it.
Span? span(DateTime start, DateTime end, DateTime ws) {
  final we = windowEnd(ws);
  if (!end.isAfter(ws) || !start.isBefore(we)) return null;
  final cutLeft = start.isBefore(ws), cutRight = end.isAfter(we);
  return Span(cutLeft ? channelWidth : _x(start, ws), cutRight ? frameWidth : _x(end, ws), cutLeft, cutRight);
}

/// Rows in the scrolling ring: the channels plus 1-6 filler rows (an "end of listings" banner)
/// so the ring is a whole number of pages and every page starts on a page boundary.
int ringRows(int channels) => channels + (rowsPerPage - channels % rowsPerPage);

int pageCount(int channels) => ringRows(channels) ~/ rowsPerPage;

/// Vertical scroll in pixels into the ring after [seconds] of playback: each page holds for
/// [hold] seconds, then slides up over [scroll] seconds (smoothstep ease); loops forever.
int scrollOffset(double seconds, int channels, {double hold = 7, double scroll = 1}) {
  final pages = pageCount(channels);
  final cycle = hold + scroll;
  final n = (seconds / cycle).floor();
  final phase = seconds - n * cycle;
  final page = n % pages;
  var f = phase <= hold ? 0.0 : (phase - hold) / scroll;
  f = f * f * (3 - 2 * f);
  final ring = pages * rowsPerPage * rowHeight;
  return ((page + f) * rowsPerPage * rowHeight).round() % ring;
}

/// ASCII only (the bitmap fonts have no other glyphs): common typography mapped, the rest dropped.
String sanitize(String s) {
  const map = {
    '‘': "'",
    '’': "'",
    '“': '"',
    '”': '"',
    '–': '-',
    '—': '-',
    '…': '...',
    ' ': ' ',
    'é': 'e',
    'è': 'e',
    'ê': 'e',
    'á': 'a',
    'à': 'a',
    'ä': 'a',
    'ö': 'o',
    'ó': 'o',
    'ü': 'u',
    'ú': 'u',
    'í': 'i',
    'ñ': 'n',
    'ç': 'c',
    'É': 'E',
  };
  final b = StringBuffer();
  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    if (r >= 32 && r < 127) {
      b.write(ch);
    } else if (map[ch] != null) {
      b.write(map[ch]);
    }
  }
  return b.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// [s] cut to fit [maxWidth] (as measured by [width]) with a trailing "..." when it had to be cut.
String fit(String s, int maxWidth, int Function(String) width) {
  if (width(s) <= maxWidth) return s;
  var n = s.length;
  while (n > 0 && width('${s.substring(0, n).trimRight()}...') > maxWidth) {
    n--;
  }
  return n == 0 ? '' : '${s.substring(0, n).trimRight()}...';
}

/// "7:30" (12-hour clock, no AM/PM).
String clock12(DateTime t) {
  final l = t.toLocal();
  final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
  return '$h:${l.minute.toString().padLeft(2, '0')}';
}

String ampm(DateTime t) => t.toLocal().hour < 12 ? 'AM' : 'PM';
