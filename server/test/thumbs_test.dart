import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:archivetv_server/guide.dart';
import 'package:archivetv_server/settings.dart';
import 'package:archivetv_server/thumbs.dart';
import 'package:archivetv_server/xmltv.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

const ch = Channel(number: 21, name: 'Marquee', genre: 'Movies', logo: 'Logos/4x3/marquee.png');

Uint8List jpg(img.Image im) => img.encodeJpg(im, quality: 90);

/// A busy 320x240 picture (gradient + noise): a "good" thumbnail.
img.Image good() {
  final r = math.Random(1), im = img.Image(width: 320, height: 240);
  for (final p in im) {
    p
      ..r = (p.x * 255 ~/ 320 + r.nextInt(60)).clamp(0, 255)
      ..g = (p.y * 255 ~/ 240 + r.nextInt(60)).clamp(0, 255)
      ..b = r.nextInt(255);
  }
  return im;
}

/// Mid-grey with +-3 noise: bright enough, but flat.
img.Image flat() {
  final r = math.Random(3), im = img.Image(width: 320, height: 240);
  for (final p in im) {
    final v = 125 + r.nextInt(7);
    p
      ..r = v
      ..g = v
      ..b = v;
  }
  return im;
}

img.Image noisyDark() {
  final r = math.Random(2), im = img.Image(width: 320, height: 240);
  for (final p in im) {
    final v = r.nextInt(20);
    p
      ..r = v
      ..g = v
      ..b = v;
  }
  return im;
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('thumbs'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Thumbs make(Map<String, Uint8List?> data, List<String> calls) => Thumbs(tmp,
      channel: (n) => n == 21 ? ch : null,
      logoFile: (c) => logoPath('config', c),
      fetch: (id) async {
        calls.add(id);
        if (!data.containsKey(id)) throw const SocketException('down');
        return data[id];
      });

  test('usable thumbnail rule: tiny file, black, flat, undecodable = no; busy picture = yes', () {
    expect(usableThumb(null), isNull);
    expect(usableThumb(Uint8List(2500)), isNull, reason: 'placeholder size');
    expect(usableThumb(Uint8List(5000)), isNull, reason: 'not an image');
    expect(usableThumb(jpg(noisyDark())), isNull, reason: 'black frame');
    final f = img.encodePng(flat());
    expect(f.length, greaterThan(3000));
    expect(usableThumb(f), isNull, reason: 'flat grey');
    expect(usableThumb(jpg(good())), isNotNull);
  });

  test('XMLTV: server icons, direct archive.org icons (bad items none), no icons; channel in desc; settings', () async {
    final e1 = Entry(id: 'a/a.mp4', itemId: 'his_girl_friday', file: 'a.mp4', title: 'A', durationSeconds: 3600, url: 'u');
    final e3 = Entry(id: 'd/d.mp4', itemId: 'dark1', file: 'd.mp4', title: 'D', durationSeconds: 3600, url: 'u');
    const e2 = Entry(id: 'guide', itemId: '', file: '', title: 'Guide', durationSeconds: 3600, url: '');
    final slots = [
      Slot(e1, DateTime(2026), DateTime(2026, 1, 1, 1)),
      Slot(e2, DateTime(2026, 1, 1, 1), DateTime(2026, 1, 1, 2)),
      Slot(e3, DateTime(2026, 1, 1, 2), DateTime(2026, 1, 1, 3)),
    ];
    final rows = [(channel: ch, slots: slots, rated: (Entry _) => false)];
    const base = 'http://192.168.1.64:8100';
    final srv = buildXmltv(base, rows, icon: serverIcon(base));
    expect(srv, contains('<icon src="$base/thumb/21/his_girl_friday.jpg"/>'));
    expect(srv, contains('<icon src="$base/cards/21.png"/>'));
    expect(RegExp('<programme').allMatches(srv).length, 3);
    expect(srv, contains('<desc lang="en">Channel 21 Marquee. From the Internet Archive'));

    // direct: unknown items get the archive.org URL at once and are checked in the background
    final calls = <String>[];
    final t = make({'his_girl_friday': jpg(good()), 'dark1': jpg(noisyDark())}, calls);
    String direct() => buildXmltv(base, rows, icon: (c, e) => t.directIcon(e.itemId));
    var x = direct();
    expect(x, contains('<icon src="https://archive.org/services/img/his_girl_friday"/>'));
    expect(x, contains('<icon src="https://archive.org/services/img/dark1"/>'), reason: 'optimistic until checked');
    expect(RegExp('<icon').allMatches(x).length, 3, reason: 'channel logo + 2 programmes; guide entry has none');
    while (t.pending > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    x = direct();
    expect(x, contains('services/img/his_girl_friday'));
    expect(x, isNot(contains('services/img/dark1')), reason: 'known bad: no icon');
    expect(x, isNot(contains('/thumb/')));
    expect(x, isNot(contains('/cards/')));
    expect(calls..sort(), ['dark1', 'his_girl_friday'], reason: 'each checked once');
    expect(File('${tmp.path}/thumbs/_ok/his_girl_friday').existsSync(), isTrue);
    expect(File('${tmp.path}/thumbs/_bad/dark1').existsSync(), isTrue);
    expect(make({}, calls).usable('dark1'), isFalse, reason: 'verdicts persist on disk');

    final off = buildXmltv('http://h', rows);
    expect(off, isNot(contains('/thumb/')));
    expect(off, isNot(contains('archive.org/services')));
    expect(off, contains('/logos/21.png'), reason: 'channel icons stay');

    expect(Settings.parse('programme_thumbs = false').programmeThumbs, isFalse);
    expect(Settings.parse('').programmeThumbs, isTrue);
    expect(Settings.parse(Settings.defaultText).programmeThumbs, isTrue);
    expect(Settings.parse('').programmeThumbsDirect, isTrue);
    expect(Settings.parse(Settings.defaultText).programmeThumbsDirect, isTrue);
    expect(Settings.parse('programme_thumbs_mode = server').programmeThumbsDirect, isFalse);
    final bad = Settings.parse('programme_thumbs_mode = sideways');
    expect((bad.programmeThumbsDirect, bad.warnings.length), (true, 1));
  });

  test('check: transient errors are not saved and not retried for an hour; at most 2 fetches at once', () async {
    var active = 0, peak = 0;
    final calls = <String>[];
    final t = Thumbs(tmp, channel: (_) => ch, logoFile: (_) => null, fetch: (id) async {
      calls.add(id);
      peak = math.max(peak, ++active);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      active--;
      if (id == 'down') throw const SocketException('down');
      return jpg(good());
    });
    for (final id in ['a', 'b', 'c', 'd', 'down', 'a']) {
      t.check(id);
    }
    while (t.pending > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(peak, 2);
    expect(t.usable('down'), isNull);
    t.check('down');
    expect(t.pending, 0, reason: 'failed recently');
    expect(calls.length, 5);
  });

  test('cache: a poster is fetched once; an unusable item is remembered; fetch errors are not', () async {
    final calls = <String>[];
    final data = {'good1': jpg(good()), 'dark1': jpg(noisyDark()), 'gone': null};
    var t = make(data, calls);
    final (p1, long1) = await t.poster(ch, 'good1');
    expect(long1, isTrue);
    final dec = img.decodeJpg(p1)!;
    expect((dec.width, dec.height), (600, 900));
    await t.poster(ch, 'good1');
    t = make(data, calls); // new process, same data folder
    final (p2, _) = await t.poster(ch, 'good1');
    expect(p2, p1);
    expect(calls, ['good1']);

    final (c1, _) = await t.poster(ch, 'dark1');
    expect(c1, await t.card(ch, jpg: true), reason: 'unusable -> channel card');
    await make(data, calls).poster(ch, 'dark1');
    await t.poster(ch, 'gone');
    await make(data, calls).poster(ch, 'gone');
    expect(calls, ['good1', 'dark1', 'gone']);

    final (_, long) = await t.poster(ch, 'offline');
    expect(long, isFalse, reason: 'transient failure: short cache');
    await t.poster(ch, 'offline');
    expect(calls.where((c) => c == 'offline').length, 1, reason: 'remembered for an hour in memory');
    expect(File('${tmp.path}/thumbs/_bad/offline').existsSync(), isFalse);
  });

  test('cache cap: oldest posters deleted', () async {
    final calls = <String>[];
    final t = Thumbs(tmp,
        channel: (_) => ch,
        logoFile: (_) => null,
        capBytes: 1,
        fetch: (id) async {
          calls.add(id);
          return jpg(good());
        });
    await t.poster(ch, 'one');
    await t.poster(ch, 'two');
    expect(Directory('${tmp.path}/thumbs/21').listSync().length, lessThanOrEqualTo(1));
  });

  test('HTTP: cards are PNGs of the right size; bad ids refused; posters are JPEG', () async {
    final calls = <String>[];
    final t = make({'good1': jpg(good())}, calls);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      if (!await t.serve(req)) req.response.statusCode = 404;
      await req.response.close();
    });
    final base = 'http://127.0.0.1:${server.port}';
    try {
      for (final (path, w, h) in [('/cards/21.png', 600, 900), ('/cards/21-wide.png', 960, 540)]) {
        final r = await http.get(Uri.parse('$base$path'));
        expect(r.statusCode, 200);
        expect(r.headers['content-type'], 'image/png');
        expect(r.headers['cache-control'], contains('max-age'));
        final im = img.decodePng(r.bodyBytes)!;
        expect((im.width, im.height), (w, h));
      }
      expect((await http.get(Uri.parse('$base/cards/5.png'))).statusCode, 404);
      for (final bad in [
        '/thumb/21/..%2Fsecret.jpg',
        '/thumb/21/a%20b.jpg',
        '/thumb/21/.hidden.jpg',
        '/thumb/21/a;b.jpg',
        '/thumb/x/a.jpg'
      ]) {
        expect((await http.get(Uri.parse('$base$bad'))).statusCode, 400, reason: bad);
      }
      final r = await http.get(Uri.parse('$base/thumb/21/good1.jpg'));
      expect(r.statusCode, 200);
      expect(r.headers['content-type'], 'image/jpeg');
      expect(calls, ['good1']);
    } finally {
      await server.close(force: true);
    }
  });

  // Sample images for a visual check: THUMB_SAMPLES=<dir> dart test test/thumbs_test.dart -N samples (real Archive fetch).
  final out = Platform.environment['THUMB_SAMPLES'];
  test('samples', skip: out == null ? 'set THUMB_SAMPLES=<dir>' : null, () async {
    final config = parseChannelConfig(File('config/channels.json').readAsStringSync());
    final byN = {for (final c in config.channels) c.number: c};
    final real = archiveThumbFetch();
    final t = Thumbs(Directory('$out/cache'),
        channel: (n) => byN[n],
        logoFile: (c) => logoPath('config', c),
        fetch: (id) async {
          if (id == 'synthetic-dark') return jpg(noisyDark());
          return real(id);
        });
    for (final n in [2, 21, 71]) {
      File('$out/card-$n.png').writeAsBytesSync(await t.card(byN[n]!));
      File('$out/card-$n-wide.png').writeAsBytesSync(await t.card(byN[n]!, wide: true));
    }
    for (final (n, id) in [
      (21, 'his_girl_friday'),
      (2, 'Popeye_forPresident'),
      (2, 'BettyBoopCartoons'),
      (21, 'synthetic-dark'),
      (71, 'zzz-no-such-item-archivetv-1'),
      (21, 'night_of_the_living_dead'),
    ]) {
      final (b, _) = await t.poster(byN[n]!, id);
      File('$out/poster-$n-$id.jpg').writeAsBytesSync(b);
    }
  });
}
