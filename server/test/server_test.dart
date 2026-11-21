import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:archivetv_server/engine.dart';
import 'package:archivetv_server/guide.dart';
import 'package:archivetv_server/hdhr.dart';
import 'package:archivetv_server/music.dart';
import 'package:archivetv_server/settings.dart';
import 'package:archivetv_server/streamer.dart';
import 'package:archivetv_server/titles.dart';
import 'package:archivetv_server/xmltv.dart';
import 'package:archive_tv_overlays/archive_tv_overlays.dart' as ov;
import 'package:test/test.dart';

Entry entry(String id, double seconds) =>
    Entry(id: '$id/$id.mp4', itemId: id, file: '$id.mp4', title: '$id & co <1>', durationSeconds: seconds, url: 'http://x/$id.mp4');

const ch = Channel(number: 7, name: 'Capes', genre: 'Movies', mature: true);

/// Entries back to back from [start] (once), minus skipped ones.
class FakeSchedule implements Schedule {
  final List<Entry> order;
  final DateTime start;
  final bad = <String>[];
  PoolStatus status = PoolStatus.ready;
  FakeSchedule(this.order, this.start);

  @override
  Airing? airing(Channel c, DateTime now) {
    var t = start;
    final slots = <Slot>[];
    for (final e in order) {
      if (bad.contains(e.id)) continue;
      final end = t.add(Duration(seconds: e.durationSeconds.round()));
      slots.add(Slot(e, t, end));
      t = end;
    }
    final slot = slotAt(slots, now);
    return slot == null ? null : Airing(c, slot, offsetSeconds(slot, now));
  }

  @override
  void markBad(Channel c, String entryId) => bad.add(entryId);

  @override
  PoolStatus statusOf(Channel c) => status;

  @override
  bool isRated(Channel c, Entry e) => e.id == 'b/b.mp4';

  @override
  bool lateNight(Channel c, DateTime t) => true;
}

class FakeProcess implements Process {
  final _out = StreamController<List<int>>();
  final _err = StreamController<List<int>>();
  final _code = Completer<int>();
  FakeProcess._hang();
  FakeProcess(String out, String err, int code) {
    scheduleMicrotask(() async {
      if (err.isNotEmpty) _err.add(utf8.encode(err));
      if (out.isNotEmpty) _out.add(utf8.encode(out));
      await _out.close();
      await _err.close();
      _code.complete(code);
    });
  }
  @override
  Stream<List<int>> get stdout => _out.stream;
  @override
  Stream<List<int>> get stderr => _err.stream;
  @override
  Future<int> get exitCode => _code.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
  @override
  int get pid => 1;
  /// Everything written to stdin (ffmpeg filter commands).
  final commands = StringBuffer();
  late final IOSink _in = IOSink(_Collect(commands));
  @override
  IOSink get stdin => _in;
}

class _Collect implements StreamConsumer<List<int>> {
  final StringBuffer b;
  _Collect(this.b);
  @override
  Future<void> addStream(Stream<List<int>> s) => s.forEach((d) => b.write(utf8.decode(d)));
  @override
  Future<void> close() async {}
}

/// Never writes anything until killed (a seek that decodes from the start).
class HangingProcess extends FakeProcess {
  HangingProcess() : super._hang();
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_code.isCompleted) {
      _out.close();
      _err.close();
      _code.complete(-15);
    }
    return true;
  }
}

void main() {
  final day = DateTime(2026, 11, 12);
  final a = entry('a', 100), b = entry('b', 200), c = entry('c', 300);

  test('HDHomeRun discover and lineup', () {
    final d = jsonDecode(discoverJson('http://h:8100', 4)) as Map;
    expect(d['TunerCount'], 4);
    expect(d['LineupURL'], 'http://h:8100/lineup.json');
    expect((d['DeviceID'] as String).length, 8);
    final l = jsonDecode(lineupJson('http://h:8100', [ch])) as List;
    expect(l.single, {'GuideNumber': '7', 'GuideName': 'Capes', 'URL': 'http://h:8100/auto/v7'});
    expect(jsonDecode(lineupStatusJson())['ScanPossible'], 1);
  });

  test('XMLTV: channels, programmes, escaping, ratings', () {
    final slots = layoutDay([a, b], day).take(2).toList();
    final xml = buildXmltv('http://h:8100', [(channel: ch, slots: slots, rated: (e) => e.id == b.id)]);
    expect(xml, contains('<channel id="7">'));
    expect(xml, contains('<icon src="http://h:8100/logos/7.png"/>'));
    expect(xml, contains('<title lang="en">A &amp; Co &lt;1&gt;</title>'));
    expect('<programme '.allMatches(xml).length, 2);
    expect(xml, contains('start="${xmltvTime(day)}"'));
    expect(xml, contains('stop="${xmltvTime(day.add(const Duration(seconds: 100)))}"'));
    expect('<value>R</value>'.allMatches(xml).length, 1);
    expect(xml, contains('<category lang="en">Movie</category>'));
    expect(xml, contains('mature content'));
    expect(xmltvTime(DateTime(2026, 1, 2, 3, 4, 5)), startsWith('20260102030405 '));
  });

  group('stream slots', () {
    late FakeSchedule sched;
    late Streamer streamer;
    late List<List<String>> spawned;
    late List<FakeProcess Function()> procs;

    setUp(() {
      sched = FakeSchedule([a, b, c], day);
      spawned = [];
      procs = [];
      streamer = Streamer(
        schedule: sched,
        ffmpeg: 'ffmpeg',
        selfBase: 'http://127.0.0.1:1',
        tmpDir: Directory.systemTemp,
        spawn: (exe, args) async {
          spawned.add(args);
          return procs.removeAt(0)();
        },
      );
    });

    Job at(Session s, int seconds) => s.nextJob(day.add(Duration(seconds: seconds)));

    test('pieces join end to end across an item boundary', () {
      final s = Session(ch, streamer, 1);
      final j1 = at(s, 40);
      expect(j1.entry, a);
      expect(j1.offset, 40);
      expect(j1.length, const Duration(seconds: 60));
      // The next request comes when j1 ends (t = 100): b from its start.
      final j2 = at(s, 40 + j1.length.inSeconds);
      expect((j2.entry, j2.offset, j2.length), (b, 0, const Duration(seconds: 200)));
      // Under 5 s left of a: go straight to b, whole.
      final j3 = at(s, 97);
      expect((j3.entry, j3.offset, j3.length), (b, 0, const Duration(seconds: 200)));
    });

    test('a file that ended before its slot: STAND BY for the rest', () {
      final s = Session(ch, streamer, 1);
      s.lastEnded = at(s, 10).key;
      final j = at(s, 90);
      expect(j.entry, isNull);
      expect(j.length, const Duration(seconds: 10));
    });

    test('no pool yet: STAND BY', () {
      sched.status = PoolStatus.building;
      expect(at(Session(ch, streamer, 1), 10).entry, isNull);
    });

    Future<String> serve(Session s) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) => s.serveItem(req.response));
      final res = await (await HttpClient().get('127.0.0.1', server.port, '/')).close();
      final body = await utf8.decodeStream(res);
      await server.close(force: true);
      return body;
    }

    test('an item that fails twice is skipped, the next one plays', () async {
      // the clock is real here, so lay the day out around now
      sched = FakeSchedule([a, b, c], DateTime.now().subtract(const Duration(seconds: 30)));
      streamer = Streamer(schedule: sched, ffmpeg: 'ffmpeg', selfBase: '', tmpDir: Directory.systemTemp, spawn: (e, args) async {
        spawned.add(args);
        return procs.removeAt(0)();
      });
      procs.addAll([() => FakeProcess('', 'HTTP error 404', 1), () => FakeProcess('', 'HTTP error 404', 1), () => FakeProcess('BBBB', '', 0)]);
      final body = await serve(Session(ch, streamer, 1));
      expect(body, 'BBBB');
      expect(sched.bad, [a.id]);
      expect([for (final a in spawned) a.contains('http://x/b.mp4')], [false, false, true]);
      expect(spawned.first, contains('-ss'));
    });

    test('a file without audio gets a silent track, not a skip', () async {
      sched = FakeSchedule([a, b], DateTime.now().subtract(const Duration(seconds: 5)));
      streamer = Streamer(schedule: sched, ffmpeg: 'ffmpeg', selfBase: '', tmpDir: Directory.systemTemp, spawn: (e, args) async {
        spawned.add(args);
        return procs.removeAt(0)();
      });
      procs.addAll([() => FakeProcess('', "Stream map '0:a:0' matches no streams.", 1), () => FakeProcess('AAAA', '', 0)]);
      expect(await serve(Session(ch, streamer, 1)), 'AAAA');
      expect(sched.bad, isEmpty);
      expect(spawned.last, contains('anullsrc=r=44100:cl=stereo'));
      expect(spawned.last, containsAllInOrder(['-map', '1:a']));
    });

    test('a piece with no output in time is killed and its item skipped at once', () async {
      sched = FakeSchedule([a, b], DateTime.now().subtract(const Duration(seconds: 5)));
      streamer = Streamer(
          schedule: sched,
          ffmpeg: 'ffmpeg',
          selfBase: '',
          tmpDir: Directory.systemTemp,
          firstOutput: const Duration(milliseconds: 100),
          spawn: (e, args) async {
            spawned.add(args);
            return procs.removeAt(0)();
          });
      procs.addAll([HangingProcess.new, () => FakeProcess('BB', '', 0)]);
      expect(await serve(Session(ch, streamer, 1)), 'BB');
      expect(sched.bad, [a.id]);
      expect(spawned.length, 2);
    });

    test('first piece bursts the lead, the next one starts at the stream position with a smaller burst', () async {
      sched = FakeSchedule([a, b, c], DateTime.now().subtract(const Duration(seconds: 97)));
      streamer = Streamer(schedule: sched, ffmpeg: 'ffmpeg', selfBase: '', tmpDir: Directory.systemTemp, spawn: (e, args) async {
        spawned.add(args);
        return procs.removeAt(0)();
      });
      procs.addAll([() => FakeProcess('A', '', 0), () => FakeProcess('B', '', 0)]);
      final s = Session(ch, streamer, 1);
      expect(await serve(s), 'A');
      expect(spawned[0], containsAllInOrder(['-readrate', '1', '-readrate_initial_burst', '6.0']));
      expect(await serve(s), 'B');
      // b starts from the stream position (a's slot end), already ahead of the clock: less than a full burst
      expect(spawned[1], isNot(contains('-ss')));
      final i = spawned[1].indexOf('-readrate_initial_burst');
      expect(i < 0 || double.parse(spawned[1][i + 1]) < 6, isTrue);
    });
  });

  group('overlays', () {
    const o = Overlays(logo: _logo, watermark: '/w.png', tuneBanner: true, lateNightNotice: true);
    final job = Job(entry('b', 200), 0, const Duration(seconds: 200), 'k');

    test('video piece: overlay graph, live stdin, burst, R badge + card for an R programme', () {
      final args = jobArgs(job,
          overlay: const OverlayParamsForTest(mature: true).params, burst: 6);
      expect(args, isNot(contains('-nostdin')));
      expect(args, containsAllInOrder(['-readrate', '1', '-readrate_initial_burst', '6.0', '-reconnect']));
      expect(args, containsAllInOrder(['-i', 'http://x/b.mp4', '-i', '/l.png', '-i', '/w.png', '-t']));
      final g = args[args.indexOf('-filter_complex') + 1];
      expect(g, contains('drawtext@atv_bname'));
      expect(g, contains('drawbox@atv_rbox=x=16:y=58:w=28:h=28:color=0xFFB300:t=2:enable=1'));
      expect(g, contains(r'drawbox@atv_dcard=x=0:y=0:w=640:h=480:color=black:t=fill:enable=between(t\,0\,6)'));
      expect(args, containsAllInOrder(['-map', '[vout]', '-map', '0:a:0']));
      expect(args, containsAllInOrder(['-fps_mode', 'cfr', '-r', '30000/1001', '-c:v', 'libx264']));
      expect(o.watermark, '/w.png');
    });

    test('defaults: clean picture, watermark + label, R watermark for R programmes', () async {
      final sched = FakeSchedule([a, b], DateTime.now().subtract(const Duration(seconds: 150)));
      final seen = <List<String>>[];
      final streamer = Streamer(
          schedule: sched,
          ffmpeg: 'ffmpeg',
          selfBase: '',
          tmpDir: Directory.systemTemp,
          overlays: const Overlays(logo: _logo, watermark: '/w.png', watermarkRated: '/wR.png'),
          spawn: (e, args) async {
            seen.add(args);
            return FakeProcess('X', '', 0);
          });
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final s = Session(ch, streamer, 1);
      server.listen((req) => s.serveItem(req.response));
      await utf8.decodeStream(await (await HttpClient().get('127.0.0.1', server.port, '/')).close());
      await server.close(force: true);
      final args = seen.single, g = args[args.indexOf('-filter_complex') + 1];
      expect(args, contains('/wR.png')); // b is R-rated in the fake schedule
      expect(args, isNot(contains('/l.png'))); // no banner/bug: the logo isn't even read
      expect(g, contains('text=7 CAPES'));
      for (final off in ['atv_bname', 'atv_bugnum', 'atv_rbox', 'atv_dcard', 'atv_dstrip1', 'atv_blate']) {
        expect(g, matches(RegExp('@$off=[^;]*?enable=0' r'(,|\[|$)')), reason: off);
      }
      expect(g, isNot(contains('LATE NIGHT ADULT MODE:fontsize=13:fontcolor=0xFFB300:x=28:y=74:enable=between')));
    });

    test('a file without video: black stand-in is input 0, audio from the file', () {
      final args = jobArgs(job, noVideo: true, overlay: const OverlayParamsForTest().params);
      expect(args.indexOf('color=c=black:s=640x480:r=30000/1001'), lessThan(args.indexOf('http://x/b.mp4')));
      expect(args, containsAllInOrder(['-map', '[vout]', '-map', '1:a:0', '-shortest']));
    });

    test('cards: lavfi inputs paced, the message drawn', () {
      final args = jobArgs(const Job.standby(Duration(seconds: 30), 'NO SIGNAL'),
          overlay: const OverlayParamsForTest(message: 'NO SIGNAL').params, burst: 3);
      expect(args, containsAllInOrder(['-readrate', '1', '-readrate_initial_burst', '3.0', '-f', 'lavfi', '-i']));
      expect(args[args.indexOf('-filter_complex') + 1], contains('text=NO SIGNAL'));
      expect(args, containsAllInOrder(['-map', '[vout]', '-map', '1:a']));
    });

    test('a viewer joining a running piece re-triggers the tune banner through stdin', () async {
      final sched = FakeSchedule([a, b], DateTime.now().subtract(const Duration(seconds: 5)));
      final running = FakeProcess._hang();
      final cmdsSeen = <List<String>>[];
      final streamer = Streamer(
          schedule: sched,
          ffmpeg: 'ffmpeg',
          selfBase: '',
          tmpDir: Directory.systemTemp,
          overlays: o,
          spawn: (e, args) async {
            cmdsSeen.add(args);
            return running;
          });
      final s = Session(ch, streamer, 1);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) => req.uri.path == '/item' ? s.serveItem(req.response) : s.watch(req.response));
      final itemF = HttpClient().get('127.0.0.1', server.port, '/item').then((r) => r.close());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      running._out.add([1, 2, 3]); // first output
      final got = (await itemF).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final viewer = HttpClient();
      unawaited(viewer.get('127.0.0.1', server.port, '/watch').then((r) => r.close()).then((r) => r.listen((_) {}, onError: (_) {})).then((_) {}, onError: (_) {}));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await running._in.flush();
      expect(running.commands.toString(), contains('cdrawtext@atv_bname -1 enable between(t,'));
      expect(running.commands.toString(), contains('cdrawtext@atv_blate -1 enable between(t,')); // late night
      // the piece itself: overlay graph for channel 7, lateNight from the schedule
      expect(cmdsSeen.single.join(' '), contains('LATE NIGHT ADULT MODE'));
      s.stop();
      running.kill();
      await got.cancel();
      viewer.close(force: true);
      await server.close(force: true);
    });
  });

  group('guide channel 99, settings, titles', () {
    test('lineup and XMLTV include channel 99', () {
      final l = jsonDecode(lineupJson('http://h:8100', [ch, guideChannel])) as List;
      expect(l.last, {'GuideNumber': '99', 'GuideName': 'Guide', 'URL': 'http://h:8100/auto/v99'});
      final slots = guideChannelSlots(DateTime(2026, 11, 12, 19, 40), 3);
      expect(slots.first.start, DateTime(2026, 11, 12, 19));
      final xml = buildXmltv('http://h', [(channel: guideChannel, slots: slots, rated: (_) => false)]);
      expect('<title lang="en">Archive TV Guide</title>'.allMatches(xml).length, 3);
      expect(xml, contains('<icon src="http://h/logos/99.png"/>'));
      expect(xml, contains('Scrolling listings'));
      expect(logoPath('/c', guideChannel), '/c/logos/guide.png');
      expect(logoPath('/c', const Channel(number: 2, name: 'Funnies', logo: 'Logos/4x3/funnies.png')), '/c/logos/funnies.png');
      expect(logoPath('/c', const Channel(number: 13, name: 'Drive-In')), '/c/logos/drivein.png');
    });

    test('programme titles: cleaned, SxxEyy as episode-num', () {
      Entry e(String t) => Entry(id: 'i/f', itemId: 'i', file: 'f', title: t, durationSeconds: 60, url: '');
      expect(programmeTitleInfo(e('Martha.Speaks.S01E39.1080p.WEB-DL.AAC2.0.H.264-NTb')).title, 'Martha Speaks S01E39');
      final i = programmeTitleInfo(e('Camp Lazlo S02E04 Strange Trout'));
      expect((i.season, i.episode), (2, 4));
      final xml = buildXmltv('http://h', [(channel: ch, slots: [Slot(e('Camp Lazlo S02E04'), DateTime(2026), DateTime(2026, 1, 1, 1))], rated: (_) => false)]);
      expect(xml, contains('<episode-num system="xmltv_ns">1.3.</episode-num>'));
      expect(xml, contains('<episode-num system="onscreen">S02E04</episode-num>'));
      final slot = [Slot(e('x'), DateTime(2026), DateTime(2026, 1, 1, 1))];
      expect(buildXmltv('http://h', [(channel: ch, slots: slot, rated: (_) => false)], channelIconBase: 'https://p/cards'),
          contains('<icon src="https://p/cards/${ch.number}.jpg"/>'));
      expect(buildXmltv('http://h', [(channel: ch, slots: slot, rated: (_) => false)]), contains('<icon src="http://h/logos/${ch.number}.png"/>'));
      expect(programmeTitleInfo(e('Plain Title')).episode, isNull);
      // item titles (core programmeInfo + item_info.json): a date-only file gets the item title and a sub-title
      final dir = Directory.systemTemp.createTempSync('atvitems');
      File('${dir.path}/item_info.json').writeAsStringSync(
          jsonEncode({'i': {'t': 'The Tonight Show Starring Johnny Carson', 's': 'Johnny with guests.'}}));
      itemInfos = ItemInfoStore(File('${dir.path}/item_info.json'));
      final c = programmeTitleInfo(e('1987-03-12'));
      expect((c.title, c.subTitle, c.description), ('The Tonight Show Starring Johnny Carson', 'Mar 12, 1987', 'Johnny with guests.'));
      final xml2 = buildXmltv('http://h', [(channel: ch, slots: [Slot(e('1987-03-12'), DateTime(2026), DateTime(2026, 1, 1, 0, 1))], rated: (_) => false)]);
      expect(xml2, contains('<sub-title lang="en">Mar 12, 1987</sub-title>'));
      expect(xml2, contains('<desc lang="en">Channel ${ch.number} ${ch.name}. Johnny with guests. From the Internet Archive'));
      // a guide block keeps its own title and no item description
      expect(programmeTitleInfo(e('Carson Marathon'), block: true).description, isNull);
      itemInfos = null;
      dir.deleteSync(recursive: true);
    });

    test('settings.txt: defaults, values, bad values fall back', () {
      final d = Settings.parse(Settings.defaultText);
      expect((d.lateNightAdultMode, d.tuners, d.overlays, d.watermark, d.guideChannel, d.windowStart), (true, 4, true, true, true, null));
      expect(d.warnings, isEmpty);
      final s = Settings.parse('late_night_adult_mode = false\ntuners=2\nlate_night_start=23:00\nlate_night_end = 04:30\n');
      expect((s.lateNightAdultMode, s.tuners, s.windowStart, s.windowEnd), (false, 2, 23 * 60, 4 * 60 + 30));
      final bad = Settings.parse('late_night_adult_mode = maybe\ntuners = 40\nlate_night_start = 25:00\nlate_night_end=01:00');
      expect((bad.lateNightAdultMode, bad.tuners, bad.windowStart), (true, 4, null));
      expect(bad.warnings.length, 4);
      final w = jsonDecode(ratedWithWindow('{"window":{"start":"22:00","end":"05:00"},"identifiers":{}}', s)!) as Map;
      expect(w['window'], {'start': '23:00', 'end': '04:30'});
      final dir = Directory.systemTemp.createTempSync('atvset');
      expect(Settings.load(dir.path).tuners, 4);
      expect(File('${dir.path}/settings.txt').readAsStringSync(), Settings.defaultText);
      dir.deleteSync(recursive: true);
    });
  });

  test('engine: blockOnly entries air only in their time block; a saved day from another channel is remade', () async {
    final dir = Directory.systemTemp.createTempSync('atvblk');
    addTearDown(() => dir.deleteSync(recursive: true));
    final config = parseChannelConfig('{"channels":[{"number":61,"name":"Maple","sources":[{"query":"a"},'
        '{"query":"b","blockOnly":true}],"timeBlocks":[{"label":"Hockey Night","days":["mon"],"start":"15:00",'
        '"end":"17:30","sources":[1]}]}]}');
    final c = config.channels.single;
    Entry e(String id, double s, int src) => Entry(id: '$id/$id.mp4', itemId: id, file: '$id.mp4', title: id, durationSeconds: s, url: 'http://x/$id.mp4', source: src);
    final pool = [for (var i = 0; i < 100; i++) e('show$i', 1800, 0), for (var i = 0; i < 20; i++) e('game$i', 9000, 1)];
    PoolStore(Directory('${dir.path}/pools')).save(61, pool);
    // a foreign day file under 61 (old channel's commercials after a renumber): must not air
    final junk = [for (var i = 0; i < 50; i++) e('ad$i', 60, 0)];
    SnapshotStore(Directory('${dir.path}/days')).day(61, DateTime(2026, 11, 17), junk);
    final engine = Engine(config, _NoApi(), dir);
    await engine.ensurePool(c);
    final mon = engine.guideFor(c, DateTime(2026, 11, 16), hours: 24);
    for (final s in mon.where((s) => s.entry.id.startsWith('game'))) {
      expect(s.start.hour * 60 + s.start.minute, inInclusiveRange(15 * 60, 17 * 60 + 30), reason: '${s.entry.id} at ${s.start}');
    }
    expect(mon.where((s) => s.entry.id.startsWith('game')), isNotEmpty);
    final tue = engine.guideFor(c, DateTime(2026, 11, 17), hours: 24);
    expect(tue.where((s) => s.entry.id.startsWith('game')), isEmpty);
    expect(tue.where((s) => s.entry.id.startsWith('ad')), isEmpty);
  });

  group('guide/weather music, weather channel', () {
    Entry track(String name, double s, [String item = 'smooth-jazz-fm-1991']) => Entry(
        id: '$item/$name.mp3', itemId: item, file: '$name.mp3', title: name, durationSeconds: s, url: "https://archive.org/download/$item/$name.mp3");
    final pool = [
      track('A', 1800),
      track('B', 3600),
      track("Joe's C", 2700),
      track('tiny', 30), // too short
      track('huge', 5 * 3600), // too long
    ];

    test('track order: sensible lengths, stable shuffle, clock rotation', () {
      final o = musicOrder(pool);
      expect(o.map((e) => e.file).toSet(), {'A.mp3', 'B.mp3', "Joe's C.mp3"});
      expect(musicOrder(pool.reversed.toList()).map((e) => e.id), o.map((e) => e.id)); // input order does not matter
      // back to back since the epoch: 8100 s cycle
      final cycle = DateTime.fromMillisecondsSinceEpoch(8100 * 1000 * 1000);
      expect(musicIndexAt(o, cycle), 0);
      expect(musicIndexAt(o, cycle.add(Duration(seconds: o[0].durationSeconds.round() - 1))), 0);
      expect(musicIndexAt(o, cycle.add(Duration(seconds: o[0].durationSeconds.round() + 1))), 1);
      expect(musicIndexAt(o, cycle.add(const Duration(seconds: 8099))), 2);
      expect(musicIndexAt(const [], cycle), 0);
    });

    test('playlist, fades and decoder arguments', () {
      final o = musicOrder(pool);
      final p = musicPlaylist(o, 1);
      final files = RegExp(r"^file '(.*)'$", multiLine: true).allMatches(p).map((m) => m[1]).toList();
      expect(p, startsWith('ffconcat version 1.0\n'));
      expect(files.length, 3);
      expect(files.first, o[1].url.replaceAll("'", r"'\''"));
      expect(p, contains(r"Joe'\''s C.mp3"));
      expect('option rw_timeout 10000000'.allMatches(p).length, 3);
      final f = musicFilter(o, 1);
      final b1 = o[1].durationSeconds, b2 = b1 + o[2].durationSeconds;
      expect(f, "aresample=44100,dynaudnorm=f=500:g=31:p=0.7:m=8,volume='0.5*if(isnan(t),1,"
          "min(1,abs(t-${b1.toStringAsFixed(2)}))*min(1,abs(t-${b2.toStringAsFixed(2)})))':eval=frame");
      expect(musicFilter([o.first], 0), contains("volume='0.5':eval=frame"));
      final a = musicDecoderArgs('/t/m.ffconcat', f);
      expect(a.sublist(a.indexOf('-f'), a.indexOf('-i') + 2), ['-f', 'concat', '-safe', '0', '-protocol_whitelist', 'file,http,https,tcp,tls,crypto', '-i', '/t/m.ffconcat']);
      expect(a.sublist(a.length - 7), ['-f', 's16le', '-ar', '44100', '-ac', '2', 'pipe:1']);
      expect(a, containsAllInOrder(['-vn', '-af', f]));
    });

    test('feed: silence while the decoder has nothing, music sample-aligned, decoder failure = silence', () async {
      final o = musicOrder(pool);
      final logs = <String>[];
      final dir = Directory.systemTemp.createTempSync('atvmusic');
      addTearDown(() => dir.deleteSync(recursive: true));
      final procs = <FakeProcess>[];
      final feed = MusicFeed(o,
          ffmpeg: 'ffmpeg',
          playlist: File('${dir.path}/m.ffconcat'),
          spawn: (exe, args) async {
            expect(args, contains('${dir.path}/m.ffconcat'));
            return (procs..add(FakeProcess(String.fromCharCodes(List.filled(10, 7)), '', 0))).last;
          },
          lead: 0.1,
          log: logs.add);
      expect(feed.take(8), List.filled(8, 0)); // nothing buffered: silence
      final out = _Sink();
      final served = feed.serve(out, tick: const Duration(milliseconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      feed.stop();
      await served;
      expect(File('${dir.path}/m.ffconcat').readAsStringSync(), startsWith('ffconcat'));
      expect(out.bytes.length % 4, 0);
      expect(out.bytes.length, greaterThanOrEqualTo((0.1 * 44100).floor() * 4)); // the lead went out at once
      // 10 decoded bytes: 8 played (two whole samples), 2 wait for the rest of their sample
      expect(out.bytes.where((b) => b == 7).length, 8);
      expect(logs.first, startsWith('music: '));
      // a decoder that can't start: silence and a log line, no throw
      final bad = MusicFeed(o, ffmpeg: 'ffmpeg', playlist: File('${dir.path}/b.ffconcat'), spawn: (e, a) => throw const ProcessException('ffmpeg', [], 'missing'), log: logs.add);
      final out2 = _Sink();
      final s2 = bad.serve(out2, tick: const Duration(milliseconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      bad.stop();
      await s2;
      expect(out2.bytes.every((b) => b == 0), true);
      expect(out2.bytes, isNotEmpty);
      expect(logs.last, contains('decoder did not start'));
    });

    test('library: saved list loads, a failed build keeps it, nothing at all = silent', () async {
      final dir = Directory.systemTemp.createTempSync('atvlib');
      addTearDown(() => dir.deleteSync(recursive: true));
      final config = parseChannelConfig('{"channels":[{"number":41,"name":"Cumulus","type":"weatherstar",'
          '"sources":[{"identifiers":["smooth-jazz-fm-1991"],"mediatype":"audio","ignoreYear":true}]}]}');
      final cumulus = config.channels.single;
      final logs = <String>[];
      final empty = MusicLibrary(cumulus, config, _NoApi(), dir, log: logs.add);
      expect(empty.order, isEmpty);
      await empty.refresh(); // _NoApi throws: logged, still silent
      expect(empty.order, isEmpty);
      expect(logs.last, contains('stay silent'));
      PoolStore(Directory('${dir.path}/music')).save(41, pool, builtAt: DateTime.now().subtract(const Duration(days: 2)));
      final lib = MusicLibrary(cumulus, config, _NoApi(), dir, log: logs.add);
      expect(lib.order.length, 3);
      await lib.refresh(); // stale: tries, fails, keeps the saved list
      expect((lib.order.length, logs.last.contains('keeping the saved list')), (3, true));
      expect(MusicLibrary(null, config, _NoApi(), dir).order, isEmpty);
    });

    test('weather channel in the lineup and XMLTV; settings keys', () {
      const cumulus = Channel(number: 41, name: 'Cumulus', genre: 'News & Docs', type: 'weatherstar', logo: 'Logos/4x3/cumulus.png');
      final slots = weatherChannelSlots(DateTime(2026, 11, 12, 19, 40), 2);
      expect(slots.first.start, DateTime(2026, 11, 12, 19));
      final xml = buildXmltv('http://h', [(channel: cumulus, slots: slots, rated: (_) => false)]);
      expect('<title lang="en">Local Weather</title>'.allMatches(xml).length, 2);
      expect(xml, contains('Local weather: current conditions'));
      expect(xml, contains('<category lang="en">News &amp; Docs</category>'));
      expect(logoPath('/c', cumulus), '/c/logos/cumulus.png');
      final d = Settings.parse(Settings.defaultText);
      expect((d.guideMusic, d.weatherChannel, d.weatherMusic, d.weatherName, d.weatherLat, d.weatherLon, d.weatherImperial),
          (true, true, true, 'Hattiesburg, MS', 31.3271, -89.2903, true));
      expect(d.warnings, isEmpty);
      final s = Settings.parse('guide_music = off\nweather_channel = no\nweather_location = Oxford, MS; 34.3665,-89.5192\nweather_units = Metric');
      expect((s.guideMusic, s.weatherChannel, s.weatherName, s.weatherLat, s.weatherLon, s.weatherImperial),
          (false, false, 'Oxford, MS', 34.3665, -89.5192, false));
      final bad = Settings.parse('weather_location = Oxford\nweather_units = kelvin\nguide_music = loud');
      expect((bad.weatherName, bad.weatherImperial, bad.guideMusic, bad.warnings.length), ('Hattiesburg, MS', true, true, 3));
      expect(Settings.parse('weather_location = North Pole; 95, 0').warnings.single, contains('weather_location'));
    });
  });
}

/// Collects what a [MusicFeed] serves.
class _Sink implements IOSink {
  final bytes = <int>[];
  @override
  void add(List<int> data) => bytes.addAll(data);
  @override
  Future<void> flush() async {}
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _NoApi implements ArchiveApi {
  @override
  Future<List<ItemSummary>> search(String query, {int rows = 100, int page = 1}) => throw UnimplementedError();
  @override
  Future<ItemMeta?> metadata(String identifier) => throw UnimplementedError();
}

String? _logo(Channel c) => '/l.png';

/// OverlayParams for channel 7 with the test logo/watermark.
class OverlayParamsForTest {
  final bool mature;
  final String? message;
  const OverlayParamsForTest({this.mature = false, this.message});
  get params => ov.OverlayParams(
      number: 7, name: 'Capes', logoPath: '/l.png', watermarkPath: '/w.png', mature: mature, message: message);
}
