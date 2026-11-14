import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Weather for the weather channel: Open-Meteo forecast (free, no key, worldwide) plus active NWS alerts
/// (free, no key, US only; anything else just has no alerts). Same data source as the Archive TV app.

/// One hour of the hourly forecast.
class HourForecast {
  final DateTime time;
  final double temp;
  final int code;
  final int? rainChance;
  const HourForecast(this.time, this.temp, this.code, this.rainChance);
}

/// One day of the extended forecast.
class DayForecast {
  final DateTime date;
  final int code;
  final double hi, lo;
  final int? rainChance;
  final DateTime? sunrise, sunset;
  final double? uvMax, windMax;
  const DayForecast(this.date, this.code, this.hi, this.lo, this.rainChance,
      {this.sunrise, this.sunset, this.uvMax, this.windMax});
}

/// An active weather alert (NWS).
class WeatherAlert {
  final String event, headline;
  final DateTime? ends;
  const WeatherAlert(this.event, this.headline, this.ends);
}

class Weather {
  final String place;
  final bool imperial;

  /// When the data was fetched (the "UPDATED" note).
  final DateTime fetched;
  final double temp, feels, dew;
  final int humidity, code;
  final double windSpeed, windDir;
  final double? gusts;

  /// Pressure in inHg (imperial) or hPa; visibility in miles or km.
  final double pressure, visibility;
  final bool isDay;
  final List<HourForecast> hours;
  final List<DayForecast> days;
  final List<WeatherAlert> alerts;

  const Weather({
    required this.place,
    required this.imperial,
    required this.fetched,
    required this.temp,
    required this.feels,
    required this.dew,
    required this.humidity,
    required this.code,
    required this.windSpeed,
    required this.windDir,
    this.gusts,
    required this.pressure,
    required this.visibility,
    this.isDay = true,
    this.hours = const [],
    this.days = const [],
    this.alerts = const [],
  });

  String get condition => wmoText(code);
  String get speedUnit => imperial ? 'MPH' : 'KM/H';

  /// "SW 12" or "Calm".
  String get wind => windSpeed.round() == 0 ? 'Calm' : '${compass(windDir)} ${windSpeed.round()}';

  /// Parses an Open-Meteo `/v1/forecast` response asked for with `timeformat=unixtime` (see [WeatherFeed]) and,
  /// optionally, an NWS `/alerts/active` GeoJSON response. Missing fields read as 0 / empty, never throw on them.
  factory Weather.parse(Map<String, dynamic> meteo,
      {required String place, required bool imperial, required DateTime fetched, Map<String, dynamic>? alerts}) {
    final c = (meteo['current'] as Map?)?.cast<String, dynamic>() ?? const {};
    final h = (meteo['hourly'] as Map?)?.cast<String, dynamic>() ?? const {};
    final d = (meteo['daily'] as Map?)?.cast<String, dynamic>() ?? const {};
    double n(Object? v) => (v as num?)?.toDouble() ?? 0;
    double? opt(Object? v) => (v as num?)?.toDouble();
    Object? at(Map<String, dynamic> m, String k, int i) => (m[k] as List?)?.elementAtOrNull(i);
    DateTime? time(Object? v) => v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt() * 1000) : null;
    final hPa = n(c['pressure_msl']), metres = n(c['visibility']);
    return Weather(
      place: place,
      imperial: imperial,
      fetched: fetched,
      temp: n(c['temperature_2m']),
      feels: n(c['apparent_temperature']),
      dew: n(c['dew_point_2m']),
      humidity: n(c['relative_humidity_2m']).round(),
      code: n(c['weather_code']).round(),
      windSpeed: n(c['wind_speed_10m']),
      windDir: n(c['wind_direction_10m']),
      gusts: opt(c['wind_gusts_10m']),
      pressure: imperial ? hPa * 0.02953 : hPa,
      visibility: imperial ? metres / 1609.344 : metres / 1000,
      isDay: c['is_day'] != 0,
      hours: [
        for (var i = 0; i < ((h['time'] as List?)?.length ?? 0); i++)
          if (time(at(h, 'time', i)) case final t?)
            HourForecast(t, n(at(h, 'temperature_2m', i)), n(at(h, 'weather_code', i)).round(),
                (at(h, 'precipitation_probability', i) as num?)?.round()),
      ],
      days: [
        for (var i = 0; i < ((d['time'] as List?)?.length ?? 0); i++)
          if (time(at(d, 'time', i)) case final t?)
            DayForecast(t, n(at(d, 'weather_code', i)).round(), n(at(d, 'temperature_2m_max', i)),
                n(at(d, 'temperature_2m_min', i)), (at(d, 'precipitation_probability_max', i) as num?)?.round(),
                sunrise: time(at(d, 'sunrise', i)),
                sunset: time(at(d, 'sunset', i)),
                uvMax: opt(at(d, 'uv_index_max', i)),
                windMax: opt(at(d, 'wind_speed_10m_max', i))),
      ],
      alerts: [
        for (final f in (alerts?['features'] as List?) ?? const [])
          if ((f as Map)['properties'] case final Map p when p['event'] is String)
            WeatherAlert(p['event'] as String, (p['headline'] as String?) ?? '',
                DateTime.tryParse((p['ends'] ?? p['expires'] ?? '') as String)),
      ],
    );
  }
}

/// A named place with coordinates.
class Place {
  final String name;
  final double lat, lon;
  const Place(this.name, this.lat, this.lon);

  static const hattiesburg = Place('Hattiesburg, MS', 31.3271, -89.2903);
}

/// Fetched JSON (or an error) for one URL; replaceable in tests.
typedef GetJson = Future<Map<String, dynamic>> Function(Uri uri, Map<String, String> headers);

Future<Map<String, dynamic>> _getJson(Uri uri, Map<String, String> headers) async {
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await c.getUrl(uri);
    headers.forEach(req.headers.set);
    final res = await req.close().timeout(const Duration(seconds: 15));
    final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}', uri: uri);
    return jsonDecode(body) as Map<String, dynamic>;
  } finally {
    c.close(force: true);
  }
}

/// The weather channel's data: the last good report ([current]), cached in [cacheFile] so a restart shows
/// it at once, refreshed when older than [maxAge]. A failed refresh keeps the last good report (the screens
/// show its "updated" time) and is logged; nothing here throws.
class WeatherFeed {
  final Place place;
  final bool imperial;
  final File? cacheFile;
  final Duration maxAge;
  final void Function(String)? log;
  final GetJson _get;
  final DateTime Function() _clock;

  Weather? current;
  Future<void>? _refreshing;

  WeatherFeed(this.place,
      {this.imperial = true,
      this.cacheFile,
      this.maxAge = const Duration(minutes: 15),
      this.log,
      GetJson? get,
      DateTime Function()? clock})
      : _get = get ?? _getJson,
        _clock = clock ?? DateTime.now {
    try {
      final f = cacheFile;
      if (f != null && f.existsSync()) {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        if (j['key'] == _key) current = _parse(j);
      }
    } on Object catch (e) {
      log?.call('weather: cache unreadable: $e');
    }
  }

  static const _ua = {'User-Agent': 'ArchiveTV-Server/0.1 (personal retro TV tuner)'};

  String get _key => '${place.lat},${place.lon},${imperial ? 'imperial' : 'metric'}';

  Weather _parse(Map<String, dynamic> j) => Weather.parse((j['meteo'] as Map).cast<String, dynamic>(),
      place: place.name,
      imperial: imperial,
      fetched: DateTime.parse(j['fetched'] as String),
      alerts: (j['alerts'] as Map?)?.cast<String, dynamic>());

  bool get stale => current == null || _clock().difference(current!.fetched) >= maxAge;

  Uri get forecastUri => Uri.https('api.open-meteo.com', '/v1/forecast', {
        'latitude': '${place.lat}',
        'longitude': '${place.lon}',
        'current': 'temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,'
            'wind_direction_10m,wind_gusts_10m,pressure_msl,visibility,dew_point_2m,is_day',
        'hourly': 'temperature_2m,weather_code,precipitation_probability',
        'daily': 'weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset,'
            'uv_index_max,wind_speed_10m_max',
        'temperature_unit': imperial ? 'fahrenheit' : 'celsius',
        'wind_speed_unit': imperial ? 'mph' : 'kmh',
        'timezone': 'auto',
        'timeformat': 'unixtime',
        'forecast_days': '7',
        'forecast_hours': '24',
      });

  Uri get alertsUri =>
      Uri.https('api.weather.gov', '/alerts/active', {'point': '${place.lat.toStringAsFixed(4)},${place.lon.toStringAsFixed(4)}'});

  /// Fetches new data (one refresh at a time). Returns when done or failed.
  Future<void> refresh() => _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  /// [refresh] when [stale]; does not wait.
  void refreshIfStale() {
    if (stale) unawaited(refresh());
  }

  Future<void> _refresh() async {
    final Map<String, dynamic> meteo;
    try {
      meteo = await _get(forecastUri, _ua);
    } on Object catch (e) {
      log?.call('weather: Open-Meteo failed, keeping the last report: $e');
      return;
    }
    Map<String, dynamic>? alerts;
    try {
      alerts = await _get(alertsUri, {..._ua, 'Accept': 'application/geo+json'});
    } on Object catch (e) {
      log?.call('weather: no NWS alerts ($e)');
    }
    final j = {'key': _key, 'fetched': _clock().toIso8601String(), 'meteo': meteo, 'alerts': alerts};
    try {
      current = _parse(j);
    } on Object catch (e) {
      log?.call('weather: bad Open-Meteo data, keeping the last report: $e');
      return;
    }
    try {
      final f = cacheFile;
      if (f != null) {
        final tmp = File('${f.path}.tmp')..writeAsStringSync(jsonEncode(j));
        tmp.renameSync(f.path);
      }
    } on Object catch (e) {
      log?.call('weather: could not save the cache: $e');
    }
  }
}

String compass(double deg) => const ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'][((deg % 360) / 45).round() % 8];

/// WMO weather code to short TV wording (the app's wording).
String wmoText(int code) => switch (code) {
      0 => 'Sunny',
      1 => 'Mostly Sunny',
      2 => 'Partly Cloudy',
      3 => 'Cloudy',
      45 || 48 => 'Fog',
      51 || 53 || 55 || 56 || 57 => 'Drizzle',
      61 || 63 || 66 || 80 || 81 => 'Rain',
      65 || 67 || 82 => 'Heavy Rain',
      71 || 73 || 75 || 77 || 85 || 86 => 'Snow',
      95 || 96 || 99 => 'T-Storms',
      _ => 'Unknown',
    };
