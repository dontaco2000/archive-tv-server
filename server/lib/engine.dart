import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';

import 'streamer.dart' show Schedule;

/// What is on a channel at one moment.
class Airing {
  final Channel channel;
  final Slot slot;
  final double offsetSeconds;

  const Airing(this.channel, this.slot, this.offsetSeconds);

  Duration get remaining => slot.end.difference(slot.start) - Duration(milliseconds: (offsetSeconds * 1000).round());
}

enum PoolStatus { building, ready, failed }

/// Server port of the app's TvEngine (player/lib/engine/tv_engine.dart), same scheduling semantics:
/// saved pools load at once (cut to the current config) and stay on air while a stale one rebuilds;
/// saved days keep the week stable; serial, rare and themed blocks; R-rated dayparting; dead links.
/// Left out (app/viewer-only): wrong-channel marks, no-subtitle marks, faststart probing, On Demand,
/// adult mode OFF (Plex has its own restrictions; R items follow the rated window as in the app's default).
class Engine implements Schedule {
  final ChannelConfig config;
  final ArchiveApi api;
  final PoolStore pools;
  final SnapshotStore snapshots;
  final Blocklist blocklist;
  final LinkHealth health;
  final void Function(String) log;
  final int buildConcurrency;

  final Map<int, List<Entry>> _pool = {};
  final Map<int, List<List<List<Entry>>>> _serials = {};
  final Map<int, Future<void>> _building = {};
  final Set<int> _tried = {};
  final Map<int, bool Function(Entry)> _rated = {};
  final Blocklist _skipped = Blocklist.session();

  /// Bumped whenever pools or skips change (the guide cache watches it).
  int version = 0;

  /// The app's parental "Late night adult mode" (settings.txt, default ON). OFF: R-rated entries never air.
  bool adultMode = true;

  Engine(this.config, this.api, Directory dataDir, {void Function(String)? log, this.buildConcurrency = 4})
      : pools = PoolStore(Directory('${dataDir.path}/pools')),
        snapshots = SnapshotStore(Directory('${dataDir.path}/days')),
        blocklist = Blocklist.load(dataDir),
        health = LinkHealth.load(dataDir),
        log = log ?? ((_) {});

  /// Archive channels only: the weather channel needs a browser.
  List<Channel> get channels => [for (final c in config.channels) if (c.type == 'archive') c];

  bool Function(Entry) ratedOf(Channel c) => _rated[c.number] ??= ratedTest(c, config);

  List<Entry> poolOf(Channel c) => _pool[c.number] ?? const [];

  @override
  bool isRated(Channel c, Entry e) => adultMode && ratedOf(c)(e);

  /// App TvEngine.lateNightOn (adult mode ON): [t] inside the channel's rated window and it has R entries.
  @override
  bool lateNight(Channel c, DateTime t) {
    final w = ratedWindowOf(c, config);
    return adultMode && !w.unrestricted && w.contains(t) && poolOf(c).any(ratedOf(c));
  }

  PoolStatus statusOf(Channel c) {
    if (_pool.containsKey(c.number) && !isOffAir(poolOf(c), config.minContentSeconds)) return PoolStatus.ready;
    if (c.sources.isNotEmpty && (_building.containsKey(c.number) || !_tried.contains(c.number))) return PoolStatus.building;
    return PoolStatus.failed;
  }

  /// Loads the saved pool (or builds one); [maxAge] zero forces a rebuild with the old pool on air meanwhile.
  Future<void> ensurePool(Channel channel, {Duration maxAge = const Duration(days: 1)}) {
    if (channel.sources.isEmpty || (maxAge > Duration.zero && _pool.containsKey(channel.number))) return Future.value();
    return _building[channel.number] ??= _ensurePool(channel, maxAge).whenComplete(() {
      _building.remove(channel.number);
      _tried.add(channel.number);
      version++;
    });
  }

  Future<void> _ensurePool(Channel channel, Duration maxAge) async {
    final raw = pools.load(channel.number);
    final saved = raw == null ? null : refilterPool(channel, config, raw);
    final usable = saved != null && !isOffAir(saved, config.minContentSeconds);
    final load = usable && maxAge > Duration.zero;
    if (usable && !_pool.containsKey(channel.number)) _pool[channel.number] = _blocked(channel).apply(saved); // on air during a rebuild
    await _ensureSerials(channel, rebuild: !load);
    if (load) return;
    try {
      log('${channel.name}: building pool');
      final built = await buildPool(channel, config, api, concurrency: buildConcurrency, log: log);
      if (built.isEmpty) {
        log('${channel.name}: build found nothing${saved != null ? ', keeping the saved pool' : ''}');
        if (saved != null) _pool[channel.number] = _blocked(channel).apply(saved);
        return;
      }
      final keep = [for (final e in built) if (!health.isGone(e.id)) e];
      pools.save(channel.number, keep);
      _pool[channel.number] = _blocked(channel).apply(keep);
      if (raw != null) snapshots.dropAfter(channel.number, DateTime.now());
      log('${channel.name}: pool built, ${keep.length} entries, ${(keep.fold(0.0, (s, e) => s + e.durationSeconds) / 3600).round()} h');
    } on Object catch (e) {
      log('pool build failed for ${channel.name}: $e');
      if (saved != null) _pool[channel.number] = _blocked(channel).apply(saved);
    }
  }

  Future<void> _ensureSerials(Channel c, {required bool rebuild}) async {
    if (c.serials.isEmpty) return;
    final saved = pools.loadSerials(c);
    if (saved != null && !rebuild) {
      _serials[c.number] = saved;
      return;
    }
    try {
      final built = await buildSerialEpisodes(c, api, log: log);
      if (built.any((slot) => slot.any((show) => show.isNotEmpty))) {
        pools.saveSerials(c, built);
        _serials[c.number] = built;
        return;
      }
      log('${c.name}: no serial episodes found${saved != null ? ', keeping the saved ones' : ''}');
    } on Object catch (e) {
      log('serial build failed for ${c.name}: $e');
    }
    if (saved != null) _serials[c.number] = saved;
  }

  /// The pool the day's shuffle is made from: serial episodes, rare-source and block-only entries never air in it.
  List<Entry> _shufflePool(Channel c) {
    final pool = _pool[c.number] ?? const <Entry>[];
    final eps = _serials[c.number];
    final ids = {if (eps != null) for (final slot in eps) for (final show in slot) for (final e in show) e.id};
    return [for (final e in pool) if (!ids.contains(e.id) && !isRare(c, e) && !isBlockOnly(c, e)) e];
  }

  List<SerialBlock> Function(DateTime)? _blocksFor(Channel c) =>
      c.serials.isEmpty && c.timeBlocks.isEmpty && !c.sources.any((s) => s.perDay != null)
          ? null
          : (d) => dayBlocks(c, _serials[c.number] ?? const [], _pool[c.number] ?? const [], d);

  Blocklist _blocked(Channel c) => blocklist.union(health.dead);

  /// Drops [entryId] from the channel's schedule for this run (it failed to play).
  void markBad(Channel channel, String entryId) {
    log('${channel.name}: skipping $entryId for this run');
    _skipped.add(entryId);
    version++;
  }

  List<Slot> _day(Channel c, DateTime day) {
    final rare = {for (final e in _pool[c.number] ?? const <Entry>[]) if (isRare(c, e)) e.id};
    final fits = poolFilter(c, config);
    final r = ratedOf(c);
    // Adult mode OFF (as the app): rated entries leave the shuffle, and block picks (serial episodes,
    // rare/themed picks) by id.
    final noRated = Blocklist.session();
    if (!adultMode) {
      noRated.ids.addAll([
        for (final e in _pool[c.number] ?? const <Entry>[]) if (r(e)) e.id,
        for (final slot in _serials[c.number] ?? const <List<List<Entry>>>[]) for (final show in slot) for (final e in show) if (r(e)) e.id,
      ]);
    }
    return snapshots.day(c.number, day, _shufflePool(c),
        blocklist: _blocked(c).union(_skipped).union(noRated),
        serials: _blocksFor(c),
        inShuffle: (e) => fits(e) && !rare.contains(e.id) && (adultMode || !r(e)),
        rated: r,
        window: ratedWindowOf(c, config));
  }

  Airing? airing(Channel channel, DateTime now) {
    final slot = slotAt(_day(channel, now), now);
    return slot == null ? null : Airing(channel, slot, offsetSeconds(slot, now));
  }

  List<Slot> guideFor(Channel channel, DateTime from, {int hours = 12}) => guide(from, (d) => _day(channel, d), hours: hours);

  void planWeek(Channel channel, DateTime now) {
    snapshots.ensureWeek(channel.number, now, _shufflePool(channel), serials: _blocksFor(channel));
    snapshots.prune(now);
  }

  /// Startup and each local midnight: rebuild pools older than [maxAge] (old ones stay on air), save the week.
  Future<void> dailyRefresh(DateTime now, {Duration maxAge = const Duration(days: 1)}) async {
    for (final c in channels) {
      if (c.sources.isEmpty) continue;
      final age = pools.age(c.number);
      final stale = age == null || age >= maxAge;
      try {
        await ensurePool(c, maxAge: stale ? Duration.zero : maxAge);
      } on Object catch (e) {
        log('daily refresh ${c.name}: $e');
      }
      planWeek(c, now);
    }
    version++;
    log('daily refresh done');
  }

  int get deadLinks => health.activeDead;

  /// One dead-link pass over the next [hours] of every channel (see the app's TvEngine.checkLinks).
  Future<int> checkLinks(DateTime now, DeadLinkChecker checker, {int hours = 12, bool onlyStruck = false}) async {
    var found = 0;
    final sw = Stopwatch()..start();
    for (final c in channels) {
      if (checker.gaveUp) break;
      final seen = <String>{};
      final List<Entry> todo;
      try {
        todo = [
          for (final s in guideFor(c, now, hours: hours))
            if (s.start.isAfter(now) && seen.add(s.entry.id) && (!onlyStruck || health.struck(s.entry.id))) s.entry,
        ];
      } on Object catch (e) {
        log('link check ${c.name}: $e');
        continue;
      }
      if (todo.isEmpty) continue;
      final dead = await checker.checkChannel(c.number, c.name, todo, now: () => now.add(sw.elapsed));
      if (dead.isEmpty) continue;
      found += dead.length;
      for (final n in _pool.keys.toList()) {
        _pool[n] = health.dead.apply(_pool[n]!);
      }
      version++;
    }
    if (!onlyStruck) {
      // ponytail: revived files come back at the next pool load; the app also keeps them off today's layout.
      final r = await checker.recheckDead(now: () => now.add(sw.elapsed));
      if (r.revived.isNotEmpty || r.gone.isNotEmpty) version++;
    }
    return found;
  }
}
