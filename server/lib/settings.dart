import 'dart:io';

/// The server's settings file (`<config>/settings.txt`, `key = value`, `#` comments), the Plex server's
/// stand-in for the app's menu. Written with the defaults on first start; bad values fall back to the
/// default (with a warning). Read at start only: `sudo systemctl restart archivetv-server` after editing.
class Settings {
  /// The app's parental "Late night adult mode" (default ON). ON: R-rated items air only inside the
  /// late-night window, with the LATE NIGHT ADULT MODE line, R badge, discretion notice and R in the guide.
  /// OFF: R-rated items never air (as the app with the toggle OFF) and nothing R is shown.
  final bool lateNightAdultMode;

  /// Late-night window, minutes after local midnight; null = rated.json's window (22:00-05:00).
  final int? windowStart, windowEnd;

  /// Simultaneous channels (HDHomeRun tuner count Plex sees). The guide channel counts as one while watched.
  final int tuners;

  /// Burned-in overlays (tune banner, bug, R badge, notices, watermark). false = plain video (phase 1 look).
  final bool overlays;

  /// The watermark (bottom-right Archive TV mark) when [overlays] is on.
  final bool watermark;

  /// Channel number + name in small text under the watermark.
  final bool watermarkLabel;

  /// The watermark's TV shows an R during R-rated programmes (the only on-screen rating mark by default).
  final bool ratedWatermark;

  /// Channel banner (logo + number + name, top-left) for [tuneBannerSeconds] when a viewer tunes in.
  final bool tuneBanner;
  final int tuneBannerSeconds;

  /// Small logo + number top-left for the whole programme.
  final bool cornerBug;

  /// VIEWER DISCRETION ADVISED card when an R programme starts / strip when tuning in mid-programme.
  final bool discretionCard, discretionStrip;

  /// The LATE NIGHT ADULT MODE line (on the tune banner, the discretion card and the STAND BY cards).
  final bool lateNightNotice;

  /// Channel 99 "Guide" (scrolling listings).
  final bool guideChannel;

  final List<String> warnings;

  const Settings({
    this.lateNightAdultMode = true,
    this.windowStart,
    this.windowEnd,
    this.tuners = 4,
    this.overlays = true,
    this.watermark = true,
    this.watermarkLabel = true,
    this.ratedWatermark = true,
    this.tuneBanner = false,
    this.tuneBannerSeconds = 4,
    this.cornerBug = false,
    this.discretionCard = false,
    this.discretionStrip = false,
    this.lateNightNotice = false,
    this.guideChannel = true,
    this.warnings = const [],
  });

  static const fileName = 'settings.txt';

  static const defaultText = '''# Archive TV Server settings. Edit, then: sudo systemctl restart archivetv-server
# A bad value is ignored (the default is used and a warning is logged).

# Late night adult mode (the app's parental setting, default true).
#   true:  R-rated programmes air only in the late-night window below, with the LATE NIGHT ADULT MODE
#          notice, the R badge, the viewer-discretion notice and an R rating in the guide.
#   false: R-rated programmes never air.
late_night_adult_mode = true

# Late-night window, local time HH:MM. Empty = the window in rated.json (22:00 to 05:00).
late_night_start =
late_night_end =

# Channels that can play at once (the tuner count Plex sees). 1-8. The Guide channel counts as one.
tuners = 4

# Burned-in overlays master switch. false = plain video, none of the items below.
overlays = true

# The Archive TV watermark, bottom-right, 50% opacity.
watermark = true
# Channel number and name in small text under the watermark (e.g. "12 WARP").
watermark_label = true
# During R-rated programmes the watermark's TV shows an R.
rated_watermark = true

# Channel banner top-left (logo + number + name) for a few seconds when someone tunes in.
tune_banner = false
tune_banner_seconds = 4
# Small logo + channel number top-left all the time.
corner_bug = false
# Black VIEWER DISCRETION ADVISED card when an R programme starts.
discretion_card = false
# VIEWER DISCRETION ADVISED strip at the bottom when tuning in during an R programme.
discretion_strip = false
# LATE NIGHT ADULT MODE line on the tune banner, the discretion card and the STAND BY cards
# (only during the late-night window).
late_night_notice = false

# Channel 99 "Guide": scrolling listings of every channel.
guide_channel = true
''';

  factory Settings.parse(String text, {int defaultTuners = 4}) {
    final kv = <String, String>{};
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final i = line.indexOf('=');
      if (i < 0) continue;
      kv[line.substring(0, i).trim().toLowerCase()] = line.substring(i + 1).trim();
    }
    final warn = <String>[];
    bool flag(String key, bool def) {
      final v = kv[key]?.toLowerCase();
      if (v == null || v.isEmpty) return def;
      if (const ['true', 'yes', 'on', '1'].contains(v)) return true;
      if (const ['false', 'no', 'off', '0'].contains(v)) return false;
      warn.add('$key = "${kv[key]}" is not true/false, using $def');
      return def;
    }

    int? time(String key) {
      final v = kv[key];
      if (v == null || v.isEmpty) return null;
      final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(v);
      final h = m == null ? 99 : int.parse(m[1]!), mi = m == null ? 99 : int.parse(m[2]!);
      if (h > 23 || mi > 59) {
        warn.add('$key = "$v" is not HH:MM, using rated.json');
        return null;
      }
      return h * 60 + mi;
    }

    var tuners = defaultTuners;
    if (kv['tuners'] case final v? when v.isNotEmpty) {
      final n = int.tryParse(v);
      if (n == null || n < 1 || n > 8) {
        warn.add('tuners = "$v" is not 1-8, using $defaultTuners');
      } else {
        tuners = n;
      }
    }
    var bannerSecs = 4;
    if (kv['tune_banner_seconds'] case final v? when v.isNotEmpty) {
      final n = int.tryParse(v);
      if (n == null || n < 1 || n > 30) {
        warn.add('tune_banner_seconds = "$v" is not 1-30, using 4');
      } else {
        bannerSecs = n;
      }
    }
    var start = time('late_night_start'), end = time('late_night_end');
    if ((start == null) != (end == null)) {
      warn.add('late_night_start and late_night_end must both be set, using rated.json');
      start = end = null;
    }
    return Settings(
      lateNightAdultMode: flag('late_night_adult_mode', true),
      windowStart: start,
      windowEnd: end,
      tuners: tuners,
      overlays: flag('overlays', true),
      watermark: flag('watermark', true),
      watermarkLabel: flag('watermark_label', true),
      ratedWatermark: flag('rated_watermark', true),
      tuneBanner: flag('tune_banner', false),
      tuneBannerSeconds: bannerSecs,
      cornerBug: flag('corner_bug', false),
      discretionCard: flag('discretion_card', false),
      discretionStrip: flag('discretion_strip', false),
      lateNightNotice: flag('late_night_notice', false),
      guideChannel: flag('guide_channel', true),
      warnings: warn,
    );
  }

  /// Reads `<configDir>/settings.txt`, writing the defaults first when it is missing.
  factory Settings.load(String configDir, {int defaultTuners = 4, void Function(String)? log}) {
    final f = File('$configDir/$fileName');
    if (!f.existsSync()) {
      try {
        f.writeAsStringSync(defaultText);
        log?.call('settings: wrote defaults to ${f.path}');
      } on Object catch (e) {
        log?.call('settings: could not write ${f.path}: $e');
        return Settings(tuners: defaultTuners);
      }
    }
    return Settings.parse(f.readAsStringSync(), defaultTuners: defaultTuners);
  }

  String _hm(int m) => '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';

  @override
  String toString() => 'late_night_adult_mode=$lateNightAdultMode, window='
      '${windowStart == null ? 'rated.json' : '${_hm(windowStart!)}-${_hm(windowEnd!)}'}, tuners=$tuners, '
      'overlays=$overlays, watermark=$watermark, watermark_label=$watermarkLabel, rated_watermark=$ratedWatermark, '
      'tune_banner=$tuneBanner (${tuneBannerSeconds}s), corner_bug=$cornerBug, discretion_card=$discretionCard, '
      'discretion_strip=$discretionStrip, late_night_notice=$lateNightNotice, guide_channel=$guideChannel';
}
