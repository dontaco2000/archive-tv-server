<p align="center"><img src="docs/banner.png" alt="Archive TV Server: Plex Live TV tuner for Archive TV" width="720"></p>

<p align="center">
<a href="https://github.com/dontaco2000/archive-tv/releases/latest"><img alt="Archive TV app release" src="https://img.shields.io/github/v/release/dontaco2000/archive-tv?color=f87d28&label=app%20release"></a>
<a href="LICENSE"><img alt="License: GPL-3.0" src="https://img.shields.io/badge/license-GPL--3.0-3fa7a0"></a>
<img alt="Runs on Linux" src="https://img.shields.io/badge/runs%20on-Linux%20x64-5a3a22">
</p>

# Archive TV Server

A **Plex Live TV source** for the [Archive TV](https://github.com/dontaco2000/archive-tv) channels. It pretends to be an HDHomeRun network tuner and serves an XMLTV guide, so every Plex client (TV apps, phones, Plex Web) can watch the Archive TV channels under **Live TV**, with a full programme guide, and nothing extra to install on the viewing devices.

Looking for the app itself (Windows, Fire TV, Android)? Get the [latest Archive TV release](https://github.com/dontaco2000/archive-tv/releases/latest).

- ~60 clock-synced channels (cartoons, movies, sitcoms, game shows, news, music videos, sports, ...), the same schedule logic as the Archive TV app.
- XMLTV guide 7 days ahead with channel logos, genres, marathons and themed blocks.
- Each channel is encoded live by ffmpeg into one steady format (640x480 4:3, H.264 + AAC MPEG-TS), so Plex never sees a codec change between programmes.
- Burned-in Archive TV watermark with channel number and name, STAND BY / BUILDING cards, and channel **99 Guide**: a Prevue-style scrolling listings channel.
- Channel **41 Cumulus**: a local weather channel (current conditions, hourly, today, extended forecast, NWS alerts). The Guide and Cumulus play smooth-jazz background music from the Internet Archive, like the app's weather channel.
- Dead-link checker, daily pool refresh, night-only adult blocks (see below).

## Content disclaimer

**We are not responsible for the content.** All video and audio comes from the Internet Archive (archive.org) and its uploaders. Archive TV Server only indexes and plays it. Archive TV is **not affiliated with or endorsed by the Internet Archive.** Weather data comes from Open-Meteo and the US National Weather Service (weather.gov) and may be wrong or late: don't rely on it for safety decisions. Some channels (such as Headliner, Teaser, Haunt and Bedlam) and the night-time blocks on many others can include mature content (strong language, violence, crude humor, sports like MMA). R-rated programmes air only in a late-night window (22:00 to 05:00 by default) and can be switched off completely (`late_night_adult_mode = false`, see Settings). Use Plex's own managed-user restrictions for anything stricter.

## Requirements

- **Plex Media Server with Live TV & DVR.** Plex Live TV & DVR needs a Plex Pass (check Plex's current terms).
- **A Linux x64 machine on the same LAN as Plex** (it can be the Plex machine itself). Tested on Ubuntu 22.04.
- **ffmpeg with https support**, installed at `/opt/archivetv-server/bin/ffmpeg` (any path works with `--ffmpeg`). Use a recent build: the server was tested with the [BtbN FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds/releases) `n8.1` `linux64-gpl` static build. The johnvansickle.com static build **segfaults on every https input** (static-glibc DNS problem), so don't use that one. Ubuntu's own ffmpeg 4.4 works for plain streaming but lacks some filters newer features use.
- **Fonts:** `fonts-dejavu-core` (Ubuntu: `sudo apt install fonts-dejavu-core`) for the overlays and STAND BY cards.
- **Internet access:** every channel streams from archive.org; the weather channel also reads api.open-meteo.com and api.weather.gov.
- **CPU:** about 0.75-0.9 of a CPU core per channel being watched (software x264, `veryfast`, measured on a 2012 AMD FX-4300). 4 tuners by default, i.e. up to 4 channels at once (the Guide and weather channels count as one each; they cost less than a programme channel: a mostly still picture plus an mp3 decoder for the music); lower `tuners` on a weak box, and remember Plex may also transcode for some clients.
- **Disk:** a few hundred MB for the data folder (channel pools, saved days, item titles, dead-link lists); allow 1 GB. No video is stored.
- **Port:** TCP 8100 (change with `--port`), reachable from the Plex server.

## Build

You need the [Dart SDK](https://dart.dev/get-dart) 3.5 or newer (the one inside Flutter works too). You can build on any OS; the server cross-compiles to Linux x64.

```
cd server
dart pub get
dart test
dart compile exe bin/server.dart --target-os linux --target-arch x64 -o build/archivetv-server
```

`dart pub get` fetches the Archive TV core (channels, pools, scheduler) from the app repository, [dontaco2000/archive-tv](https://github.com/dontaco2000/archive-tv) (`core/` folder), as a git dependency.

To work against a local checkout of the app instead, create `server/pubspec_overrides.yaml` (git-ignored):

```yaml
dependency_overrides:
  archive_tv_core:
    path: /path/to/archive-tv/core
```

## Install on the Linux box

1. Create a service user and the folders:
   ```
   sudo useradd --system --create-home archivetv
   sudo mkdir -p /opt/archivetv-server/bin
   sudo chown -R archivetv: /opt/archivetv-server
   ```
2. Copy the files (from your build machine, `<server-ip>` = the Linux box):
   - `server/build/archivetv-server` to `/opt/archivetv-server/archivetv-server` (`chmod +x`)
   - the whole `server/config` folder to `/opt/archivetv-server/config`
   - your ffmpeg (and ffprobe) to `/opt/archivetv-server/bin/`
3. Install the systemd unit (edit `User=` if you used another user):
   ```
   sudo cp archivetv-server.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now archivetv-server
   journalctl -u archivetv-server -f
   ```
4. Check it: open `http://<server-ip>:8100/discover.json`, `/lineup.json` and `/status` in a browser.

**First start builds the channel pools** (lists of playable Archive files per channel) from archive.org. This takes several minutes; until a channel's pool is ready it shows a BUILDING / STAND BY card. Pools are saved in `/opt/archivetv-server/data` and refreshed daily at 00:01.

Command-line options (all optional; defaults shown): `--port 8100 --config /opt/archivetv-server/config --data /opt/archivetv-server/data --ffmpeg /opt/archivetv-server/bin/ffmpeg --tuners 4`. `--load-only` (no pool rebuilds or link checks) and `--no-refresh` are for testing.

### Updating with deploy.sh

`deploy.sh` runs the tests, cross-compiles, copies the binary + `config/` over SSH and restarts the service (the previous binary is kept as `archivetv-server.prev`; `data/` and `config/settings.txt` are never touched):

```
./deploy.sh me@<server-ip> /opt/archivetv-server
# or: ATV_HOST=me@<server-ip> ATV_DIR=/opt/archivetv-server ./deploy.sh
```

It needs SSH key login and passwordless `sudo systemctl restart archivetv-server` for that user.

## Plex setup

1. In Plex: **Settings > Live TV & DVR > Set Up Plex DVR**. If the tuner is not found automatically, choose to enter the device address manually: `<server-ip>:8100`.
2. Plex shows "Archive TV" with 4 tuners. Continue.
3. **Guide:** choose to use an XMLTV guide and enter `http://<server-ip>:8100/guide.xml`.
4. **Channels:** Plex suggests a mapping; every channel should map to the guide channel with the same number. Keep them all enabled and finish.
5. Live TV now appears in every Plex client. Tuning takes a few seconds (the server starts ffmpeg, then Plex buffers).

### Gotcha: never fetch guide.xml via localhost

The logo (icon) URLs inside `guide.xml` are built from the host name the client used. Plex refuses `localhost` icon URLs, and the guide is cached per address, so always use the LAN address: `curl http://<server-ip>:8100/guide.xml`, not `curl http://localhost:8100/guide.xml`. If you test on the server itself, add the header: `curl -H "Host: <server-ip>:8100" http://localhost:8100/guide.xml`.

### After the channel list changes

When channels are added or removed (a new `channels.json`):

1. Reload the guide: Settings > Live TV & DVR > your Archive TV DVR > refresh the guide.
2. Fix the channel map: in the same DVR's settings open the channel list, then enable and map the new channels.

If the Plex UI keeps an old mapping, you can set it through Plex's API. You need your **Plex token** (Plex support article "Finding an authentication token / X-Plex-Token"). **Never share your Plex token or paste it anywhere public**; it gives full access to your Plex server.

```
TOKEN=<your-plex-token>
PLEX=http://<plex-ip>:32400
# 1. Find the device key of the Archive TV tuner ("key" attribute of the Device):
curl -s "$PLEX/media/grabbers/devices?X-Plex-Token=$TOKEN"
# 2. Build "enable every channel and map n to n" from the tuner's lineup:
Q=$(curl -s http://<server-ip>:8100/lineup.json | grep -o '"GuideNumber":"[0-9]*"' | grep -o '[0-9]*' \
    | awk '{e=e (e?",":"") $1; m=m "&channelMapping%5B" $1 "%5D=" $1}
           END{print "channelsEnabled=" e m}')
# 3. Apply it (replace <device-key>) and reload the guide (<dvr-id> from $PLEX/livetv/dvrs):
curl -X PUT "$PLEX/media/grabbers/devices/<device-key>/channelmap?$Q&X-Plex-Token=$TOKEN"
curl -X POST "$PLEX/livetv/dvrs/<dvr-id>/reloadGuide?X-Plex-Token=$TOKEN"
```

## Updating the channels

The channel lineup is the Archive TV app's own config. When the app changes it, copy from the app repo into `server/config/` (or straight into `/opt/archivetv-server/config/`):

- `player/assets/channels.json` -> `config/channels.json`
- `player/assets/rated.json` -> `config/rated.json`
- `player/assets/renumber_map.json` -> `config/renumber_map.json` (when channels were renumbered; the server moves saved pools to the new numbers on start)
- `player/assets/logos/*.png` (4:3 PNGs named by lower-case channel name, e.g. `funnies.png`) -> `config/logos/`

Then restart the service (or run `deploy.sh`) and do "After the channel list changes" above. Changed channels rebuild at the next daily refresh; to rebuild one now, delete `data/pools/pool-<n>.json` and restart.

The weather channel (Cumulus, the `weatherstar` channel in `channels.json`) is drawn natively by the server, not the app's WeatherStar 4000+ web page (no browser on the server): current conditions, hourly forecast, today (sunrise/sunset, UV, wind), extended forecast and active NWS alerts, each screen holding about 9 seconds. Weather data comes from [Open-Meteo](https://open-meteo.com) (no key) and, in the US, weather.gov alerts; it refreshes every 15 minutes while someone watches and is cached in `data/weather.json` (a failed refresh keeps the last report and shows its "updated" time). Its music sources (the Archive item `smooth-jazz-fm-1991`) are also the Guide channel's music; the track list is built once a day and saved in `data/music/`.

## Settings

`/opt/archivetv-server/config/settings.txt` (`key = value`, `#` comments). Created with defaults on first start, never overwritten by updates. Apply changes with `sudo systemctl restart archivetv-server`. A bad value is ignored (default used, warning logged).

| Key | Default | Meaning |
|---|---|---|
| `late_night_adult_mode` | `true` | `true`: R-rated programmes air only in the late-night window, with an R rating in the guide. `false`: they never air. |
| `late_night_start` / `late_night_end` | empty | Window as `HH:MM` local time. Empty = the window in `rated.json` (22:00 to 05:00). |
| `tuners` | `4` | Channels that can play at once (1-8). The Guide channel counts as one. |
| `overlays` | `true` | Master switch for all burned-in overlays below. |
| `watermark` | `true` | Archive TV watermark, bottom-right, 50% opacity. |
| `watermark_label` | `true` | Channel number and name under the watermark. |
| `rated_watermark` | `true` | The watermark's TV shows an R during R-rated programmes. |
| `tune_banner` / `tune_banner_seconds` | `false` / `4` | Channel banner top-left for a few seconds after tuning in. |
| `corner_bug` | `false` | Small logo + channel number top-left all the time. |
| `discretion_card` | `false` | VIEWER DISCRETION ADVISED card when an R programme starts. |
| `discretion_strip` | `false` | VIEWER DISCRETION ADVISED strip when tuning in during an R programme. |
| `late_night_notice` | `false` | LATE NIGHT ADULT MODE line on banners and cards during the window. |
| `guide_channel` | `true` | Channel 99 "Guide": scrolling listings of every channel. |
| `guide_music` | `true` | Smooth-jazz background music on the Guide (the app's weather music, from the Internet Archive). |
| `weather_channel` | `true` | The weather channel (41 Cumulus). |
| `weather_music` | `true` | Smooth-jazz background music on the weather channel. |
| `weather_location` | `Hattiesburg, MS; 31.3271, -89.2903` | Place name; latitude, longitude (decimal degrees). |
| `weather_units` | `imperial` | `imperial` (F, mph, inHg, miles) or `metric` (C, km/h, hPa, km). |

Times (late-night window, guide and weather channel clocks, hourly forecast) use the server's local time zone: set the box to the viewers' time zone.

## Troubleshooting

- **Logs:** `journalctl -u archivetv-server -f`. Status page: `http://<server-ip>:8100/status` (sessions, pool states, dead links).
- **Channel shows BUILDING / STAND BY:** its pool is still being built (first start or a new channel), or archive.org is slow. Wait a few minutes.
- **NO SIGNAL / skips:** an Archive item failed; the server retries once, then skips it. Items that keep failing are marked dead and rechecked weekly.
- **"All tuners in use" in Plex:** all tuners are busy. Each channel keeps its tuner 30 s after the last viewer leaves. Raise `tuners` only if the CPU can take it.
- **No video at all / ffmpeg crashes on https:** wrong ffmpeg build (see Requirements). Test: `/opt/archivetv-server/bin/ffmpeg -i https://archive.org/ -f null -` should not segfault.
- **Missing channel logos in Plex:** guide.xml was fetched via `localhost` (see the gotcha above); reload the guide from Plex.
- **New channels missing in Plex:** re-map channels (see "After the channel list changes").
- **Plex Web has no channel up/down:** that is a Plex client limit; use the guide.
- **Rollback:** `cd /opt/archivetv-server && cp archivetv-server.prev archivetv-server && sudo systemctl restart archivetv-server`.
- **Uninstall:** `sudo systemctl disable --now archivetv-server; sudo rm /etc/systemd/system/archivetv-server.service; sudo systemctl daemon-reload; sudo rm -rf /opt/archivetv-server`, then delete the DVR in Plex (Settings > Live TV & DVR).

## Repository layout

- `server/`: the Dart server (HDHomeRun API, XMLTV, stream engine, settings) and its `config/` (channels, rated list, renumber map, logos, watermark).
- `modules/overlays/`: ffmpeg filter graphs for the burned-in overlays.
- `modules/guidechannel/`: the Prevue-style Guide channel renderer and the weather channel (data + screens).
- `deploy.sh`, `archivetv-server.service`: deployment helpers.

## How it relates to the app

[Archive TV](https://github.com/dontaco2000/archive-tv) is the Windows/Android app. This server reuses its pure-Dart core (channel config, pools, deterministic scheduler, guide blocks, dead-link checker), so a channel on the server airs the same kind of schedule as in the app. The app's interactive guide, menu, remote and On Demand do not exist inside Plex; Plex draws its own guide. The weather channel on Plex is a simplified native rendering (fixed screens, no radar), not the WeatherStar 4000+ page the app shows.

## Porting and forks

Archive TV Server is licensed under the **GNU General Public License v3.0** (see `LICENSE`). If you port it to another platform or modify it, the GPL requires that you share your source under the same license. We ask that you publish your port as a **fork of this project** so improvements stay connected.

## Credits

- [Internet Archive](https://archive.org): all video and audio.
- [FFmpeg](https://ffmpeg.org) and x264: encoding and streaming.
- [Plex](https://www.plex.tv) Live TV & DVR, and the HDHomeRun network tuner API it understands (Archive TV Server is not affiliated with Plex or SiliconDust).
- [Dart](https://dart.dev) and the [image](https://pub.dev/packages/image) package.
- DejaVu fonts.
