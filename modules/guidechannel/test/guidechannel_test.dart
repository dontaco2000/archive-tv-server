import 'dart:convert';
import 'dart:io';

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

  group('weather channel', () {
    final t0 = DateTime(2026, 11, 13, 15, 20);
    int unix(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;
    Map<String, dynamic> meteo() => {
          'current': {
            'temperature_2m': 71.6, 'apparent_temperature': 73.2, 'dew_point_2m': 60.1, 'relative_humidity_2m': 65,
            'weather_code': 2, 'wind_speed_10m': 12.4, 'wind_direction_10m': 225, 'wind_gusts_10m': 22.0,
            'pressure_msl': 1016.0, 'visibility': 16093.44, 'is_day': 1,
          },
          'hourly': {
            'time': [for (var i = 0; i < 24; i++) unix(DateTime(2026, 11, 13, 15 + i))],
            'temperature_2m': [for (var i = 0; i < 24; i++) 70 - i],
            'weather_code': [for (var i = 0; i < 24; i++) i.isEven ? 61 : 3],
            'precipitation_probability': [for (var i = 0; i < 24; i++) i * 4],
          },
          'daily': {
            'time': [for (var i = 0; i < 7; i++) unix(DateTime(2026, 11, 13 + i))],
            'weather_code': [0, 1, 2, 3, 61, 71, 95],
            'temperature_2m_max': [75, 76, 77, 78, 79, 80, 81],
            'temperature_2m_min': [50, 51, 52, 53, 54, 55, 56],
            'precipitation_probability_max': [0, 10, 20, 30, 40, 50, 60],
            'sunrise': [for (var i = 0; i < 7; i++) unix(DateTime(2026, 11, 13 + i, 6, 23))],
            'sunset': [for (var i = 0; i < 7; i++) unix(DateTime(2026, 11, 13 + i, 16, 59))],
            'uv_index_max': [5.2, 4, 3, 2, 1, 0, 0],
            'wind_speed_10m_max': [11, 12, 13, 14, 15, 16, 17],
          },
        };
    Map<String, dynamic> alerts(int n, String text) => {
          'features': [
            for (var i = 0; i < n; i++)
              {
                'properties': {'event': '$text $i', 'headline': List.filled(12, text).join(' '), 'ends': '2026-11-13T23:00:00-06:00'}
              },
            {
              'properties': {'headline': 'no event: skipped'}
            },
          ],
        };

    test('Open-Meteo + NWS parsing, units, missing fields', () {
      final w = Weather.parse(meteo(), place: 'Hattiesburg, MS', imperial: true, fetched: t0, alerts: alerts(2, 'Flood Watch'));
      expect((w.temp, w.humidity, w.code, w.condition, w.wind), (71.6, 65, 2, 'Partly Cloudy', 'SW 12'));
      expect(w.pressure, closeTo(30.0, 0.01)); // 1016 hPa in inHg
      expect(w.visibility, closeTo(10, 0.001)); // miles
      expect(w.hours.length, 24);
      expect((w.hours[1].time, w.hours[1].temp, w.hours[1].rainChance), (DateTime(2026, 11, 13, 16), 69.0, 4));
      expect((w.days[6].code, w.days[6].hi, w.days[0].sunrise), (95, 81.0, DateTime(2026, 11, 13, 6, 23)));
      expect(w.alerts.map((a) => a.event), ['Flood Watch 0', 'Flood Watch 1']);
      final m = Weather.parse(meteo(), place: 'x', imperial: false, fetched: t0);
      expect(m.pressure, 1016.0);
      expect(m.visibility, closeTo(16.09, 0.01));
      expect(m.speedUnit, 'KM/H');
      final empty = Weather.parse({}, place: 'x', imperial: true, fetched: t0);
      expect((empty.temp, empty.hours.length, empty.days.length, empty.alerts.length, empty.wind), (0, 0, 0, 0, 'Calm'));
      expect(compass(350), 'N');
      expect(wmoText(95), 'T-Storms');
    });

    test('pages and paging', () {
      expect(weatherPages(null), [WeatherPage.none]);
      final w = Weather.parse(meteo(), place: 'x', imperial: true, fetched: t0, alerts: alerts(1, 'Watch'));
      expect(weatherPages(w).first, WeatherPage.alerts);
      expect(weatherPages(Weather.parse(meteo(), place: 'x', imperial: true, fetched: t0)).length, 4);
      expect(weatherPhase(0, 4), (page: 0, next: 1, f: 0.0));
      expect(weatherPhase(9.5, 4).f, closeTo(0.5, 1e-9));
      expect(weatherPhase(10, 4), (page: 1, next: 2, f: 0.0));
      expect(weatherPhase(39.99, 4).next, 0); // loops
      expect(weatherPhase(5, 1), (page: 0, next: 0, f: 0.0));
    });

    test('wrapText keeps every line inside the width', () {
      int w(String s) => s.length * 10;
      expect(wrapText('Partly Cloudy', 200, w), ['Partly Cloudy']);
      expect(wrapText('Partly Cloudy', 80, w), ['Partly', 'Cloudy']);
      final long = wrapText(List.filled(30, 'word').join(' '), 100, w, maxLines: 3);
      expect(long.length, 3);
      expect(long.last, endsWith('...'));
      for (final l in [...long, ...wrapText('Supercalifragilistic', 50, w)]) {
        expect(w(l), lessThanOrEqualTo(100));
      }
    });

    test('renderer: every page, long names and many alerts, no data, slides', () {
      final long = Weather.parse(meteo(),
          place: 'Llanfairpwllgwyngyllgogerychwyrndrobwllllantysiliogogogoch, Isle of Anglesey, Wales',
          imperial: true,
          fetched: t0.subtract(const Duration(days: 2)),
          alerts: alerts(9, 'Extreme Hurricane And Tornado Warning With A Very Long Name'));
      Weather? data = long;
      final r = WeatherRenderer(() => data, logoPath: '/missing.png');
      final pages = weatherPages(long).length;
      for (var s = 0.0; s < pages * 10; s += 2.5) {
        expect(r.frameYuv(t0, s).length, frameWidth * frameHeight * 3 ~/ 2);
        expect(r.frameImage(t0, s).width, frameWidth);
      }
      data = null;
      expect(r.frameImage(t0, 0).height, frameHeight);
      data = Weather.parse({}, place: '', imperial: false, fetched: t0); // empty forecast: placeholder pages
      for (var s = 0.0; s < 40; s += 10) {
        r.frameYuv(t0, s);
      }
      // a slide frame differs from both held pages
      data = long;
      final a = List<int>.of(r.frameYuv(t0, 0)), mid = List<int>.of(r.frameYuv(t0, 9.5)), b = r.frameYuv(t0, 10);
      expect(mid, isNot(a));
      expect(mid, isNot(b));
    });

    test('feed: cache, staleness, failures keep the last report', () async {
      final dir = Directory.systemTemp.createTempSync('wxfeed');
      addTearDown(() => dir.deleteSync(recursive: true));
      final cache = File('${dir.path}/weather.json');
      var now = t0;
      var fail = false;
      final asked = <String>[];
      Future<Map<String, dynamic>> get(Uri u, Map<String, String> h) async {
        asked.add(u.host);
        expect(h['User-Agent'], isNotEmpty);
        if (fail) throw const SocketException('down');
        return u.host == 'api.weather.gov' ? alerts(1, 'Frost Advisory') : meteo();
      }

      final logs = <String>[];
      final f = WeatherFeed(Place.hattiesburg, cacheFile: cache, get: get, clock: () => now, log: logs.add);
      expect((f.current, f.stale), (null, true));
      expect(f.forecastUri.queryParameters['temperature_unit'], 'fahrenheit');
      expect(f.alertsUri.queryParameters['point'], '31.3271,-89.2903');
      await f.refresh();
      expect((f.current!.temp, f.current!.alerts.length, f.stale), (71.6, 1, false));
      expect(asked, ['api.open-meteo.com', 'api.weather.gov']);
      now = t0.add(const Duration(minutes: 16));
      expect(f.stale, true);
      fail = true;
      final before = f.current;
      await f.refresh();
      expect(identical(f.current, before), true);
      expect(logs.last, contains('keeping the last report'));
      // a restart reads the cache; another place/units ignores it
      final again = WeatherFeed(Place.hattiesburg, cacheFile: cache, get: get, clock: () => now);
      expect((again.current!.temp, again.current!.fetched), (71.6, t0));
      expect(WeatherFeed(const Place('Elsewhere', 1, 2), cacheFile: cache, get: get).current, isNull);
      expect(WeatherFeed(Place.hattiesburg, imperial: false, cacheFile: cache, get: get).current, isNull);
      // no alerts service (outside the US): the forecast still updates
      Future<Map<String, dynamic>> noAlerts(Uri u, Map<String, String> h) async =>
          u.host == 'api.weather.gov' ? throw const HttpException('HTTP 400') : meteo();
      final out = WeatherFeed(Place.hattiesburg, get: noAlerts);
      await out.refresh();
      expect((out.current!.temp, out.current!.alerts.length), (71.6, 0));
      expect(jsonDecode(cache.readAsStringSync())['key'], '31.3271,-89.2903,imperial');
    });

    test('stream: audio input replaces the silence', () {
      final g = GuideChannel(Snapshot(generated: ws, channels: const []));
      final a = g.ffmpegArgs();
      expect(a.sublist(a.indexOf('pipe:0') + 1, a.indexOf('pipe:0') + 5), GuideChannel.silence);
      final pcm = ['-f', 's16le', '-ar', '44100', '-ac', '2', '-i', 'http://127.0.0.1:8100/internal/music/99?g=1'];
      final m = GuideChannel.frames(WeatherRenderer(() => null), audioInput: pcm).ffmpegArgs();
      final i = m.indexOf('pipe:0');
      expect(m.sublist(i + 1, i + 1 + pcm.length), pcm);
      expect(m, isNot(contains('anullsrc=r=44100:cl=stereo')));
      expect(m.sublist(m.indexOf('-map'), m.indexOf('-map') + 4), ['-map', '0:v', '-map', '1:a']);
    });
  });
}
