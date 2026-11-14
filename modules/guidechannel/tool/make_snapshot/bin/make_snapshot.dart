import 'dart:convert';
import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';

/// Usage: dart run bin/make_snapshot.dart CHANNELS_JSON POOLS_DIR [LOGOS_DIR] [HOURS]
/// Prints a guidechannel snapshot (JSON) for now .. now+HOURS (default 6) to stdout.
/// Same pipeline as the app's guide (day shuffle + serial/rare/themed blocks + guideBlocks),
/// minus the viewer-specific parts (blocklists, adult mode, slow/no-subs lists).
void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: make_snapshot CHANNELS_JSON POOLS_DIR [LOGOS_DIR] [HOURS]');
    exit(64);
  }
  final config = parseChannelConfig(File(args[0]).readAsStringSync());
  final pools = PoolStore(Directory(args[1]));
  final logos = args.length > 2 ? args[2] : null;
  final hours = args.length > 3 ? int.parse(args[3]) : 6;
  final now = DateTime.now();
  final until = now.add(Duration(hours: hours));
  final from = DateTime(now.year, now.month, now.day, now.hour, now.minute - now.minute % 30); // guide window start
  final channels = <Map<String, dynamic>>[];
  for (final c in config.channels) {
    final logo = logos == null
        ? null
        : '$logos${Platform.pathSeparator}${c.name.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '')}.png';
    final progs = <Map<String, String>>[];
    if (c.type == 'weatherstar') {
      final h0 = DateTime(now.year, now.month, now.day, now.hour);
      for (var t = h0; t.isBefore(until); t = t.add(const Duration(hours: 1))) {
        progs.add(_p(t, t.add(const Duration(hours: 1)), 'Local Forecast & Radar'));
      }
    } else {
      final pool = pools.load(c.number) ?? const <Entry>[];
      final serials = pools.loadSerials(c) ?? const <List<List<Entry>>>[];
      final eps = {
        for (final slot in serials)
          for (final show in slot)
            for (final e in show) e.id
      };
      final shuffle = [
        for (final e in pool)
          if (!eps.contains(e.id) && !isRare(c, e)) e
      ];
      List<Slot> dayFor(DateTime d) =>
          layoutSerialDay(dayOrder(shuffle, 'ch${c.number}', d), d, dayBlocks(c, serials, pool, d));
      // whole days from midnight so marathons/blocks group the same way as in the app
      final slots = guide(DateTime(now.year, now.month, now.day), dayFor, hours: now.hour + hours + 1);
      final blocks = guideBlocks(slots,
          shortContent: c.shortContent, labelOf: (e) => blockLabelOf(c, e), themeOf: (s) => themeLabelOf(c, s));
      for (final s in blocks) {
        if (s.end.isAfter(from) && s.start.isBefore(until)) progs.add(_p(s.start, s.end, cleanTitle(s.entry.title)));
      }
    }
    channels.add({
      'number': c.number,
      'name': c.name,
      'genre': c.genre,
      if (logo != null && File(logo).existsSync()) 'logo': logo,
      'programmes': progs,
    });
  }
  stdout.writeln(const JsonEncoder.withIndent(' ')
      .convert({'version': 1, 'generated': now.toUtc().toIso8601String(), 'channels': channels}));
}

Map<String, String> _p(DateTime a, DateTime b, String title) =>
    {'start': a.toUtc().toIso8601String(), 'end': b.toUtc().toIso8601String(), 'title': title};
