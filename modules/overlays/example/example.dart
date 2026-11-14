import 'package:archive_tv_overlays/archive_tv_overlays.dart';

/// Prints the ffmpeg arguments for channel 12 WARP, freshly tuned, late-night window open.
void main() {
  final g = buildFilterGraph(const OverlayParams(
    number: 12,
    name: 'Warp',
    logoPath: '/opt/archivetv-server/data/logos/warp.png',
    watermarkPath: '/opt/archivetv-server/assets/wm_native3_50.png',
    lateNight: true,
    crop: CropRect(106, 0, 640, 480), // from cropProbeArgs + CropDecider
  ));
  print([
    'ffmpeg',
    '-re',
    '-ss',
    '1234',
    '-i',
    'https://archive.org/download/item/file.mp4',
    ...g.args,
    '-c:v',
    'libx264',
    '-preset',
    'veryfast',
    '-c:a',
    'aac',
    '-f',
    'mpegts',
    'pipe:1'
  ].join(' '));
  print(tuneBannerCommands(1800).join());
}
