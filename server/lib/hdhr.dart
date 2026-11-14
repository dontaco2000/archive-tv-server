import 'dart:convert';

import 'package:archive_tv_core/archive_tv_core.dart';

/// HDHomeRun HTTP API bodies, the subset Plex reads. [base] is like `http://<server-ip>:8100`.
const deviceId = '1A7C0001';

String discoverJson(String base, int tuners) => jsonEncode({
      'FriendlyName': 'Archive TV',
      'Manufacturer': 'Silicondust',
      'ModelNumber': 'HDTC-2US',
      'FirmwareName': 'hdhomeruntc_atsc',
      'FirmwareVersion': '20200101',
      'DeviceID': deviceId,
      'DeviceAuth': 'archivetv',
      'TunerCount': tuners,
      'BaseURL': base,
      'LineupURL': '$base/lineup.json',
    });

String lineupJson(String base, List<Channel> channels) => jsonEncode([
      for (final c in channels) {'GuideNumber': '${c.number}', 'GuideName': c.name, 'URL': '$base/auto/v${c.number}'},
    ]);

String lineupStatusJson() =>
    jsonEncode({'ScanInProgress': 0, 'ScanPossible': 1, 'Source': 'Cable', 'SourceList': ['Cable']});

String deviceXml(String base) => '''<?xml version="1.0" encoding="UTF-8"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <URLBase>$base</URLBase>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>
    <friendlyName>Archive TV</friendlyName>
    <manufacturer>Silicondust</manufacturer>
    <modelName>HDTC-2US</modelName>
    <modelNumber>HDTC-2US</modelNumber>
    <serialNumber>$deviceId</serialNumber>
    <UDN>uuid:$deviceId-0000-0000-0000-000000000000</UDN>
  </device>
</root>
''';
