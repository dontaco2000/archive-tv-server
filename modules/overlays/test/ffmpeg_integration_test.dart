/// Real ffmpeg: renders every overlay variant, checks exit 0 and 640x480, saves PNG frames to
/// $OVERLAY_SHOTS (default: system temp). Skipped when ffmpeg or the font is missing.
/// BENCH=1 also runs the 60 s cost benchmark (prints x realtime and CPU overhead).
@Timeout(Duration(minutes: 10))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive_tv_overlays/archive_tv_overlays.dart';
import 'package:test/test.dart';

String? _find(String exe) {
  for (final p in [r'C:\ffmpeg\bin\' '$exe.exe', '/usr/bin/$exe', '/opt/archivetv-server/bin/$exe']) {
    if (File(p).existsSync()) return p;
  }
  final r = Process.runSync(Platform.isWindows ? 'where' : 'which', [exe]);
  return r.exitCode == 0 ? (r.stdout as String).trim().split(RegExp(r'\r?\n')).first : null;
}

final ffmpeg = _find('ffmpeg'), ffprobe = _find('ffprobe');
final font = [r'C:\Windows\Fonts\DejaVuSansMono-Bold.ttf', defaultFontFile]
    .map((p) => p.replaceAll(r'\', '/'))
    .firstWhere((p) => File(p).existsSync(), orElse: () => '');
final shots = Directory(Platform.environment['OVERLAY_SHOTS'] ?? '${Directory.systemTemp.path}/overlay-shots');
final work = Directory.systemTemp.createTempSync('atv_overlays_');
String fx(String f) => File('test/fixtures/$f').absolute.path;
final wm = File('assets/wm_native3_50.png').absolute.path;

const busy = 'testsrc2=s=640x480:r=30';
const bright = 'color=c=0xEEEEEE:s=640x480:r=30';
const dark = 'color=c=0x101010:s=640x480:r=30';
const fractal = 'mandelbrot=s=640x480:r=30'; // busy natural-looking detail, no test-pattern clock
const pillar = 'testsrc2=s=640x480:r=30,pad=852:480:106:0:black'; // 4:3 picture inside a 16:9 file
const window = 'testsrc2=s=560x420:r=30,pad=640:480:40:30:black'; // bars on all four sides

/// Runs a video-mode graph on a lavfi [source] for [secs]; returns the .ts path and stderr.
Future<(String, String)> renderVideo(String name, OverlayParams p, String source,
    {double secs = 8, List<(double, String)> stdinAt = const []}) async {
  final g = buildFilterGraph(p, fontFile: font);
  final out = '${work.path}/$name.ts';
  final audioIndex = 1 + g.inputArgs.length ~/ 2;
  final args = [
    '-hide_banner', '-y', if (stdinAt.isNotEmpty) '-re', //
    '-f', 'lavfi', '-i', source, ...g.inputArgs, '-f', 'lavfi', '-i', 'sine=f=440:r=44100',
    '-filter_complex', g.filterComplex, '-map', g.videoMap, '-map', '$audioIndex:a',
    '-t', '$secs', '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'aac', '-f', 'mpegts', out,
  ];
  return (out, await _run(args, stdinAt));
}

Future<String> renderCard(String name, OverlayParams p, {double secs = 3}) async {
  final g = buildFilterGraph(p, fontFile: font);
  final out = '${work.path}/$name.ts';
  final args = [
    '-hide_banner',
    '-y',
    ...g.args,
    '-t',
    '$secs',
    '-c:v',
    'libx264',
    '-preset',
    'ultrafast',
    '-c:a',
    'aac',
    '-f',
    'mpegts',
    out
  ];
  await _run(args, const []);
  return out;
}

Future<String> _run(List<String> args, List<(double, String)> stdinAt) async {
  final proc = await Process.start(ffmpeg!, args);
  final err = StringBuffer();
  final done = proc.stderr.transform(utf8.decoder).forEach(err.write);
  unawaited(proc.stdout.drain<void>());
  for (final (at, line) in stdinAt) {
    await Future<void>.delayed(Duration(milliseconds: (at * 1000).round()));
    proc.stdin.write(line);
    await proc.stdin.flush();
  }
  final code = await proc.exitCode;
  await done;
  expect(code, 0, reason: err.toString().split('\n').reversed.take(15).toList().reversed.join('\n'));
  return err.toString();
}

void expectSize(String ts) {
  final r = Process.runSync(ffprobe!,
      ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height', '-of', 'csv=p=0', ts]);
  expect((r.stdout as String).trim().split(RegExp(r'\s+')).toSet(), {'640,480'}); // MPEG-TS: program + stream rows
}

/// Saves the frame at [t] seconds as `<name>.png` in [shots].
void shot(String ts, double t, String name) {
  shots.createSync(recursive: true);
  final r = Process.runSync(ffmpeg!,
      ['-hide_banner', '-y', '-i', ts, '-ss', '$t', '-frames:v', '1', '-update', '1', '${shots.path}/$name.png']);
  expect(r.exitCode, 0, reason: r.stderr.toString());
  expect(File('${shots.path}/$name.png').existsSync(), isTrue, reason: 'no frame at $t s');
}

void main() {
  final skip = ffmpeg == null || ffprobe == null
      ? 'ffmpeg not found'
      : (font.isEmpty ? 'DejaVuSansMono-Bold.ttf not found' : false);
  const warp = 'warp.png';

  group('ffmpeg', skip: skip, () {
    test('tune banner then persistent bug (busy, bright, dark)', () async {
      for (final (src, tag) in [(busy, 'busy'), (bright, 'bright'), (dark, 'dark'), (fractal, 'fractal')]) {
        final (ts, _) = await renderVideo(
            'tune_$tag', OverlayParams(number: 12, name: 'Warp', logoPath: fx(warp), watermarkPath: wm), src);
        expectSize(ts);
        shot(ts, 2, '01_tune_banner_$tag');
        shot(ts, 7, '02_bug_after_6s_$tag');
      }
    });

    test('no logo, no watermark, long name', () async {
      final (ts, _) =
          await renderVideo('nologo', const OverlayParams(number: 34, name: 'Cablecast', watermark: false), busy);
      expectSize(ts);
      shot(ts, 2, '03_banner_no_logo');
    });

    test('late night + fresh R programme: discretion card, banner, R badge', () async {
      final (ts, _) = await renderVideo(
          'late',
          OverlayParams(
              number: 67, name: 'Nightcap', logoPath: fx('headliner.png'), watermarkPath: wm, lateNight: true),
          busy);
      expectSize(ts);
      shot(ts, 2, '04_late_night_discretion_card');
      shot(ts, 7, '05_late_night_r_badge');
    });

    test('mature joined mid-programme: strip', () async {
      final (ts, _) = await renderVideo(
          'strip',
          OverlayParams(
              number: 17,
              name: 'Headliner',
              logoPath: fx('headliner.png'),
              watermarkPath: wm,
              mature: true,
              secondsIntoProgramme: 900),
          busy);
      expectSize(ts);
      shot(ts, 2, '06_mature_strip');
    });

    test('cards: STAND BY dots, BUILDING, build mode, NO SIGNAL, OFF AIR', () async {
      final ts = await renderCard(
          'standby',
          OverlayParams(
              number: 12, name: 'Warp', logoPath: fx(warp), watermarkPath: wm, message: standBy, lateNight: true));
      expectSize(ts);
      shot(ts, 0.2, '07_standby_dot1');
      shot(ts, 0.65, '07_standby_dot2');
      shot(ts, 1.1, '07_standby_dot3');
      for (final (m, n) in [
        (building, '08_building'),
        (buildModeNotice, '09_build_mode'),
        (noSignal, '10_no_signal'),
        (offAir, '11_off_air')
      ]) {
        final t = await renderCard(
            n, OverlayParams(number: 12, name: 'Warp', logoPath: fx(warp), watermarkPath: wm, message: m));
        expectSize(t);
        shot(t, 1, n);
      }
      final t = await renderCard('nologo_card', const OverlayParams(number: 30, name: 'Dispatch', message: standBy));
      shot(t, 0.2, '12_standby_no_logo');
    });

    test('crop: pillarboxed 16:9 file and windowboxed picture fill 640x480', () async {
      for (final (src, rect, n) in [
        (pillar, const CropRect(106, 0, 640, 480), 'pillar'),
        (window, const CropRect(40, 30, 560, 420), 'window')
      ]) {
        final (raw, _) = await renderVideo(
            '${n}_raw', const OverlayParams(number: 1, name: 'A', secondsSinceTune: 99), src,
            secs: 2);
        shot(raw, 1, '13_crop_${n}_before');
        final (ts, _) =
            await renderVideo(n, OverlayParams(number: 1, name: 'A', secondsSinceTune: 99, crop: rect), src, secs: 2);
        expectSize(ts);
        shot(ts, 1, '14_crop_${n}_after');
      }
    });

    test('cropProbeArgs + CropDecider decide the pillarbox crop of a real file', () async {
      final file = '${work.path}/pillar.mp4';
      expect(
          Process.runSync(ffmpeg!, [
            '-y',
            '-f',
            'lavfi',
            '-i',
            pillar,
            '-t',
            '10',
            '-c:v',
            'libx264',
            '-preset',
            'ultrafast',
            file
          ]).exitCode,
          0);
      final sw = Stopwatch()..start();
      final r = await Process.run(ffmpeg!, cropProbeArgs(file, 2));
      expect(r.exitCode, 0, reason: r.stderr.toString());
      final d = CropDecider(852, 480);
      CropRect? got;
      for (final l in const LineSplitter().convert(r.stderr.toString().replaceAll('\r', '\n'))) {
        got = d.add(l) ?? got;
      }
      expect(got, const CropRect(106, 0, 640, 480));
      print('crop probe (7 s of 852x480 h264, local file): ${sw.elapsedMilliseconds} ms');
    });

    test('stdin command: tune banner re-trigger in a running ffmpeg', () async {
      final (ts, _) = await renderVideo('retrigger',
          OverlayParams(number: 12, name: 'Warp', logoPath: fx(warp), watermarkPath: wm, secondsSinceTune: 600), busy,
          secs: 9, stdinAt: [(1.0, tuneBannerCommands(3, lateNight: true).join())]);
      expectSize(ts);
      shot(ts, 2, '15_retrigger_before');
      shot(ts, 5, '16_retrigger_after');
    });

    test('benchmark 60 s', skip: Platform.environment['BENCH'] == null ? 'set BENCH=1' : false, () async {
      // A 60 s h264 640x480 source, then encode it like the server (x264 veryfast) with/without overlays.
      final src = '${work.path}/src.mp4';
      expect(
          Process.runSync(ffmpeg!, [
            '-y',
            '-f',
            'lavfi',
            '-i',
            '$busy,noise=alls=20:allf=t',
            '-f',
            'lavfi',
            '-i',
            'sine',
            '-t',
            '60',
            '-c:v',
            'libx264',
            '-preset',
            'veryfast',
            '-c:a',
            'aac',
            '-shortest',
            src
          ]).exitCode,
          0);
      final plainVf = '[0:v]scale=640:480:flags=bilinear,pad=640:480:(ow-iw)/2:(oh-ih)/2,setsar=1[vout]';
      final full = buildFilterGraph(
          OverlayParams(number: 12, name: 'Warp', logoPath: fx(warp), watermarkPath: wm, lateNight: true),
          fontFile: font);
      // One thread everywhere: CPU seconds ~= wall seconds, comparable with one FX-4300 core.
      Future<(double, double)> bench(List<String> extraIn, String graph, {bool encode = true}) async {
        final best = <(double, double)>[];
        for (var i = 0; i < 3; i++) {
          final r = await Process.run(ffmpeg!, [
            '-hide_banner',
            '-benchmark',
            '-threads',
            '1',
            '-filter_threads',
            '1',
            '-filter_complex_threads',
            '1',
            '-i',
            src,
            ...extraIn,
            '-filter_complex',
            graph,
            '-map',
            '[vout]',
            '-map',
            '0:a',
            ...(encode
                ? [
                    '-c:v',
                    'libx264',
                    '-preset',
                    'veryfast',
                    '-threads',
                    '1',
                    '-c:a',
                    'aac',
                    '-f',
                    'mpegts',
                    '-y',
                    '${work.path}/b.ts'
                  ]
                : ['-f', 'null', '-'])
          ]);
          final m = RegExp(r'utime=([\d.]+)s stime=([\d.]+)s rtime=([\d.]+)s').firstMatch(r.stderr as String)!;
          best.add((double.parse(m[1]!) + double.parse(m[2]!), double.parse(m[3]!)));
        }
        best.sort((a, b) => a.$1.compareTo(b.$1));
        return best.first;
      }

      for (final encode in [false, true]) {
        final (cpu0, wall0) = await bench([], plainVf, encode: encode);
        final (cpu1, wall1) = await bench(full.inputArgs, full.filterComplex, encode: encode);
        final what = encode ? 'decode+filters+x264 veryfast+aac' : 'decode+filters only';
        print('$what, 1 thread: plain ${cpu0.toStringAsFixed(2)} s cpu (${(60 / wall0).toStringAsFixed(1)}x realtime), '
            'overlays ${cpu1.toStringAsFixed(2)} s cpu (${(60 / wall1).toStringAsFixed(1)}x realtime), '
            'overhead ${(cpu1 - cpu0).toStringAsFixed(2)} s = ${((cpu1 / cpu0 - 1) * 100).toStringAsFixed(1)}%');
      }
    });
  });
}
