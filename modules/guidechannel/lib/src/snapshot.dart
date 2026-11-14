import 'dart:convert';

/// One programme on a channel. [start]/[end] are absolute instants (ISO 8601 with offset or Z in JSON).
class Programme {
  final DateTime start;
  final DateTime end;
  final String title;

  const Programme(this.start, this.end, this.title);

  factory Programme.fromJson(Map<String, dynamic> j) =>
      Programme(DateTime.parse(j['start'] as String), DateTime.parse(j['end'] as String), j['title'] as String);

  Map<String, dynamic> toJson() =>
      {'start': start.toUtc().toIso8601String(), 'end': end.toUtc().toIso8601String(), 'title': title};

  bool airsAt(DateTime t) => !t.isBefore(start) && t.isBefore(end);
}

/// One channel row: [programmes] sorted by start, covering roughly the next 6 hours.
class GuideChannelInfo {
  final int number;
  final String name;
  final String genre;

  /// Optional path to a channel logo PNG (4:3 or square, transparent), shown in the info strip.
  final String? logo;
  final List<Programme> programmes;

  const GuideChannelInfo(
      {required this.number, required this.name, this.genre = '', this.logo, this.programmes = const []});

  factory GuideChannelInfo.fromJson(Map<String, dynamic> j) => GuideChannelInfo(
        number: j['number'] as int,
        name: j['name'] as String,
        genre: (j['genre'] as String?) ?? '',
        logo: j['logo'] as String?,
        programmes: [
          for (final p in (j['programmes'] as List? ?? const [])) Programme.fromJson(p as Map<String, dynamic>)
        ]..sort((a, b) => a.start.compareTo(b.start)),
      );

  Map<String, dynamic> toJson() => {
        'number': number,
        'name': name,
        if (genre.isNotEmpty) 'genre': genre,
        if (logo != null) 'logo': logo,
        'programmes': [for (final p in programmes) p.toJson()],
      };

  /// The programme on at [t], or null.
  Programme? at(DateTime t) {
    for (final p in programmes) {
      if (p.airsAt(t)) return p;
    }
    return null;
  }

  /// The first programme starting at or after [t], or null.
  Programme? after(DateTime t) {
    for (final p in programmes) {
      if (!p.start.isBefore(t)) return p;
    }
    return null;
  }
}

/// What the guide channel shows: every channel (in display order) with its upcoming programmes.
class Snapshot {
  final DateTime generated;
  final List<GuideChannelInfo> channels;

  const Snapshot({required this.generated, required this.channels});

  factory Snapshot.fromJson(Map<String, dynamic> j) => Snapshot(
        generated: DateTime.parse(j['generated'] as String),
        channels: [for (final c in j['channels'] as List) GuideChannelInfo.fromJson(c as Map<String, dynamic>)],
      );

  factory Snapshot.parse(String text) => Snapshot.fromJson(jsonDecode(text) as Map<String, dynamic>);

  Map<String, dynamic> toJson() => {
        'version': 1,
        'generated': generated.toUtc().toIso8601String(),
        'channels': [for (final c in channels) c.toJson()],
      };
}
