// Writes every channel's square card (400x400 JPEG, named <number>.jpg) for hosting on GitHub:
//   dart run tool/export_cards.dart <configDir> <outDir>
// Plex refuses LAN image URLs, so the guide's channel icons point at these public files (settings: channel_icon_base).
import 'dart:io';
import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:image/image.dart' as img;
import '../lib/guide.dart';
import '../lib/thumbs.dart';

void main(List<String> a) {
  final cfg = a[0], out = Directory(a[1])..createSync(recursive: true);
  final config = parseChannelConfig(File('$cfg/channels.json').readAsStringSync());
  for (final c in [...config.channels, guideChannel]) {
    final p = logoPath(cfg, c);
    final logo = File(p).existsSync() ? img.decodeImage(File(p).readAsBytesSync()) : null;
    File('${out.path}/${c.number}.jpg').writeAsBytesSync(img.encodeJpg(img.copyResize(drawCard(c, logo, square: true), width: 400, interpolation: img.Interpolation.average), quality: 85));
  }
  stdout.writeln('wrote ${out.listSync().length} cards to ${out.path}');
}
