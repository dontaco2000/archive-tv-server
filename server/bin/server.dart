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
import 'package:archivetv_server/thumbs.dart';
import 'package:archivetv_server/titles.dart';
import 'package:archivetv_server/xmltv.dart';
import 'package:guidechannel/guidechannel.dart' show Place, WeatherFeed;
import 'package:http/http.dart' as http;

void log(String m) => stdout.writeln('${DateTime.now().toIso8601String().substring(0, 19)} $m');

/// archivetv-server [--port 8100] [--config dir] [--data dir] [--ffmpeg path] [--tuners 4] [--font ttf] [--no-refresh]
Future<void> main(List<String> args) async {
  String opt(String name, String def) {
    final i = args.indexOf('--$name');
    return i >= 0 && i + 1 < args.length ? args[i + 1] : def;
  }

  final port = int.parse(opt('port', '8100'));
  final configDir = opt('config', '/opt/archivetv-server/config');
  final dataDir = Directory(opt('data', '/opt/archivetv-server/data'))..createSync(recursive: true);
  final settings = Settings.load(configDir, defaultTuners: int.parse(opt('tuners', '4')), log: log);
  for (final w in settings.warnings) {
    log('settings: $w');
  }
  log('settings: $settings');
  final tuners = settings.tuners;

  final ratedFile = File('$configDir/rated.json');
  final config = parseChannelConfig(File('$configDir/channels.json').readAsStringSync(),
      ratedText: ratedWithWindow(ratedFile.existsSync() ? ratedFile.readAsStringSync() : null, settings));
  final archive = ArchiveClient(userAgent: 'ArchiveTV-Server/0.1 (personal retro TV tuner)');
  itemInfos = ItemInfoStore(File('${dataDir.path}/item_info.json'), fetch: archive.itemInfos, log: log);
  try {
    // Only with both the map and the new-numbered channels.json deployed; a map beside the old config would
    // move pools under numbers the config doesn't use (and layout_version would block a later fix).
    final m = File('$configDir/renumber_map.json');
    if (m.existsSync() && File('$configDir/channels.json').existsSync()) {
      final moved = migrateLayout(dataDir, m.readAsStringSync());
      log(moved ?? 'layout migration: nothing to do');
    } else {
      log('layout migration: skipped (needs renumber_map.json and channels.json in $configDir)');
    }
  } on Object catch (e) {
    log('layout migration: $e');
  }
  final engine = Engine(config, archive, dataDir, log: log)
    ..adultMode = settings.lateNightAdultMode;

  // Item titles/descriptions for the guides, looked up in the background (2 batches at a time, once per item).
  Future<void> enrichTitles() async {
    try {
      final n = await itemInfos!.enrich([for (final c in engine.channels) ...engine.poolOf(c)], all: true);
      if (n > 0) engine.version++;
      log('titles: $n new item records');
    } on Object catch (e) {
      log('titles: lookup failed: $e');
    }
  }
  String? logoFile(Channel c) {
    final f = File(logoPath(configDir, c));
    return f.existsSync() ? f.path : null;
  }

  final wm = File('$configDir/wm_native3_50.png'), wmR = File('$configDir/wm_native3_50_R.png');
  final guideCh = settings.guideChannel ? guideChannel : null;
  // The weather channel of channels.json (Cumulus): its sources are also the guide's music.
  final weatherConfig = config.channels.where((c) => c.type == 'weatherstar').firstOrNull;
  final weatherCh = settings.weatherChannel ? weatherConfig : null;
  final lineup = [...engine.channels, if (weatherCh != null) weatherCh, if (guideCh != null) guideCh]
    ..sort((a, b) => a.number.compareTo(b.number));
  final music = MusicLibrary(weatherConfig, config, archive, dataDir, log: log);
  final weatherFeed = weatherCh == null
      ? null
      : WeatherFeed(Place(settings.weatherName, settings.weatherLat, settings.weatherLon),
          imperial: settings.weatherImperial, cacheFile: File('${dataDir.path}/weather.json'), log: log);
  final streamer = Streamer(
    schedule: engine,
    ffmpeg: opt('ffmpeg', '/opt/archivetv-server/bin/ffmpeg'),
    selfBase: 'http://127.0.0.1:$port',
    tmpDir: Directory('${dataDir.path}/tmp'),
    maxTuners: tuners,
    font: opt('font', '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'),
    overlays: settings.overlays
        ? Overlays(
            logo: logoFile,
            watermark: settings.watermark && wm.existsSync() ? wm.path : null,
            watermarkRated: settings.watermark && settings.ratedWatermark && wmR.existsSync() ? wmR.path : null,
            watermarkLabel: settings.watermark && settings.watermarkLabel,
            tuneBanner: settings.tuneBanner,
            tuneBannerSeconds: settings.tuneBannerSeconds,
            cornerBug: settings.cornerBug,
            discretionCard: settings.discretionCard,
            discretionStrip: settings.discretionStrip,
            lateNightNotice: settings.lateNightNotice,
          )
        : null,
    guideSnapshot: guideCh == null ? null : () => guideSnapshot(engine, DateTime.now(), logo: logoFile),
    weather: weatherFeed == null ? null : (feed: weatherFeed, logo: logoFile(weatherCh!)),
    music: (c) => (c.number == guideNumber ? settings.guideMusic : settings.weatherMusic) ? music.order : const [],
    log: log,
  );
  final byNumber = {for (final c in lineup) c.number: c};
  final thumbs = Thumbs(dataDir, channel: (n) => byNumber[n], logoFile: logoFile, log: log);

  // guide.xml is cached; remade when pools change or every 30 min (Plex reads it a few times a day).
  String? guideXml;
  var guideVersion = -1;
  var guideAt = DateTime(0);
  var guideBase = '';
  String guideFor(String base) {
    final now = DateTime.now();
    if (guideXml != null && guideBase == base && guideVersion == engine.version && now.difference(guideAt) < const Duration(minutes: 30)) return guideXml!;
    final sw = Stopwatch()..start();
    final from = now.subtract(const Duration(hours: 2));
    guideXml = buildXmltv(base, [
      for (final c in engine.channels)
        if (engine.statusOf(c) == PoolStatus.ready)
          (
            channel: c,
            slots: guideSlots(engine, c, from, 7 * 24 + 2),
            rated: (e) => engine.isRated(c, e),
          ),
      if (weatherCh != null) (channel: weatherCh, slots: weatherChannelSlots(from, 7 * 24 + 2), rated: (_) => false),
      if (guideCh != null) (channel: guideCh, slots: guideChannelSlots(from, 7 * 24 + 2), rated: (_) => false),
    ],
        channelIconBase: settings.channelIconBase,
        icon: !settings.programmeThumbs
            ? null
            : settings.programmeThumbsDirect
                ? (c, e) => thumbs.directIcon(e.itemId)
                : serverIcon(base));
    (guideVersion, guideAt, guideBase) = (engine.version, now, base);
    log('guide.xml built in ${sw.elapsedMilliseconds} ms (${guideXml!.length ~/ 1024} KB)');
    return guideXml!;
  }

  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  server.autoCompress = false;
  log('Archive TV Server on :$port, ${engine.channels.length} channels, $tuners tuners');

  server.listen((req) async {
    final res = req.response;
    final path = req.uri.path;
    final base = 'http://${req.headers.host ?? '127.0.0.1'}:${req.headers.port ?? port}';
    try {
      void send(String body, String type) {
        res.headers.contentType = ContentType.parse(type);
        res.write(body);
      }

      if (await thumbs.serve(req)) {
        // /cards/<n>.png, /cards/<n>-wide.png, /thumb/<n>/<item>.jpg
      } else if (path == '/discover.json' || path == '/discover') {
        send(discoverJson(base, tuners), 'application/json');
      } else if (path == '/lineup.json') {
        send(lineupJson(base, lineup), 'application/json');
      } else if (path == '/lineup_status.json') {
        send(lineupStatusJson(), 'application/json');
      } else if (path == '/lineup.post') {
        // scan request: the lineup is static
      } else if (path == '/device.xml' || path == '/') {
        send(deviceXml(base), 'application/xml');
      } else if (path == '/guide.xml' || path == '/xmltv.xml') {
        send(guideFor(base), 'application/xml; charset=utf-8');
      } else if (path == '/status') {
        send(
            const JsonEncoder.withIndent(' ').convert({
              'tuners': tuners,
              'sessions': {for (final s in streamer.sessions.values) '${s.channel.number}': s.viewers},
              'ready': engine.channels.where((c) => engine.statusOf(c) == PoolStatus.ready).length,
              'building': [for (final c in engine.channels) if (engine.statusOf(c) == PoolStatus.building) c.number],
              'failed': [for (final c in engine.channels) if (engine.statusOf(c) == PoolStatus.failed) c.number],
              'deadLinks': engine.deadLinks,
            }),
            'application/json');
      } else if (RegExp(r'^/logos/(\d+)\.png$').firstMatch(path) case final m?) {
        final c = byNumber[int.parse(m.group(1)!)];
        final f = File(c == null ? '' : logoPath(configDir, c));
        if (c == null || !f.existsSync()) {
          res.statusCode = 404;
        } else {
          res.headers.contentType = ContentType('image', 'png');
          await res.addStream(f.openRead());
        }
      } else if (RegExp(r'^/(?:auto/v|stream/)(\d+)$').firstMatch(path) case final m?) {
        final c = byNumber[int.parse(m.group(1)!)];
        if (c == null) {
          res.statusCode = 404;
        } else {
          final s = await streamer.join(c);
          if (s == null) {
            res.statusCode = 503;
            res.headers.set('X-HDHomeRun-Error', '805 All Tuners In Use');
            res.write('tuner busy');
          } else {
            log('ch${c.number}: viewer ${req.connectionInfo?.remoteAddress.address} joined (${s.viewers + 1})');
            res.headers.contentType = ContentType('video', 'mp2t');
            res.bufferOutput = false;
            if (req.method == 'HEAD') {
              await res.close();
              return;
            }
            await s.watch(res);
            log('ch${c.number}: viewer left (${s.viewers})');
            return;
          }
        }
      } else if (RegExp(r'^/internal/music/(\d+)$').firstMatch(path) case final m?) {
        final s = streamer.byGen(int.parse(m.group(1)!), int.tryParse(req.uri.queryParameters['g'] ?? '') ?? -1);
        if (s == null) {
          res.statusCode = 410;
        } else {
          res.headers.contentType = ContentType('audio', 'L16');
          res.bufferOutput = false;
          await s.serveMusic(res);
          return;
        }
      } else if (RegExp(r'^/internal/item/(\d+)$').firstMatch(path) case final m?) {
        final s = streamer.byGen(int.parse(m.group(1)!), int.tryParse(req.uri.queryParameters['g'] ?? '') ?? -1);
        if (s == null) {
          res.statusCode = 410;
        } else {
          res.headers.contentType = ContentType('video', 'mp2t');
          res.bufferOutput = false;
          await s.serveItem(res);
          return;
        }
      } else {
        res.statusCode = 404;
      }
    } on Object catch (e, st) {
      log('request $path failed: $e\n$st');
      res.statusCode = 500;
    }
    await res.close().catchError((_) {});
  });

  ProcessSignal.sigterm.watch().listen((_) {
    streamer.stopAll();
    exit(0);
  });

  if (args.contains('--no-refresh')) return;
  if (!args.contains('--load-only')) unawaited(music.refresh());
  unawaited(() async {
    // Saved pools load at once (old ones stay on air); missing ones build, one channel at a time.
    for (final c in engine.channels) {
      await engine.ensurePool(c);
      engine.planWeek(c, DateTime.now());
    }
    log('pools loaded: ${engine.channels.where((c) => engine.statusOf(c) == PoolStatus.ready).length} ready');
    if (settings.programmeThumbs && settings.programmeThumbsDirect) {
      // check the guide window's thumbnails in the background, soonest first (guide builds never wait)
      final from = DateTime.now().subtract(const Duration(hours: 2));
      final slots = [
        for (final c in engine.channels)
          if (engine.statusOf(c) == PoolStatus.ready) ...guideSlots(engine, c, from, 7 * 24 + 2)
      ]..sort((a, b) => a.start.compareTo(b.start));
      for (final s in slots) {
        thumbs.check(s.entry.itemId);
      }
      log('thumbs: ${thumbs.pending} thumbnail checks queued');
    }
    unawaited(enrichTitles());
    if (args.contains('--load-only')) return; // staging/testing: no rebuilds
    while (true) {
      await engine.dailyRefresh(DateTime.now());
      unawaited(enrichTitles());
      unawaited(music.refresh());
      final now = DateTime.now();
      final midnight = DateTime(now.year, now.month, now.day + 1, 0, 1);
      await Future<void>.delayed(midnight.difference(now));
    }
  }());

  // Dead-link checker, as the Windows app runs it: a full pass every 12 h, second strikes in between.
  if (!args.contains('--load-only')) unawaited(() async {
    await Future<void>.delayed(const Duration(minutes: 5));
    final client = http.Client();
    var lastFull = DateTime(0);
    while (true) {
      final now = DateTime.now();
      final full = now.difference(lastFull) >= const Duration(hours: 12);
      if (full || engine.health.hasDue(now)) {
        if (full) lastFull = now;
        try {
          final checker = DeadLinkChecker(client, engine.health, concurrency: 2, delay: const Duration(milliseconds: 500), log: log);
          final n = await engine.checkLinks(now, checker, hours: 12, onlyStruck: !full);
          log('link check ${full ? 'pass' : 'recheck'} done: $n new dead, ${engine.deadLinks} in all');
        } on Object catch (e) {
          log('link check failed: $e');
        }
      }
      await Future<void>.delayed(const Duration(minutes: 10));
    }
  }());
}
