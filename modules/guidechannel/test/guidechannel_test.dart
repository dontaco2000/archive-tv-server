import 'package:guidechannel/guidechannel.dart';
import 'package:test/test.dart';

void main() {
  final ws = DateTime(2026, 11, 12, 19, 30);

  test('window starts on the half hour', () {
    expect(windowStart(DateTime(2026, 11, 12, 19, 57, 12)), ws);
    expect(windowStart(DateTime(2026, 11, 12, 20, 0)), DateTime(2026, 11, 12, 20, 0));
    expect(windowEnd(ws), DateTime(2026, 11, 12, 21, 0));
  });

  test('span maps 30 minutes to one column and clips at the window edges', () {
    final a = span(DateTime(2026, 11, 12, 20, 0), DateTime(2026, 11, 12, 20, 30), ws)!;
    expect((a.x0, a.x1, a.cutLeft, a.cutRight),
        (channelWidth + columnWidth, channelWidth + 2 * columnWidth, false, false));
    final b = span(DateTime(2026, 11, 12, 19, 0), DateTime(2026, 11, 12, 22, 0), ws)!;
    expect((b.x0, b.x1, b.cutLeft, b.cutRight), (channelWidth, frameWidth, true, true));
    expect(span(DateTime(2026, 11, 12, 19, 0), ws, ws), isNull); // ended at the window start
    expect(span(windowEnd(ws), DateTime(2026, 11, 12, 22, 0), ws), isNull);
  });

  test('ring is whole pages with 1-6 filler rows', () {
    expect(ringRows(51), 54);
    expect(pageCount(51), 9);
    expect(ringRows(48), 54); // full pages still get a banner page
    expect(ringRows(1), 6);
  });

  test('paging holds, slides, and loops', () {
    const page = rowsPerPage * rowHeight;
    expect(scrollOffset(0, 51), 0);
    expect(scrollOffset(6.9, 51), 0); // holding page 1
    expect(scrollOffset(7.5, 51), page ~/ 2); // halfway through the slide
    expect(scrollOffset(8, 51), page);
    expect(scrollOffset(8.0 * 8 + 1, 51), 8 * page); // last (banner) page
    expect(scrollOffset(8.0 * 9, 51), 0); // looped
    for (var t = 0.0; t < 200; t += 0.1) {
      expect(scrollOffset(t, 51), inInclusiveRange(0, ringRows(51) * rowHeight - 1));
    }
  });

  test('fit truncates with an ellipsis', () {
    int w(String s) => s.length * 10;
    expect(fit('Spider-Man', 100, w), 'Spider-Man');
    expect(fit('The Incredible Hulk', 100, w), 'The Inc...');
    expect(w(fit('The Incredible Hulk', 100, w)), lessThanOrEqualTo(100));
    expect(fit('Hulk', 20, w), '');
  });

  test('sanitize keeps ASCII and maps typography', () {
    expect(sanitize('Episode 13 – The Hulk’s  Café ★'), "Episode 13 - The Hulk's Cafe");
  });

  test('clock', () {
    expect(clock12(DateTime(2026, 11, 12, 0, 5)), '12:05');
    expect(clock12(DateTime(2026, 11, 12, 19, 30)), '7:30');
    expect(ampm(DateTime(2026, 11, 12, 12)), 'PM');
  });

  test('snapshot JSON round trip and now/next', () {
    final s = Snapshot.parse('''{"version":1,"generated":"2026-11-13T01:00:00Z","channels":[
      {"number":2,"name":"Funnies","genre":"Kids & Animation","programmes":[
        {"start":"2026-11-13T01:30:00Z","end":"2026-11-13T02:00:00Z","title":"B"},
        {"start":"2026-11-13T01:00:00Z","end":"2026-11-13T01:30:00Z","title":"A"}]}]}''');
    final c = s.channels.single;
    expect(c.programmes.first.title, 'A'); // sorted
    expect(c.at(DateTime.utc(2026, 11, 13, 1, 10))!.title, 'A');
    expect(c.after(DateTime.utc(2026, 11, 13, 1, 10))!.title, 'B');
    expect(Snapshot.fromJson(s.toJson()).channels.single.programmes.length, 2);
  });

  test('renderer draws full frames and reuses unchanged ones', () {
    final s = Snapshot(generated: ws, channels: [
      for (var i = 0; i < 51; i++)
        GuideChannelInfo(number: i + 2, name: 'Channel$i', genre: 'TV', programmes: [
          Programme(ws, ws.add(const Duration(minutes: 45)), 'A very long programme title that will not fit'),
          Programme(ws.add(const Duration(minutes: 45)), ws.add(const Duration(hours: 3)), 'Next'),
        ]),
    ]);
    final r = GuideRenderer(s);
    final now = ws.add(const Duration(minutes: 10));
    final a = r.frame(now, 0);
    expect(a.length, frameWidth * frameHeight * 3);
    final copy = List<int>.of(a);
    expect(r.frame(now, 0.5), copy); // same second, same page
    expect(r.frame(now, 7.5), isNot(copy)); // sliding
    final y = r.frameYuv(now, 0);
    expect(y.length, frameWidth * frameHeight * 3 ~/ 2);
    // navy header pixel (0x101A5C) in BT.601 limited range: Y ~ 32, U ~ 168, V ~ 122
    final yv = y[2 * frameWidth + 400], u = y[frameWidth * frameHeight + 320 + 200];
    expect(yv, inInclusiveRange(20, 45));
    expect(u, greaterThan(140));
  });
}
