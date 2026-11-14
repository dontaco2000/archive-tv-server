/// Black-bar crop: parse ffmpeg `cropdetect` log lines and decide a stable crop, mirroring the Archive TV
/// app's Picture Auto mode (app\player\lib\player\picture.dart): one sample a second, the last 4 samples
/// identical, bars >= 6% of an axis and centred, never keep < 34% of an axis, and once a crop is on screen
/// only a materially wider box replaces it.
library;

class CropRect {
  final int x, y, w, h;
  const CropRect(this.x, this.y, this.w, this.h);

  @override
  bool operator ==(Object other) => other is CropRect && other.x == x && other.y == y && other.w == w && other.h == h;
  @override
  int get hashCode => Object.hash(x, y, w, h);
  @override
  String toString() => '${w}x$h+$x+$y';
}

/// The cropdetect settings the app uses. reset=0: the box is the union of every frame since the filter
/// started, so it only grows (a dark scene can't shrink it). limit 24/255 = near pure black.
const cropdetectOptions = 'limit=24:round=2:reset=0';

final _cropRe = RegExp(r'crop=(-?\d+):(-?\d+):(-?\d+):(-?\d+)');
final _tRe = RegExp(r'\bt:(-?[\d.]+)');

/// One cropdetect log line -> (seconds, rect). Null for any other line or an invalid box.
(double, CropRect)? parseCropdetectLine(String line) {
  final c = _cropRe.firstMatch(line), t = _tRe.firstMatch(line);
  if (c == null || t == null) return null;
  final w = int.parse(c[1]!), h = int.parse(c[2]!), x = int.parse(c[3]!), y = int.parse(c[4]!);
  if (w <= 0 || h <= 0 || x < 0 || y < 0) return null;
  return (double.parse(t[1]!), CropRect(x, y, w, h));
}

/// Decides the crop from [samples] (oldest first, one per second; null = no reading) on a [srcW]x[srcH]
/// video. Null while undecided, the full frame for "leave it alone", else the crop. Same rules as the app.
CropRect? decideCrop(List<CropRect?> samples, int srcW, int srcH,
    {int minSamples = 6, int stable = 4, double minBorder = 0.06, double minKeep = 0.34}) {
  final full = CropRect(0, 0, srcW, srcH);
  if (srcW <= 0 || srcH <= 0 || samples.length < minSamples) return null;
  final last = samples.sublist(samples.length - stable);
  final r = last.first;
  if (r == null || last.any((s) => s != r)) return null;
  if (r.x + r.w > srcW || r.y + r.h > srcH) return full; // not this video's numbers

  (int, int) axis(int off, int size, int src) {
    final before = off, after = src - off - size;
    if (before + after < minBorder * src) return (0, src); // bars too thin
    if ((before - after).abs() > 0.02 * src + 4) return (0, src); // lopsided: a dark scene, not bars
    if (size < minKeep * src) return (0, src);
    return (off & ~1, size & ~1);
  }

  final (x, w) = axis(r.x, r.w, srcW);
  final (y, h) = axis(r.y, r.h, srcH);
  return CropRect(x, y, w, h);
}

/// Whether [next] should replace the crop on screen ([current], null = none yet).
bool cropShouldChange(CropRect? current, CropRect next, int srcW, int srcH) {
  if (current == null) return true;
  if (next == current || next.w < current.w || next.h < current.h) return false;
  return next.w - current.w >= 0.02 * srcW || next.h - current.h >= 0.02 * srcH;
}

/// Feed it ffmpeg stderr lines of one item (source [srcW]x[srcH]); [add] returns a rect when the crop on
/// screen should change (full frame = remove the crop). Call [reset] at every new item.
class CropDecider {
  final int srcW, srcH;
  final _samples = <CropRect?>[];
  int _lastSecond = -1;
  CropRect? current;
  CropDecider(this.srcW, this.srcH);

  CropRect? add(String line) {
    final p = parseCropdetectLine(line);
    if (p == null) return null;
    final second = p.$1.floor();
    if (second <= _lastSecond) return null; // one sample a second, like the app
    _lastSecond = second;
    _samples.add(p.$2);
    if (_samples.length > 10) _samples.removeAt(0);
    final next = decideCrop(_samples, srcW, srcH);
    if (next == null || !cropShouldChange(current, next, srcW, srcH)) return null;
    return current = next;
  }

  void reset() {
    _samples.clear();
    _lastSecond = -1;
    current = null;
  }
}
