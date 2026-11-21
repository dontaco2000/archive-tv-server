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

  /// Smooth-jazz background music (the app's weather-channel music) on the guide / the weather channel.
  final bool guideMusic, weatherMusic;

  /// The weather channel (Cumulus, the weather channel of channels.json): native weather screens.
  final bool weatherChannel;

  /// Its place: name and coordinates (default Hattiesburg, MS).
  final String weatherName;
  final double weatherLat, weatherLon;

  /// false = metric (Celsius, km/h, hPa, km).
  final bool weatherImperial;

  /// Programme pictures in the XMLTV guide (Archive thumbnails as posters, else the channel card).
  final bool programmeThumbs;

  /// true (direct, default) = icons point at archive.org (Plex fetches them; known-bad items get none);
  /// false (server) = our /thumb posters (Plex refuses LAN image URLs, so only for other clients).
  final bool programmeThumbsDirect;

  /// Public folder of square channel cards `<n>.jpg` used as the XMLTV channel icons (Plex refuses LAN image
  /// URLs, so its Recent Channels tiles stay black with the server's own /logos). Empty = the server's /logos.
  final String channelIconBase;

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
    this.guideMusic = true,
    this.weatherMusic = true,
    this.weatherChannel = true,
    this.weatherName = 'Hattiesburg, MS',
    this.weatherLat = 31.3271,
    this.weatherLon = -89.2903,
    this.weatherImperial = true,
    this.programmeThumbs = true,
    this.programmeThumbsDirect = true,
    this.channelIconBase = 'https://raw.githubusercontent.com/dontaco2000/archive-tv-server/main/cards',
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
# Smooth-jazz background music on the Guide (the app's weather music, from the Internet Archive).
guide_music = true

# Weather channel (Cumulus): current conditions, hourly, today, extended forecast and NWS alerts
# (Open-Meteo + weather.gov, no key), with the same smooth-jazz music.
weather_channel = true
weather_music = true
# Place name; latitude, longitude (decimal degrees, e.g. from latlong.net).
weather_location = Hattiesburg, MS; 31.3271, -89.2903
# imperial (F, mph, inHg, miles) or metric (C, km/h, hPa, km).
weather_units = imperial

# Programme pictures in the Plex guide ("On Now" tiles): the Archive item's thumbnail as a poster with the
# channel badge, or the channel card when the item has no usable picture. false = no programme pictures.
programme_thumbs = true
# direct: the picture comes straight from archive.org (items without a usable picture get none).
# server: this server's posters with the channel badge (Plex refuses to load pictures from LAN addresses).
programme_thumbs_mode = direct
# Channel pictures (Plex "Recent Channels" tiles): a PUBLIC folder holding <number>.jpg squares (made with
# `dart run tool/export_cards.dart`). Plex refuses LAN addresses, so this must be a public URL. Empty = this
# server's /logos (works for non-Plex clients only).
channel_icon_base = https://raw.githubusercontent.com/dontaco2000/archive-tv-server/main/cards
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
    var (wName, wLat, wLon) = ('Hattiesburg, MS', 31.3271, -89.2903);
    if (kv['weather_location'] case final v? when v.isNotEmpty) {
      final m = RegExp(r'^(.+);\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)$').firstMatch(v);
      final lat = m == null ? null : double.parse(m[2]!), lon = m == null ? null : double.parse(m[3]!);
      if (lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180 || m![1]!.trim().isEmpty) {
        warn.add('weather_location = "$v" is not "Name; lat, lon", using Hattiesburg, MS');
      } else {
        (wName, wLat, wLon) = (m[1]!.trim(), lat, lon);
      }
    }
    var thumbsDirect = true;
    if (kv['programme_thumbs_mode'] case final v? when v.isNotEmpty) {
      if (v.toLowerCase() == 'server') {
        thumbsDirect = false;
      } else if (v.toLowerCase() != 'direct') {
        warn.add('programme_thumbs_mode = "$v" is not direct/server, using direct');
      }
    }
    final iconBase = (kv['channel_icon_base'] ?? 'https://raw.githubusercontent.com/dontaco2000/archive-tv-server/main/cards').trim().replaceAll(RegExp(r'/+$'), '');
    var imperial = true;
    if (kv['weather_units'] case final v? when v.isNotEmpty) {
      if (v.toLowerCase() == 'metric') {
        imperial = false;
      } else if (v.toLowerCase() != 'imperial') {
        warn.add('weather_units = "$v" is not imperial/metric, using imperial');
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
      guideMusic: flag('guide_music', true),
      weatherMusic: flag('weather_music', true),
      weatherChannel: flag('weather_channel', true),
      weatherName: wName,
      weatherLat: wLat,
      weatherLon: wLon,
      weatherImperial: imperial,
      programmeThumbs: flag('programme_thumbs', true),
      programmeThumbsDirect: thumbsDirect,
      channelIconBase: iconBase,
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
      'discretion_strip=$discretionStrip, late_night_notice=$lateNightNotice, guide_channel=$guideChannel, guide_music=$guideMusic, '
      'weather_channel=$weatherChannel, weather_music=$weatherMusic, weather_location=$weatherName; $weatherLat, $weatherLon, '
      'weather_units=${weatherImperial ? 'imperial' : 'metric'}, programme_thumbs=$programmeThumbs, '
      'programme_thumbs_mode=${programmeThumbsDirect ? 'direct' : 'server'}, channel_icon_base=$channelIconBase';
}
