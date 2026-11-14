import 'package:archive_tv_overlays/archive_tv_overlays.dart';
import 'package:test/test.dart';

void main() {
  const line = '[cropdetect@atv_cd @ 0x55d0] x1:106 x2:745 y1:0 y2:479 w:640 h:480 x:106 y:0 pts:3003 '
      't:2.100000 limit:0.094118 crop=640:480:106:0';

  test('parses an ffmpeg cropdetect line', () {
    final p = parseCropdetectLine(line)!;
    expect(p.$1, 2.1);
    expect(p.$2, const CropRect(106, 0, 640, 480));
  });

  test('ignores other lines and invalid boxes', () {
    expect(parseCropdetectLine('frame=  100 fps= 30 q=21.0'), isNull);
    expect(parseCropdetectLine('[cropdetect] x1:0 t:1.0 crop=-16:480:8:0'), isNull);
  });

  const pillar = CropRect(106, 0, 640, 480), full = CropRect(0, 0, 852, 480);

  group('decideCrop (app rules)', () {
    test('undecided below 6 samples or unstable', () {
      expect(decideCrop(List.filled(5, pillar), 852, 480), isNull);
      expect(decideCrop([...List.filled(5, pillar), const CropRect(100, 0, 652, 480)], 852, 480), isNull);
      expect(decideCrop([...List.filled(5, pillar), null], 852, 480), isNull);
    });
    test('crops centred pillar bars', () => expect(decideCrop(List.filled(6, pillar), 852, 480), pillar));
    test('thin bars (< 6%) left alone', () {
      expect(decideCrop(List.filled(6, const CropRect(10, 0, 832, 480)), 852, 480), full);
    });
    test('lopsided box (dark scene) left alone', () {
      expect(decideCrop(List.filled(6, const CropRect(0, 0, 640, 480)), 852, 480), full);
    });
    test('would keep < 34%: refused', () {
      expect(decideCrop(List.filled(6, const CropRect(326, 0, 200, 480)), 852, 480), full);
    });
    test('box bigger than source: full frame', () {
      expect(decideCrop(List.filled(6, const CropRect(0, 0, 900, 480)), 852, 480), full);
    });
    test('odd numbers rounded to even', () {
      expect(
          decideCrop(List.filled(6, const CropRect(107, 41, 639, 399)), 852, 480), const CropRect(106, 40, 638, 398));
    });
  });

  test('cropShouldChange: first always, then only materially wider', () {
    expect(cropShouldChange(null, pillar, 852, 480), isTrue);
    expect(cropShouldChange(pillar, pillar, 852, 480), isFalse);
    expect(cropShouldChange(pillar, const CropRect(100, 0, 652, 480), 852, 480), isFalse); // +12 px < 2%
    expect(cropShouldChange(pillar, full, 852, 480), isTrue);
    expect(cropShouldChange(full, pillar, 852, 480), isFalse); // never narrower
  });

  test('CropDecider: one sample a second, decides after 6 s, reset per item', () {
    final d = CropDecider(852, 480);
    CropRect? got;
    for (var f = 0; f < 30 * 8; f++) {
      final r = d.add(line.replaceFirst('t:2.100000', 't:${(f / 30).toStringAsFixed(6)}'));
      if (r != null) {
        expect(got, isNull, reason: 'decided once');
        got = r;
        expect(f ~/ 30, 5); // sixth second
      }
    }
    expect(got, pillar);
    d.reset();
    expect(d.current, isNull);
  });
}
