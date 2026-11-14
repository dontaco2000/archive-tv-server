import 'dart:async';
import 'dart:io';

import 'renderer.dart';
import 'snapshot.dart';

/// The guide channel as a live MPEG-TS stream: Dart draws yuv420p frames at a constant [fps] into
/// ffmpeg's stdin, ffmpeg adds the audio ([audioInput]: silence by default) and encodes h264/aac MPEG-TS
/// (640x480 4:3). [GuideChannel.frames] streams any other [FrameSource] (the weather channel).
///
/// ```dart
/// final g = GuideChannel(snapshot);
/// await g.start();                       // MPEG-TS on g.output
/// g.output.pipe(httpResponse);           // or fan out to several viewers
/// g.snapshot = newSnapshot;              // any time: no restart, next frame uses it
/// await g.stop();
/// ```
class GuideChannel {
  final FrameSource source;

  /// The listings renderer (only for a channel made with the default constructor).
  GuideRenderer get renderer => source as GuideRenderer;
  final String ffmpeg;
  final int fps;

  /// x264 preset and rate cap; the guide is mostly still, so this is cheap.
  final String preset;
  final String maxrate;

  /// Where ffmpeg writes: 'pipe:1' (default, read [output]) or a file path.
  final String out;

  /// Pace frames to the wall clock (live). false = as fast as possible (benchmarks/clips);
  /// the drawn clock then advances at the frame rate from the start time.
  final bool realtime;

  /// Called with ffmpeg's stderr lines.
  final void Function(String)? log;

  /// Live mode: seconds of frames sent at once at the start (they show the clock from [lead] s ago), so a
  /// viewer's player gets a buffer instead of starting at exactly real time (Plex stutters otherwise).
  final double lead;

  /// ffmpeg input arguments of the audio track (input 1), e.g. raw PCM from a URL. Default: silence.
  final List<String> audioInput;

  static const silence = ['-f', 'lavfi', '-i', 'anullsrc=r=44100:cl=stereo'];

  GuideChannel(Snapshot snapshot,
      {String ffmpeg = 'ffmpeg',
      int fps = 15,
      String preset = 'veryfast',
      String maxrate = '1500k',
      String out = 'pipe:1',
      bool realtime = true,
      void Function(String)? log,
      double lead = 0,
      List<String> audioInput = silence,
      double hold = 7,
      double scroll = 1})
      : this.frames(GuideRenderer(snapshot, hold: hold, scroll: scroll),
            ffmpeg: ffmpeg,
            fps: fps,
            preset: preset,
            maxrate: maxrate,
            out: out,
            realtime: realtime,
            log: log,
            lead: lead,
            audioInput: audioInput);

  GuideChannel.frames(this.source,
      {this.ffmpeg = 'ffmpeg',
      this.fps = 15,
      this.preset = 'veryfast',
      this.maxrate = '1500k',
      this.out = 'pipe:1',
      this.realtime = true,
      this.log,
      this.lead = 0,
      this.audioInput = silence});

  Process? _p;
  bool _stopping = false;
  final _done = Completer<void>();

  /// MPEG-TS bytes (when [out] is 'pipe:1'). Valid after [start].
  Stream<List<int>> get output => _p!.stdout;

  /// Completes when the stream ends (duration reached, [stop], or ffmpeg died).
  Future<void> get done => _done.future;

  set snapshot(Snapshot s) => renderer.snapshot = s;

  List<String> ffmpegArgs() => [
        '-hide_banner',
        '-loglevel',
        'error',
        '-nostdin',
        '-f',
        'rawvideo',
        '-pix_fmt',
        'yuv420p',
        '-s',
        '640x480',
        '-r',
        '$fps',
        '-i',
        'pipe:0',
        ...audioInput,
        '-map',
        '0:v',
        '-map',
        '1:a',
        '-shortest',
        // -shortest queues up to 10 s by default before muxing: a live stream would stall that long at start
        '-shortest_buf_duration',
        '0.5',
        '-c:v',
        'libx264',
        '-preset',
        preset,
        '-tune',
        'stillimage',
        '-profile:v',
        'main',
        '-pix_fmt',
        'yuv420p',
        '-g',
        '${fps * 2}',
        '-crf',
        '23',
        '-maxrate',
        maxrate,
        '-bufsize',
        '3000k',
        '-aspect',
        '4:3',
        '-c:a',
        'aac',
        '-b:a',
        '64k',
        '-ar',
        '44100',
        '-ac',
        '2',
        '-f',
        'mpegts',
        '-y',
        out,
      ];

  /// Starts ffmpeg and the frame loop. [duration] null = forever (until [stop]).
  Future<void> start({Duration? duration, DateTime? startTime}) async {
    final p = _p = await Process.start(ffmpeg, ffmpegArgs());
    p.stderr.transform(const SystemEncoding().decoder).listen((s) => log?.call(s.trimRight()));
    p.stdin.done.catchError((_) {}); // a viewer leaving / ffmpeg exiting is not an error here
    unawaited(_loop(p, duration, startTime ?? DateTime.now()));
  }

  Future<void> _loop(Process p, Duration? duration, DateTime t0) async {
    final clock = Stopwatch()..start();
    if (realtime && lead > 0) t0 = t0.subtract(Duration(milliseconds: (lead * 1000).round()));
    final total = duration == null ? null : duration.inMilliseconds * fps ~/ 1000;
    try {
      for (var i = 0; !_stopping && (total == null || i < total); i++) {
        final sec = i / fps;
        final now = realtime && lead <= 0 ? DateTime.now() : t0.add(Duration(microseconds: (sec * 1e6).round()));
        p.stdin.add(source.frameYuv(now, sec));
        await p.stdin.flush(); // backpressure: never queue more than a frame
        if (realtime) {
          final ahead = ((sec - lead) * 1000).round() - clock.elapsedMilliseconds;
          if (ahead > 0) await Future<void>.delayed(Duration(milliseconds: ahead));
        }
      }
    } on Object catch (e) {
      log?.call('guide frame loop ended: $e'); // ffmpeg gone (killed / pipe closed)
    }
    try {
      await p.stdin.close();
    } on Object catch (_) {}
    await p.exitCode;
    if (!_done.isCompleted) _done.complete();
  }

  Future<void> stop() async {
    _stopping = true;
    final p = _p;
    if (p == null) return;
    await done.timeout(const Duration(seconds: 5), onTimeout: () => p.kill());
  }
}
