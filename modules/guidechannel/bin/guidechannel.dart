import 'dart:async';
import 'dart:io';

import 'package:guidechannel/guidechannel.dart';
import 'package:image/image.dart' as img;

const usage = '''
usage: guidechannel --snapshot snap.json [options]
       guidechannel --weather "Hattiesburg, MS;31.3271,-89.2903" [--metric] [--logo PNG] [options]
  --out FILE|stdout     MPEG-TS destination (default stdout)
  --fps N               frame rate (default 15)
  --duration SECONDS    stop after N seconds (default: run forever)
  --fast                render as fast as possible (clips/benchmarks), clock advances with frames
  --start ISO8601       clock time of the first frame (with --fast; default now)
  --refresh SECONDS     re-read the snapshot file this often without restarting (default 60)
  --ffmpeg PATH         ffmpeg binary (default ffmpeg)
  --preset NAME         x264 preset (default veryfast)
  --png DIR             instead of video: write PNG stills at --shots seconds (comma list)
  --shots LIST          seconds for --png (default 0,3,7.5,8,15,40,70)
''';

Future<void> main(List<String> args) async {
  final o = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (!a.startsWith('--')) _die('unexpected $a');
    final k = a.substring(2);
    if (k == 'fast' || k == 'metric') {
      o[k] = '1';
    } else if (i + 1 < args.length) {
      o[k] = args[++i];
    } else {
      _die('missing value for $a');
    }
  }
  final start = o['start'] == null ? DateTime.now() : DateTime.parse(o['start']!);
  WeatherRenderer? weather;
  if (o['weather'] case final spec?) {
    final m = RegExp(r'^(.*);\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)$').firstMatch(spec) ?? _die('--weather "Name;lat,lon"');
    final feed = WeatherFeed(Place(m[1]!.trim(), double.parse(m[2]!), double.parse(m[3]!)),
        imperial: o['metric'] == null, log: stderr.writeln);
    await feed.refresh();
    weather = WeatherRenderer(() => feed.current, logoPath: o['logo'], place: m[1]!.trim());
  }
  final path = weather != null ? null : o['snapshot'] ?? _die('--snapshot or --weather is required');
  Snapshot read() => Snapshot.parse(File(path!).readAsStringSync());
  final snap = weather != null ? null : read();

  if (o['png'] != null) {
    final dir = Directory(o['png']!)..createSync(recursive: true);
    final r = snap == null ? null : GuideRenderer(snap);
    for (final s in (o['shots'] ?? '0,3,7.5,8,15,40,70').split(',')) {
      final sec = double.parse(s);
      final at = start.add(Duration(milliseconds: (sec * 1000).round()));
      final f = File('${dir.path}${Platform.pathSeparator}${r == null ? 'weather' : 'guide'}-${s.replaceAll('.', '_')}s.png');
      f.writeAsBytesSync(img.encodePng(r?.frameImage(at, sec) ?? weather!.frameImage(at, sec)));
      stderr.writeln('wrote ${f.path}');
    }
    return;
  }

  final toStdout = (o['out'] ?? 'stdout') == 'stdout';
  final g = GuideChannel.frames(weather ?? GuideRenderer(snap!),
      ffmpeg: o['ffmpeg'] ?? 'ffmpeg',
      fps: int.parse(o['fps'] ?? '15'),
      preset: o['preset'] ?? 'veryfast',
      out: toStdout ? 'pipe:1' : o['out']!,
      realtime: o['fast'] == null,
      log: stderr.writeln);
  final d = o['duration'];
  await g.start(
      duration: d == null ? null : Duration(milliseconds: (double.parse(d) * 1000).round()), startTime: start);
  if (toStdout) unawaited(stdout.addStream(g.output));

  final every = int.parse(o['refresh'] ?? '60');
  final timer = Timer.periodic(Duration(seconds: every), (_) {
    if (snap == null) return;
    try {
      g.snapshot = read();
    } on Object catch (e) {
      stderr.writeln('snapshot reload failed, keeping the old one: $e');
    }
  });
  ProcessSignal.sigint.watch().listen((_) => g.stop());
  await g.done;
  timer.cancel();
  await stdout.flush();
  exit(0);
}

Never _die(String m) {
  stderr.writeln('$m\n$usage');
  exit(64);
}
