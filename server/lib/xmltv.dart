import 'package:archive_tv_core/archive_tv_core.dart';

import 'titles.dart';

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');

String _2(int n) => n.toString().padLeft(2, '0');

/// XMLTV time: `20261112190000 -0600` (local time with its offset).
String xmltvTime(DateTime t) {
  final l = t.toLocal();
  final o = l.timeZoneOffset;
  final m = o.inMinutes.abs();
  return '${l.year}${_2(l.month)}${_2(l.day)}${_2(l.hour)}${_2(l.minute)}${_2(l.second)} '
      '${o.isNegative ? '-' : '+'}${_2(m ~/ 60)}${_2(m % 60)}';
}

/// One channel's guide rows: [slots] are guide blocks (see core `guideBlocks`); [rated] marks R entries.
typedef GuideRow = ({Channel channel, List<Slot> slots, bool Function(Entry) rated});

/// The XMLTV document. Channel ids are the channel numbers (= the lineup GuideNumber, how Plex matches them).
String buildXmltv(String base, List<GuideRow> rows) {
  final b = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n<tv generator-info-name="Archive TV Server">\n');
  for (final r in rows) {
    final c = r.channel;
    b.writeln('  <channel id="${c.number}">');
    b.writeln('    <display-name>${_esc(c.name)}</display-name>');
    b.writeln('    <display-name>${c.number}</display-name>');
    b.writeln('    <display-name>${c.number} ${_esc(c.name)}</display-name>');
    b.writeln('    <icon src="$base/logos/${c.number}.png"/>');
    b.writeln('  </channel>');
  }
  for (final r in rows) {
    final c = r.channel;
    for (final s in r.slots) {
      final e = s.entry;
      final block = s.end.difference(s.start) > Duration(seconds: e.durationSeconds.ceil() + 60);
      final info = programmeTitleInfo(e, block: block);
      final rated = r.rated(e);
      final desc = [
        if (info.description != null) info.description!,
        if (e.itemId.isEmpty)
          'Scrolling listings for every Archive TV channel: what is on now and next.'
        else if (block)
          'A block of programmes from the Internet Archive, starting with archive.org/details/${e.itemId}.'
        else
          'From the Internet Archive (archive.org/details/${e.itemId}).',
        if (rated) 'Rated R: airs late at night only.',
        if (c.mature) 'This channel can include mature content.',
      ].join(' ');
      b.writeln('  <programme start="${xmltvTime(s.start)}" stop="${xmltvTime(s.end)}" channel="${c.number}">');
      b.writeln('    <title lang="en">${_esc(info.title)}</title>');
      if (info.subTitle != null) b.writeln('    <sub-title lang="en">${_esc(info.subTitle!)}</sub-title>');
      b.writeln('    <desc lang="en">${_esc(desc)}</desc>');
      if (c.genre.isNotEmpty) b.writeln('    <category lang="en">${_esc(c.genre)}</category>');
      if (c.genre == 'Movies') b.writeln('    <category lang="en">Movie</category>');
      if (info.episode != null) {
        b.writeln('    <episode-num system="xmltv_ns">${(info.season ?? 1) - 1}.${info.episode! - 1}.</episode-num>');
        b.writeln('    <episode-num system="onscreen">S${_2(info.season ?? 1)}E${_2(info.episode!)}</episode-num>');
      }
      if (rated) b.writeln('    <rating system="MPAA"><value>R</value></rating>');
      b.writeln('  </programme>');
    }
  }
  b.writeln('</tv>');
  return b.toString();
}

/// The guide channel's own listing: one "Archive TV Guide" programme per hour over [hours] from [from].
List<Slot> guideChannelSlots(DateTime from, int hours) {
  final h = DateTime(from.year, from.month, from.day, from.hour);
  const e = Entry(id: 'guide', itemId: '', file: '', title: 'Archive TV Guide', durationSeconds: 3600, url: '');
  return [for (var i = 0; i < hours; i++) Slot(e, h.add(Duration(hours: i)), h.add(Duration(hours: i + 1)))];
}
