import 'dart:async';
import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:archive_tv_overlays/archive_tv_overlays.dart' as ov;
import 'package:guidechannel/guidechannel.dart' show GuideChannel, Snapshot;

import 'engine.dart';

/// What the stream engine needs from the scheduler (the [Engine]; tests use a fake).
abstract interface class Schedule {
  Airing? airing(Channel c, DateTime now);
  void markBad(Channel c, String entryId);
  PoolStatus statusOf(Channel c);

  /// The entry is R-rated (R badge + viewer-discretion notice).
  bool isRated(Channel c, Entry e);

  /// [t] is in the channel's late-night (rated) window and the channel has R entries.
  bool lateNight(Channel c, DateTime t);
}

/// Burned-in overlay settings (null on the [Streamer] = plain video, the phase 1 look).
class Overlays {
  final String font;

  /// Watermark PNGs: plain, and with an R in the TV for R-rated programmes (null = plain one).
  final String? watermark, watermarkRated;
  final bool watermarkLabel, tuneBanner, cornerBug, discretionCard, discretionStrip, lateNightNotice;
  final int tuneBannerSeconds;
  final String? Function(Channel) logo;
  const Overlays({
    this.font = ov.defaultFontFile,
    this.watermark,
    this.watermarkRated,
    required this.logo,
    this.watermarkLabel = true,
    this.tuneBanner = false,
    this.tuneBannerSeconds = 4,
    this.cornerBug = false,
    this.discretionCard = false,
    this.discretionStrip = false,
    this.lateNightNotice = false,
  });
}

/// The guide channel's number (one shared listings stream, see modules/guidechannel).
const guideNumber = 99;

/// Seconds the stream is kept ahead of real time: each piece starts with a burst that refills this lead,
/// so a player (Plex) gets a buffer at tune and across item changes instead of running at exactly 1x.
const leadSeconds = 6.0;

/// A late joiner of a running channel first gets this much of the recent output (~2.5 s at ~1.1 Mbit/s):
/// a head start that contains a keyframe (GOP 2 s).
const backlogBytes = 350 * 1024;

typedef Spawn = Future<Process> Function(String exe, List<String> args);

/// One piece of a channel's stream: [entry] from [offset] seconds for [length], or (entry null) a STAND BY card.
class Job {
  final Entry? entry;
  final double offset;
  final Duration length;

  /// `<entry id>@<slot start>`: identifies the airing (null for STAND BY).
  final String? key;

  /// Card text for a piece without an entry (the app's wording: STAND BY, build mode notice, OFF AIR, NO SIGNAL).
  final String message;

  const Job(this.entry, this.offset, this.length, this.key) : message = ov.standBy;
  const Job.standby(this.length, [this.message = ov.standBy])
      : entry = null,
        offset = 0,
        key = null;

  @override
  String toString() => entry == null ? '${message.split('\n').first}${length.inSeconds}s' : '${entry!.id} @${offset.round()}s for ${length.inSeconds}s';
}

/// Output format every piece is encoded to, so Plex never sees a codec change (the outer ffmpeg only copies).
const _encode = [
  '-c:v', 'libx264', '-preset', 'veryfast', '-profile:v', 'main', '-level', '3.1', '-pix_fmt', 'yuv420p', //
  '-b:v', '900k', '-maxrate', '1200k', '-bufsize', '1800k', '-g', '60', '-keyint_min', '60', '-sc_threshold', '0',
  '-c:a', 'aac', '-b:a', '96k', '-ac', '2', '-ar', '44100',
  '-f', 'mpegts', 'pipe:1',
];
const _fps = '30000/1001';
const _scale = 'scale=640:480:force_original_aspect_ratio=decrease,pad=640:480:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=$_fps';

/// Real-time reading with a first [burst] of seconds read as fast as possible.
List<String> _rate(double burst) =>
    ['-readrate', '1', if (burst >= 0.5) ...['-readrate_initial_burst', burst.toStringAsFixed(1)]];

/// ffmpeg arguments for one piece. [noAudio]/[noVideo]: the file lacks that stream, a silent/black one stands in.
/// [overlay]: burn in the Archive TV overlays (card mode for a piece without entry); stdin then stays open for
/// live filter commands. [burst]: seconds sent ahead of real time at the start.
List<String> jobArgs(Job job,
    {bool noAudio = false, bool noVideo = false, String? font, ov.OverlayParams? overlay, String overlayFont = ov.defaultFontFile, double burst = 0}) {
  final t = (job.length.inMilliseconds / 1000).toStringAsFixed(3);
  final rate = _rate(burst);
  final head = ['-hide_banner', '-loglevel', 'error', if (overlay == null) '-nostdin'];
  final silence = [...rate, '-f', 'lavfi', '-i', 'anullsrc=r=44100:cl=stereo'];
  const cfr = ['-fps_mode', 'cfr', '-r', _fps];
  if (overlay != null) {
    if (job.entry == null) {
      final g = ov.buildFilterGraph(overlay, fontFile: overlayFont);
      return [
        ...head,
        for (final a in g.inputArgs) ...(a == '-f' ? [...rate, a] : [a]),
        '-t', t, '-filter_complex', g.filterComplex, '-map', g.videoMap, '-map', g.audioMap, ...cfr, ..._encode,
      ];
    }
    final src = [
      if (job.offset >= 1) ...['-ss', job.offset.toStringAsFixed(3)],
      ...rate, '-reconnect', '1', '-reconnect_on_network_error', '1', '-reconnect_delay_max', '4', '-rw_timeout', '15000000',
      '-i', job.entry!.url,
    ];
    // The overlay graph reads its video from input 0: a missing video's black stand-in goes first.
    final inputs = noVideo
        ? [...rate, '-f', 'lavfi', '-i', 'color=c=black:s=640x480:r=$_fps', ...src]
        : [...src, if (noAudio) ...silence];
    final g = ov.buildFilterGraph(overlay, fontFile: overlayFont, firstInput: noAudio || noVideo ? 2 : 1);
    return [
      ...head, ...inputs, ...g.inputArgs, '-t', t,
      '-filter_complex', g.filterComplex, '-map', g.videoMap,
      '-map', noVideo ? '1:a:0' : (noAudio ? '1:a' : '0:a:0'),
      if (noAudio || noVideo) ...['-shortest', '-shortest_buf_duration', '0.5'],
      '-af', 'aresample=async=1:first_pts=0', ...cfr, ..._encode,
    ];
  }
  if (job.entry == null) {
    final text = font != null && File(font).existsSync()
        ? ",drawtext=fontfile=$font:text='STAND BY':fontcolor=white:fontsize=56:x=(w-tw)/2:y=(h-th)/2"
        : '';
    return [
      ...head, ...rate, '-f', 'lavfi', '-i', 'color=c=0x14213d:s=640x480:r=$_fps', ...silence, //
      '-t', t, '-map', '0:v', '-map', '1:a', '-vf', 'setsar=1$text', ..._encode,
    ];
  }
  return [
    ...head,
    if (job.offset >= 1) ...['-ss', job.offset.toStringAsFixed(3)],
    ...rate, '-reconnect', '1', '-reconnect_on_network_error', '1', '-reconnect_delay_max', '4', '-rw_timeout', '15000000',
    '-i', job.entry!.url,
    if (noAudio) ...silence,
    if (noVideo) ...[...rate, '-f', 'lavfi', '-i', 'color=c=black:s=640x480:r=$_fps'],
    '-t', t,
    '-map', noVideo ? '1:v' : '0:v:0',
    '-map', noAudio ? '1:a' : '0:a:0',
    if (noAudio || noVideo) ...['-shortest', '-shortest_buf_duration', '0.5'],
    '-vf', _scale, '-af', 'aresample=async=1:first_pts=0', ..._encode,
  ];
}

class _Viewer {
  final HttpResponse res;
  bool aligned = false;
  _Viewer(this.res);
}

/// One watched channel: one outer ffmpeg (concat demuxer, copy only) that keeps asking this server for the
/// next piece (`/internal/item/<n>`), fanned out to every viewer.
class Session {
  final Channel channel;
  final Streamer s;
  final int gen;
  final List<_Viewer> _viewers = [];
  Process? _outer;
  final Set<Process> _inner = {};
  Timer? _idle;
  int _bytes = 0;
  bool stopped = false;
  final List<DateTime> _restarts = [];

  /// Airing key of the last piece that played to its end (a file shorter than its slot: STAND BY fills the rest).
  String? lastEnded;
  final Map<String, int> _fails = {};
  final Map<String, ({bool noAudio, bool noVideo})> _shape = {};

  /// Schedule time the stream has been sent up to (ahead of the wall clock by up to [leadSeconds]);
  /// null = start from now (new session, outer restart, a failed piece).
  DateTime? _pos;

  /// When the last viewer tuned in (tune banner timing).
  DateTime? _tunedAt;

  /// The piece playing now: its ffmpeg, when its first output came, and how far ahead its clock t ran then.
  ({Process p, DateTime? first, double lead, bool lateNight})? _cur;

  /// Recent output for late joiners ([backlogBytes]); [_blStart] = stream offset of its first byte.
  final List<List<int>> _backlog = [];
  int _blBytes = 0, _blStart = 0;

  GuideChannel? _guide;
  Timer? _guideTimer;

  Session(this.channel, this.s, this.gen);

  int get viewers => _viewers.length;

  Future<void> start() async {
    _pos = null;
    if (channel.number == guideNumber && s.guideSnapshot != null) return _startGuide();
    final f = File('${s.tmpDir.path}/ch${channel.number}.ffconcat');
    f.parent.createSync(recursive: true);
    final url = '${s.selfBase}/internal/item/${channel.number}?g=$gen';
    f.writeAsStringSync('ffconcat version 1.0\n${List.filled(5000, "file '$url'\n").join()}');
    final p = await s.spawn(s.ffmpeg, [
      '-hide_banner', '-loglevel', 'error', '-nostdin', //
      '-f', 'concat', '-safe', '0', '-protocol_whitelist', 'file,http,tcp', '-i', f.path,
      '-map', '0', '-c', 'copy', '-f', 'mpegts', 'pipe:1',
    ]);
    _outer = p;
    p.stderr.listen((d) => s.log('ch${channel.number} outer: ${String.fromCharCodes(d).trim()}'));
    p.stdout.listen(_fanOut, onDone: () async {
      final code = await p.exitCode;
      if (stopped) return;
      _restarts
        ..add(DateTime.now())
        ..removeWhere((t) => DateTime.now().difference(t) > const Duration(minutes: 2));
      s.log('ch${channel.number}: outer ffmpeg ended ($code)${_restarts.length <= 3 ? ', restarting' : ', giving up'}');
      if (_restarts.length <= 3 && _viewers.isNotEmpty) {
        await start();
      } else {
        stop();
      }
    });
  }

  /// The guide channel: one shared listings stream, snapshot refreshed every 5 minutes.
  Future<void> _startGuide() async {
    final g = _guide = GuideChannel(s.guideSnapshot!(), ffmpeg: s.ffmpeg, lead: leadSeconds, log: (l) {
      if (l.isNotEmpty) s.log('ch$guideNumber guide: $l');
    });
    await g.start();
    _guideTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      try {
        g.snapshot = s.guideSnapshot!();
      } on Object catch (e) {
        s.log('ch$guideNumber: snapshot failed: $e');
      }
    });
    g.output.listen(_fanOut, onDone: () {
      if (!stopped) s.log('ch$guideNumber: guide stream ended');
      stop();
    });
  }

  void _fanOut(List<int> chunk) {
    final before = _bytes;
    _bytes += chunk.length;
    _backlog.add(chunk);
    _blBytes += chunk.length;
    while (_blBytes - _backlog.first.length >= backlogBytes) {
      _blBytes -= _backlog.first.length;
      _blStart += _backlog.removeAt(0).length;
    }
    for (final v in [..._viewers]) {
      var data = chunk;
      if (!v.aligned) {
        final skip = (188 - before % 188) % 188; // a late joiner starts on a TS packet boundary
        if (skip >= chunk.length) continue;
        data = skip == 0 ? chunk : chunk.sublist(skip);
        v.aligned = true;
      }
      try {
        v.res.add(data);
      } on Object {
        _viewers.remove(v);
      }
    }
  }

  /// Serves [res] until the viewer leaves.
  Future<void> watch(HttpResponse res) async {
    _idle?.cancel();
    final v = _Viewer(res);
    _tunedAt = s.clock();
    if (_backlog.isNotEmpty) {
      // head start for a late joiner, from a TS packet boundary
      final all = [for (final c in _backlog) ...c];
      final skip = (188 - _blStart % 188) % 188;
      if (skip < all.length) {
        try {
          res.add(all.sublist(skip));
          v.aligned = true;
        } on Object {
          // gone already
        }
      }
    }
    _viewers.add(v);
    _bannerForNewViewer();
    try {
      await res.done;
    } on Object {
      // viewer went away
    }
    _viewers.remove(v);
    if (_viewers.isEmpty && !stopped) _idle = Timer(s.idle, stop);
  }

  void stop() {
    if (stopped) return;
    stopped = true;
    _idle?.cancel();
    _guideTimer?.cancel();
    unawaited(_guide?.stop());
    _outer?.kill();
    for (final p in _inner) {
      p.kill();
    }
    for (final v in _viewers) {
      v.res.close().catchError((_) {});
    }
    _viewers.clear();
    s._ended(this);
    s.log('ch${channel.number}: stopped');
  }

  /// The next piece at [now]: the airing slot from its offset to its end; the next slot when under 5 s are
  /// left; STAND BY when nothing is ready, or the file already ended before its slot did.
  Job nextJob(DateTime now) {
    if (s.schedule.statusOf(channel) != PoolStatus.ready) return const Job.standby(Duration(seconds: 30));
    var a = s.schedule.airing(channel, now);
    if (a != null && a.remaining < const Duration(seconds: 5)) {
      final n = s.schedule.airing(channel, a.slot.end);
      a = n == null ? null : Airing(channel, n.slot, 0);
    }
    if (a == null) return const Job.standby(Duration(seconds: 30));
    final key = '${a.slot.entry.id}@${a.slot.start.millisecondsSinceEpoch}';
    if (key == lastEnded) {
      final r = a.remaining;
      return Job.standby(r > const Duration(minutes: 5) ? const Duration(minutes: 5) : r);
    }
    return Job(a.slot.entry, a.offsetSeconds, a.remaining, key);
  }

  /// Answers one `/internal/item` request from the outer ffmpeg: tries the airing piece (retry once, then skip
  /// the item, like the app: two items, then STAND BY).
  Future<void> serveItem(HttpResponse res) async {
    try {
      await _serveItem(res);
    } finally {
      await res.close().catchError((_) {});
    }
  }

  Future<void> _serveItem(HttpResponse res) async {
    for (var attempt = 0; attempt < 4 && !stopped; attempt++) {
      final now = s.clock(), at = _pos != null && _pos!.isAfter(now) ? _pos! : now;
      final job = nextJob(at);
      final shape = job.key == null ? null : _shape[job.entry!.id];
      final r = await _run(job, res, at, noAudio: shape?.noAudio ?? false, noVideo: shape?.noVideo ?? false);
      _pos = r.output && r.code == 0 ? at.add(job.length) : null;
      if (r.output) {
        if (job.key != null) {
          if (r.code == 0) {
            lastEnded = job.key;
          } else if ((_fails[job.key!] = (_fails[job.key!] ?? 0) + 1) >= 3) {
            s.schedule.markBad(channel, job.entry!.id); // keeps breaking mid-way
          }
        }
        return;
      }
      if (job.key == null) break;
      final e = job.entry!;
      // ffmpeg 8: "Stream map '' matches no streams ... Failed to set value '0:a:0'"; with the overlay graph a
      // missing video is "Stream specifier ':v' in filtergraph description [0:v]... matches no streams".
      final none = r.err.contains('matches no streams');
      final noV = r.err.contains("specifier ':v' in filtergraph") || (none && r.err.contains("'0:v:0'")),
          noA = !noV && none && r.err.contains("'0:a:0'");
      if ((noA || noV) && shape == null) {
        _shape[e.id] = (noAudio: noA, noVideo: noV);
        attempt--; // not a failure: retry at once with a stand-in stream
        continue;
      }
      s.log('ch${channel.number}: ${e.id} failed (attempt $attempt): ${r.err.split('\n').where((l) => l.trim().isNotEmpty).take(2).join(' | ')}');
      if (attempt.isOdd || r.timedOut) {
        s.schedule.markBad(channel, e.id); // a seek that took too long won't get faster: skip at once
        if (attempt.isEven) attempt++;
      }
    }
    if (!stopped) {
      final now = s.clock();
      const j = Job.standby(Duration(seconds: 30), ov.noSignal);
      final r = await _run(j, res, now);
      _pos = r.code == 0 ? now.add(j.length) : null;
    }
  }

  /// Show the tune banner to a viewer who joined the running piece (its process is past its own banner).
  void _bannerForNewViewer() {
    final c = _cur;
    final o = s.overlays;
    if (c == null || c.first == null || o == null || !o.tuneBanner) return;
    final at = s.clock().difference(c.first!).inMilliseconds / 1000 + c.lead;
    _command(c.p, ov.tuneBannerCommands(at, lateNight: c.lateNight, seconds: o.tuneBannerSeconds));
  }

  void _command(Process p, List<String> lines) {
    try {
      p.stdin.write(lines.join());
    } on Object {
      // ffmpeg already gone
    }
  }

  /// The overlay parameters for [job] starting at schedule time [at], [lead] s ahead of the wall clock.
  ov.OverlayParams _overlayFor(Job job, DateTime at, double lead) {
    final o = s.overlays!;
    final e = job.entry;
    final since = _tunedAt == null ? 0.0 : s.clock().difference(_tunedAt!).inMilliseconds / 1000 - lead;
    final message = e != null
        ? null
        : switch (s.schedule.statusOf(channel)) {
            PoolStatus.building => ov.buildModeNotice,
            PoolStatus.failed => ov.offAir,
            PoolStatus.ready => job.message,
          };
    final rated = e != null && s.schedule.isRated(channel, e);
    return ov.OverlayParams(
      number: channel.number,
      name: channel.name,
      logoPath: o.tuneBanner || o.cornerBug || message != null ? o.logo(channel) : null,
      watermarkPath: rated && o.watermarkRated != null ? o.watermarkRated : o.watermark,
      watermarkLabel: o.watermarkLabel ? '${channel.number} ${channel.name.toUpperCase()}' : null,
      secondsSinceTune: since < 0 ? 0 : since,
      lateNight: o.lateNightNotice && s.schedule.lateNight(channel, at),
      mature: rated,
      secondsIntoProgramme: job.offset,
      message: message,
      tuneBanner: o.tuneBanner,
      bannerSeconds: o.tuneBannerSeconds,
      compactBanner: true,
      cornerBug: o.cornerBug,
      bugLogo: o.cornerBug,
      ratedBadge: false, // the R is in the watermark's TV
      discretionCard: o.discretionCard,
      discretionStrip: o.discretionStrip,
      lateNightInBanner: true,
      lateNightInCard: true,
    );
  }

  Future<({bool output, int code, String err, bool timedOut})> _run(Job job, HttpResponse res, DateTime at,
      {bool noAudio = false, bool noVideo = false}) async {
    final ahead = at.difference(s.clock()).inMilliseconds / 1000;
    final lead = ahead < 0 ? 0.0 : ahead;
    final burst = (leadSeconds - lead).clamp(0.0, leadSeconds);
    final overlay = s.overlays == null ? null : _overlayFor(job, at, lead);
    s.log('ch${channel.number}: play $job${burst >= 0.5 ? ' (burst ${burst.toStringAsFixed(1)} s)' : ''}');
    final p = await s.spawn(
        s.ffmpeg,
        jobArgs(job,
            noAudio: noAudio,
            noVideo: noVideo,
            font: s.font,
            overlay: overlay,
            overlayFont: s.overlays?.font ?? ov.defaultFontFile,
            burst: burst));
    _inner.add(p);
    if (overlay != null) p.stdin.done.catchError((_) {});
    var cur = (p: p, first: null as DateTime?, lead: burst, lateNight: overlay?.lateNight ?? false);
    _cur = cur;
    var timedOut = false;
    // Some files seek by decoding from the start (a minute or more): give up on them, as the app does after 15 s.
    final watchdog = Timer(s.firstOutput, () {
      timedOut = true;
      p.kill();
    });
    final err = StringBuffer();
    final errDone = p.stderr.listen((d) {
      if (err.length < 4000) err.write(String.fromCharCodes(d));
    }).asFuture<void>();
    var output = false;
    try {
      await res.addStream(p.stdout.map((d) {
        if (!output) {
          watchdog.cancel();
          if (identical(_cur, cur)) _cur = cur = (p: p, first: s.clock(), lead: cur.lead, lateNight: cur.lateNight);
        }
        output = true;
        return d;
      }));
    } on Object {
      p.kill(); // the outer ffmpeg hung up (channel stopped or restarting)
    }
    final code = await p.exitCode;
    watchdog.cancel();
    await errDone.catchError((_) {});
    _inner.remove(p);
    if (identical(_cur, cur)) _cur = null;
    return (output: output, code: code, err: err.toString(), timedOut: timedOut && !output);
  }
}

/// Starts/stops one [Session] per watched channel, at most [maxTuners] at a time.
class Streamer {
  final Schedule schedule;
  final String ffmpeg;
  final String selfBase;
  final Directory tmpDir;
  final int maxTuners;
  final Duration idle;

  /// A piece with no output by then is killed and its item skipped.
  final Duration firstOutput;
  final String? font;

  /// Burned-in overlays; null = plain video.
  final Overlays? overlays;

  /// The guide channel's listings (null: no guide channel).
  final Snapshot Function()? guideSnapshot;
  final Spawn spawn;
  final DateTime Function() clock;
  final void Function(String) log;

  final Map<int, Session> sessions = {};
  int _gen = 0;

  Streamer({
    required this.schedule,
    required this.ffmpeg,
    required this.selfBase,
    required this.tmpDir,
    this.maxTuners = 4,
    this.idle = const Duration(seconds: 30),
    this.firstOutput = const Duration(seconds: 10),
    this.font,
    this.overlays,
    this.guideSnapshot,
    Spawn? spawn,
    DateTime Function()? clock,
    void Function(String)? log,
  })  : spawn = spawn ?? ((exe, args) => Process.start(exe, args)),
        clock = clock ?? DateTime.now,
        log = log ?? ((_) {});

  /// The channel's running session, or a new one; null when every tuner is busy with a watched channel.
  Future<Session?> join(Channel c) async {
    final have = sessions[c.number];
    if (have != null && !have.stopped) return have;
    if (sessions.length >= maxTuners) {
      final idle = sessions.values.where((x) => x.viewers == 0).firstOrNull;
      if (idle == null) return null;
      idle.stop(); // a channel in its 30 s grace period gives its tuner up
    }
    final s = sessions[c.number] = Session(c, this, ++_gen);
    log('ch${c.number}: start (${sessions.length}/$maxTuners tuners)');
    await s.start();
    return s;
  }

  /// The session an `/internal/item/<n>?g=` request belongs to (null if it was stopped meanwhile).
  Session? byGen(int channel, int gen) {
    final s = sessions[channel];
    return s != null && s.gen == gen && !s.stopped ? s : null;
  }

  void _ended(Session s) {
    if (sessions[s.channel.number] == s) sessions.remove(s.channel.number);
  }

  void stopAll() {
    for (final s in [...sessions.values]) {
      s.stop();
    }
  }
}
