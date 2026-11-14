import 'dart:async';
import 'dart:io';

import 'package:guidechannel/guidechannel.dart';

/// How the server uses the package: one GuideChannel, MPEG-TS read from [GuideChannel.output],
/// snapshot swapped on a timer without restarting the stream.
/// Usage: dart run example/api_example.dart SNAPSHOT.json OUT.ts [SECONDS] [FFMPEG]
Future<void> main(List<String> args) async {
  final file = File(args[0]);
  final g = GuideChannel(Snapshot.parse(file.readAsStringSync()),
      ffmpeg: args.length > 3 ? args[3] : 'ffmpeg', log: stderr.writeln);
  await g.start();
  final sink = File(args[1]).openWrite();
  final piping = sink.addStream(g.output);

  var swaps = 0;
  final refresh = Timer.periodic(const Duration(seconds: 2), (_) {
    g.snapshot = Snapshot.parse(file.readAsStringSync()); // the server would build this from its scheduler
    swaps++;
  });
  await Future<void>.delayed(Duration(seconds: args.length > 2 ? int.parse(args[2]) : 6));
  refresh.cancel();
  await g.stop();
  await piping;
  await sink.close();
  stderr.writeln('wrote ${File(args[1]).lengthSync()} bytes, $swaps snapshot swaps');
}
