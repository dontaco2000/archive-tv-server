import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive_tv_core/archive_tv_core.dart';

/// Background music for the guide (99) and weather channels: the app's weather-channel music (the weather
/// channel's sources in channels.json, Archive item `smooth-jazz-fm-1991`), as raw PCM that the channel's
/// ffmpeg reads from `/internal/music/<n>` (see [MusicFeed]).

/// Bytes per second of that PCM: s16le, 44.1 kHz, stereo.
const pcmRate = 44100 * 4;

/// ffmpeg input options for the PCM (followed by `-i <url>`).
const pcmInput = ['-f', 's16le', '-ar', '44100', '-ac', '2'];

/// The tracks in play order: files of 1 min to 4 h, shuffled with a fixed seed (stable while the item is).
List<Entry> musicOrder(List<Entry> pool) {
  final ok = [for (final e in pool) if (e.durationSeconds >= 60 && e.durationSeconds <= 4 * 3600) e]
    ..sort((a, b) => a.id.compareTo(b.id));
  return seededShuffle(ok, 1991);
}

/// The track "on air" at [now] if [order] had played back to back since the Unix epoch (a radio station:
/// whoever tunes in hears the same track, from its start).
int musicIndexAt(List<Entry> order, DateTime now) {
  final total = order.fold(0.0, (s, e) => s + e.durationSeconds);
  if (total <= 0) return 0;
  var t = (now.millisecondsSinceEpoch / 1000) % total;
  for (var i = 0; i < order.length; i++) {
    t -= order[i].durationSeconds;
    if (t < 0) return i;
  }
  return 0;
}

List<Entry> _from(List<Entry> order, int start) => [...order.sublist(start), ...order.sublist(0, start)];

/// ffconcat playlist: every track once, from [start]. A track that can't be read within 10 s ends the music
/// (the feed restarts it at the next track).
String musicPlaylist(List<Entry> order, int start) {
  final b = StringBuffer('ffconcat version 1.0\n');
  for (final e in _from(order, start)) {
    b
      ..write("file '${e.url.replaceAll("'", r"'\''")}'\n")
      ..write('option rw_timeout 10000000\n');
  }
  return b.toString();
}

/// The decoder's audio filter: an even level (dynaudnorm) at [volume], and a 1 s fade out and in around
/// each track change of the playlist from [start] (no clicks between tracks).
String musicFilter(List<Entry> order, int start, {double volume = 0.5}) {
  final tracks = _from(order, start);
  var t = 0.0;
  final dips = <String>[];
  for (final e in tracks.take(tracks.length - 1)) {
    t += e.durationSeconds;
    dips.add('min(1,abs(t-${t.toStringAsFixed(2)}))');
  }
  final gain = dips.isEmpty ? '$volume' : '$volume*if(isnan(t),1,${dips.join('*')})';
  return "aresample=44100,dynaudnorm=f=500:g=31:p=0.7:m=8,volume='$gain':eval=frame";
}

/// The decoder: the playlist to s16le PCM on stdout.
List<String> musicDecoderArgs(String playlist, String filter) => [
      '-hide_banner', '-loglevel', 'error', '-nostdin', //
      '-f', 'concat', '-safe', '0', '-protocol_whitelist', 'file,http,https,tcp,tls,crypto', '-i', playlist,
      '-vn', '-af', filter, '-f', 's16le', '-ar', '44100', '-ac', '2', 'pipe:1',
    ];

/// The music's track list, built from Archive once a day (core [buildPool] on the weather channel's sources)
/// and saved in `<data>/music/`, so viewers never wait on Archive metadata. A failed build keeps the saved
/// list; no list at all = the channels stay silent.
class MusicLibrary {
  final Channel? channel;
  final ChannelConfig config;
  final ArchiveApi api;
  final PoolStore store;
  final void Function(String) log;
  List<Entry> order = const [];

  MusicLibrary(this.channel, this.config, this.api, Directory dataDir, {void Function(String)? log})
      : store = PoolStore(Directory('${dataDir.path}/music')),
        log = log ?? ((_) {}) {
    final c = channel;
    if (c == null) return;
    try {
      order = musicOrder(store.load(c.number) ?? const []);
    } on Object catch (e) {
      this.log('music: saved track list unreadable: $e');
    }
  }

  /// Rebuilds the list when it is missing or older than [maxAge]; never throws.
  Future<void> refresh({Duration maxAge = const Duration(days: 1)}) async {
    final c = channel;
    if (c == null || c.sources.isEmpty) return;
    final age = store.age(c.number);
    if (order.isNotEmpty && age != null && age < maxAge) return;
    try {
      final built = await buildPool(c, config, api, log: log);
      final o = musicOrder(built);
      if (o.isEmpty) {
        log('music: no tracks found${order.isEmpty ? ', guide/weather stay silent' : ', keeping the saved list'}');
        return;
      }
      store.save(c.number, built);
      order = o;
      log('music: ${o.length} tracks, ${(o.fold(0.0, (s, e) => s + e.durationSeconds) / 3600).toStringAsFixed(1)} h');
    } on Object catch (e) {
      log('music: track list failed${order.isEmpty ? ' (guide/weather stay silent)' : ', keeping the saved list'}: $e');
    }
  }
}

/// One channel's music while it is watched: a decoder ffmpeg turns the playlist into PCM (buffered up to
/// [maxBuffer]), [serve] sends it to the channel's ffmpeg in real time (plus [lead] s at once, as the video).
/// Whenever the decoder has nothing (starting, Archive slow or failing) silence goes out instead, so the
/// picture never waits for the music. A decoder that ends is restarted at the then-current track.
class MusicFeed {
  final List<Entry> order;
  final String ffmpeg;
  final File playlist;
  final Future<Process> Function(String, List<String>) spawn;
  final double lead;
  final void Function(String) log;
  final DateTime Function() clock;

  static const maxBuffer = 3 * pcmRate;

  MusicFeed(this.order,
      {required this.ffmpeg,
      required this.playlist,
      required this.spawn,
      this.lead = 0,
      void Function(String)? log,
      DateTime Function()? clock})
      : log = log ?? ((_) {}),
        clock = clock ?? DateTime.now;

  final List<Uint8List> _buf = [];
  int _bufBytes = 0;
  Process? _dec;
  StreamSubscription<List<int>>? _sub;
  Timer? _restart;
  bool _stopped = false, _started = false;

  int get buffered => _bufBytes;

  Future<void> _startDecoder() async {
    if (_stopped) return;
    final i = musicIndexAt(order, clock());
    final started = clock();
    final Process p;
    try {
      playlist.parent.createSync(recursive: true);
      playlist.writeAsStringSync(musicPlaylist(order, i));
      p = await spawn(ffmpeg, musicDecoderArgs(playlist.path, musicFilter(order, i)));
    } on Object catch (e) {
      log('music: decoder did not start: $e');
      _again(const Duration(minutes: 1));
      return;
    }
    if (_stopped) {
      p.kill();
      return;
    }
    _dec = p;
    log('music: ${order[i].file}');
    p.stderr.transform(const SystemEncoding().decoder).listen((l) {
      if (l.trim().isNotEmpty && !_stopped) log('music: ${l.trim()}'); // a stop's broken pipe is no news
    });
    _sub = p.stdout.listen((d) {
      _buf.add(d is Uint8List ? d : Uint8List.fromList(d));
      _bufBytes += d.length;
      if (_bufBytes >= maxBuffer) _sub?.pause();
    }, onDone: () async {
      final code = await p.exitCode;
      if (_stopped) return;
      final quick = clock().difference(started) < const Duration(minutes: 1);
      log('music: decoder ended ($code), next track in ${quick ? 60 : 2} s');
      _again(Duration(seconds: quick ? 60 : 2)); // a quick failure (Archive down): don't hammer it
    });
  }

  void _again(Duration d) {
    if (_stopped) return;
    _restart = Timer(d, _startDecoder);
  }

  /// [n] bytes (a multiple of 4) of PCM: buffered music in whole samples, the rest silence.
  Uint8List take(int n) {
    final out = Uint8List(n);
    var m = math.min(n, _bufBytes);
    m -= m % 4; // keep the music sample-aligned around inserted silence
    var o = 0;
    while (o < m) {
      final c = _buf.first, k = math.min(m - o, c.length);
      out.setRange(o, o + k, c);
      if (k == c.length) {
        _buf.removeAt(0);
      } else {
        _buf[0] = Uint8List.sublistView(c, k);
      }
      o += k;
    }
    _bufBytes -= m;
    if (_sub?.isPaused ?? false) {
      if (_bufBytes < maxBuffer ~/ 2) _sub!.resume();
    }
    return out;
  }

  /// Sends PCM to [out] until [stop] or the reader goes away (then stops the decoder).
  Future<void> serve(IOSink out, {Duration tick = const Duration(milliseconds: 40)}) async {
    if (_started || _stopped) return;
    _started = true;
    unawaited(_startDecoder());
    final sw = Stopwatch()..start();
    var sent = 0;
    try {
      while (!_stopped) {
        final target = ((sw.elapsedMicroseconds / 1e6 + lead) * 44100).floor() * 4;
        if (target > sent) {
          out.add(take(target - sent));
          sent = target;
          await out.flush();
        }
        await Future<void>.delayed(tick);
      }
    } on Object {
      // the channel's ffmpeg hung up
    } finally {
      stop();
    }
  }

  void stop() {
    if (_stopped) return;
    _stopped = true;
    _restart?.cancel();
    _sub?.cancel();
    _dec?.kill();
  }
}
