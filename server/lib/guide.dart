import 'dart:io';
import 'dart:convert';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:guidechannel/guidechannel.dart' show GuideChannelInfo, Programme, Snapshot;

import 'engine.dart';
import 'settings.dart';
import 'streamer.dart' show guideNumber;
import 'titles.dart';

/// Channel 99: the scrolling listings (modules/guidechannel), in the lineup after the Archive channels.
const guideChannel = Channel(number: guideNumber, name: 'Guide', genre: 'News & Docs', type: 'guide');

/// A channel's logo in `<config>/logos/`: the channel's own `logo` file name, else its lower-case name.
String logoPath(String configDir, Channel c) {
  final own = c.logo?.split(RegExp(r'[/\\]')).last;
  final derived = '$configDir/logos/${c.name.toLowerCase().replaceAll(RegExp(r'[\s-]'), '')}.png';
  if (own == null) return derived;
  final ownPath = '$configDir/logos/$own';
  // The configured file name can differ from the shipped file (Drive-In: 'drive-in.png' vs drivein.png): use the one that exists.
  return File(ownPath).existsSync() || !File(derived).existsSync() ? ownPath : derived;
}

/// The guide's view of [c] from [from] for [hours]: the app's guide blocks (marathons, "More X", themes).
/// Both the XMLTV and the guide channel use this, so they always agree.
List<Slot> guideSlots(Engine engine, Channel c, DateTime from, int hours) => guideBlocks(engine.guideFor(c, from, hours: hours),
    shortContent: c.shortContent, labelOf: (e) => blockLabelOf(c, e), themeOf: (s) => themeLabelOf(c, s));

/// The guide channel's snapshot: every ready channel, from the current half hour to ~6 h ahead.
Snapshot guideSnapshot(Engine engine, DateTime now, {String? Function(Channel)? logo}) {
  final from = DateTime(now.year, now.month, now.day, now.hour, now.minute < 30 ? 0 : 30);
  return Snapshot(generated: now, channels: [
    for (final c in engine.channels)
      if (engine.statusOf(c) == PoolStatus.ready)
        GuideChannelInfo(number: c.number, name: c.name, genre: c.genre, logo: logo?.call(c), programmes: [
          for (final s in guideSlots(engine, c, from, 7)) Programme(s.start, s.end, programmeTitleInfo(s.entry, block: s.end.difference(s.start) > Duration(seconds: s.entry.durationSeconds.ceil() + 60)).title),
        ]),
  ]);
}

/// rated.json with the late-night window from settings.txt (when set there).
String? ratedWithWindow(String? ratedText, Settings s) {
  if (s.windowStart == null) return ratedText;
  String hm(int m) => '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
  final j = ratedText == null ? <String, dynamic>{} : jsonDecode(ratedText) as Map<String, dynamic>;
  j['window'] = {'start': hm(s.windowStart!), 'end': hm(s.windowEnd!)};
  return jsonEncode(j);
}
