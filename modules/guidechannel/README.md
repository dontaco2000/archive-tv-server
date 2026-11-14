# guidechannel

Prevue-style guide channel for Archive TV Server: a continuously running 640x480 (4:3) h264/aac
MPEG-TS stream of a scrolling TV listings grid (Archive TV wordmark + ticking clock, now/next info
strip with channel logo, 90-minute grid in 30-minute columns, NOW cells highlighted, pages that
hold 7 s and slide 1 s, looping forever, with an end-of-listings banner carrying the content disclaimer).

Standalone: depends only on `package:image` (bitmap Arial fonts, PNG). Needs `ffmpeg` (4.4+ with libx264).

## Snapshot schema (version 1)

```json
{
  "version": 1,
  "generated": "2026-11-13T01:00:00.000Z",
  "channels": [
    {
      "number": 2,
      "name": "Funnies",
      "genre": "Kids & Animation",
      "logo": "/opt/archivetv-server/logos/4x3/funnies.png",
      "programmes": [
        {"start": "2026-11-13T00:42:33.730Z", "end": "2026-11-13T01:00:00.000Z", "title": "Shorts"}
      ]
    }
  ]
}
```

- `channels` in display order. `genre` (optional) tints the channel cell (Archive TV app palette).
  `logo` (optional) is a local PNG path, shown in the info strip; missing/broken files are ignored.
- `programmes`: ISO 8601 instants, any order (sorted on load), titles already cleaned for display
  (guide blocks like "Spider-Man Marathon", "More Trailers"). Cover from the current half hour to
  ~6 hours ahead. Non-ASCII is mapped/dropped (bitmap fonts are ASCII).
- Times are drawn in the process's local time zone (run the server with the viewers' TZ).

Dart classes: `Snapshot`, `GuideChannelInfo`, `Programme` (`lib/src/snapshot.dart`).

## CLI

```
dart run bin/guidechannel.dart --snapshot snap.json [--out out.ts|stdout] [--fps 15] [--duration N]
    [--fast] [--start ISO] [--refresh 60] [--ffmpeg PATH] [--preset veryfast] [--png DIR --shots 0,7.5]
```

Default is live: frames paced to the wall clock, MPEG-TS on stdout, snapshot file re-read every 60 s.

## API

```dart
final g = GuideChannel(snapshot, ffmpeg: '/usr/bin/ffmpeg');
await g.start();                 // MPEG-TS on g.output (Stream<List<int>>)
g.snapshot = newSnapshot;        // any time, no restart
await g.stop();
```

`GuideRenderer` alone gives frames (`frame` RGB24, `frameYuv` yuv420p, `frameImage` for PNGs).

## Real-data snapshot (dev)

`tool/make_snapshot` is a separate tiny package (git dependency on the Archive TV app core) so this
package stays independent of app code:

```
cd tool/make_snapshot
dart run bin/make_snapshot.dart "<channels.json>" "<pools dir>" ["<Logos\4x3 dir>"] [hours] > ../../example/snapshot.json
```

## Header logo

`lib/src/header_logo.dart` embeds `assets/header_logo.png` (Archive TV branding `logo-wordmark.png`
scaled to 208x78). Regenerate with `tool/make_logo.sh`.
