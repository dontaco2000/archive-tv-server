/// Builds the ffmpeg filter graph that burns Archive TV's overlays into a channel stream.
/// Pure functions: no I/O, same input -> same output.
library;

import 'crop.dart';

// ---- Wording and palette (same as the Archive TV app, tv_screen.dart / tv_engine.dart).
const standBy = 'STAND BY'; // drawn with animated dots
const building = 'BUILDING...';
const noSignal = 'NO SIGNAL';
const offAir = 'OFF AIR';
const buildModeNotice = 'This channel is in its build mode,\nplease choose another channel for now.';
const lateNightLine = 'LATE NIGHT ADULT MODE';
const discretionLine = 'VIEWER DISCRETION ADVISED';
const matureLine = 'MATURE CONTENT (R)';

const _navy = '0x101A5C', _cardBg = '0x0A0A3A', _yellow = '0xFFEB3B', _amber = '0xFFB300', _blue = '0x9EC8FF';

/// Seconds the tune banner and the viewer-discretion notice stay up (app: 6 s).
const bannerSeconds = 6;

/// fonts-dejavu-core on Ubuntu. Monospace, like the app's Consolas; layout assumes a monospace font.
const defaultFontFile = '/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf';

/// Advance of one character as a share of the font size (DejaVu Sans Mono: 1233/2048).
const _adv = 0.602;

class OverlayParams {
  final int number;
  final String name;

  /// Channel logo PNG (1024x768 transparent), or null.
  final String? logoPath;

  /// Seconds since the viewer tuned when this ffmpeg starts: 0 for a fresh tune; when the engine restarts
  /// ffmpeg for the same viewer (next item), pass the real figure so the banner doesn't come back.
  final double secondsSinceTune;

  /// The slot is inside the channel's late-night (rated) window: LATE NIGHT ADULT MODE line on the banner/cards.
  final bool lateNight;

  /// The programme is R-rated (app: TvEngine.showsRated): R badge + viewer-discretion notice.
  final bool mature;

  /// How far into the current programme the stream starts. Under 15 s the discretion notice is the full
  /// card (programme just starting), otherwise a strip (joined mid-way), like the app.
  final double secondsIntoProgramme;

  /// Non-null: draw the full-frame card instead of video ([standBy] animates its dots).
  final String? message;

  /// Black-bar crop for this item (from [cropProbeArgs] + [CropDecider]), or null. Fixed for the life of
  /// the process: a crop can't be changed live (the scale/pad after it is sized at graph setup).
  final CropRect? crop;

  /// Archive TV watermark PNG (assets/wm_native3_50.png), or null for none.
  final String? watermarkPath;
  final bool watermark;

  /// Small text under the watermark's "ArchiveTV" (e.g. "12 WARP"), same look and opacity; null = none.
  final String? watermarkLabel;

  /// Tiny channel logo next to the persistent number bug.
  final bool bugLogo;

  /// Each element on/off (all on by default = the full look). Off elements stay in the graph with enable=0.
  final bool tuneBanner, cornerBug, ratedBadge, discretionCard, discretionStrip;

  /// How long the tune banner stays up.
  final num bannerSeconds;

  /// A smaller tune banner (64x48 logo, 20 px name).
  final bool compactBanner;

  /// Where the LATE NIGHT ADULT MODE line goes: under the name on the tune banner, and/or on the
  /// viewer-discretion card (above VIEWER DISCRETION ADVISED).
  final bool lateNightInBanner, lateNightInCard;

  const OverlayParams({
    required this.number,
    required this.name,
    this.logoPath,
    this.secondsSinceTune = 0,
    this.lateNight = false,
    this.mature = false,
    this.secondsIntoProgramme = 0,
    this.message,
    this.crop,
    this.watermarkPath,
    this.watermark = true,
    this.watermarkLabel,
    this.bugLogo = true,
    this.tuneBanner = true,
    this.cornerBug = true,
    this.ratedBadge = true,
    this.discretionCard = true,
    this.discretionStrip = true,
    this.bannerSeconds = 6,
    this.compactBanner = false,
    this.lateNightInBanner = true,
    this.lateNightInCard = false,
  });

  /// As in the app, the R badge and the discretion notice follow the programme, not the time of day.
  bool get rated => mature;
}

class OverlayGraph {
  /// Input arguments to add. Video mode: extra `-i` after the source (which must be input 0).
  /// Card mode: the whole input list (the card needs no source).
  final List<String> inputArgs;
  final String filterComplex;

  /// `-map` for video and audio.
  final String videoMap, audioMap;
  const OverlayGraph(this.inputArgs, this.filterComplex, {this.videoMap = '[vout]', required this.audioMap});

  /// `[...inputArgs, -filter_complex, graph, -map, v, -map, a]`.
  List<String> get args => [...inputArgs, '-filter_complex', filterComplex, '-map', videoMap, '-map', audioMap];
}

/// Escapes [s] as a filter option value inside a -filter_complex string (both escaping levels of
/// ffmpeg's "Notes on filtergraph escaping"). drawtext also gets `expansion=none`, so `%` is literal.
String escapeDrawtext(String s) => _graphLevel(s.replaceAllMapped(RegExp(r"[\\':]"), (m) => '\\${m[0]}'));

String _graphLevel(String s) => s.replaceAllMapped(RegExp(r"[\\'\[\],;]"), (m) => '\\${m[0]}');

String _num(num v) => v is int || v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2);

String _between(num a, num b) => b <= 0 ? '0' : 'between(t,${_num(a < 0 ? 0 : a)},${_num(b)})';

/// Filter labels the engine can target with commands.
const bannerTargets = ['drawbox@atv_bpanel', 'drawbox@atv_bframe', 'overlay@atv_blogo', 'drawtext@atv_bname'];
const lateTarget = 'drawtext@atv_blate';
const ratedTargets = ['drawbox@atv_rbox', 'drawtext@atv_r'];
const cardTargets = ['drawbox@atv_dcard', 'drawtext@atv_dcard1', 'drawtext@atv_dcard2'];
const stripTargets = ['drawbox@atv_dstrip', 'drawtext@atv_dstrip1', 'drawtext@atv_dstrip2'];

class _B {
  final String font;
  final int w, h;
  _B(this.font, this.w, this.h);

  String text(String label, String text, int size, String color, String x, String y, String enable,
          {String extra = ''}) =>
      'drawtext@$label=fontfile=${escapeDrawtext(font)}:expansion=none:text=${escapeDrawtext(text)}'
      ':fontsize=$size:fontcolor=$color:x=${_graphLevel(x)}:y=${_graphLevel(y)}$extra:enable=${_graphLevel(enable)}';

  String box(String label, num x, num y, num w, num h, String color, String t, String enable) =>
      'drawbox@$label=x=${_num(x)}:y=${_num(y)}:w=${_num(w)}:h=${_num(h)}:color=$color:t=$t:enable=${_graphLevel(enable)}';
}

/// Builds the overlay graph. Video mode (no [OverlayParams.message]): source = input 0, extra inputs get
/// indexes from [firstInput]. Card mode: a self-contained lavfi card + silent audio.
OverlayGraph buildFilterGraph(OverlayParams p,
    {String fontFile = defaultFontFile, int width = 640, int height = 480, int firstInput = 1}) {
  final b = _B(fontFile, width, height);
  return p.message != null ? _card(p, b) : _video(p, b, firstInput);
}

/// Inputs for the logo PNGs: one frame each, scaled once (overlay repeats the last frame).
({List<String> args, String? logo, String? wm}) _logoInputs(OverlayParams p, int first) {
  final args = <String>[];
  String? logo, wm;
  if (p.logoPath != null) {
    args.addAll(['-i', p.logoPath!]);
    logo = '${first + args.length ~/ 2 - 1}:v';
  }
  if (p.watermark && p.watermarkPath != null) {
    args.addAll(['-i', p.watermarkPath!]);
    wm = '${first + args.length ~/ 2 - 1}:v';
  }
  return (args: args, logo: logo, wm: wm);
}

/// The watermark PNG is pre-rendered at its final size for 640x480 (assets/wm_native3_50.png, 55x69):
/// overlaid 1:1 (no scaling), 50% opacity, bottom-right, 6 px margin.
const _wmMargin = 6, _wmAlpha = 0.5;

/// The watermark layer: the PNG, plus [label] centred under it (dark fill, white edge, like the PNG's
/// "ArchiveTV"), widened when the label is wider; the whole stack then gets the 50% opacity as one layer.
String _wmPrep(String input, String? label, _B b) {
  if (label == null || label.isEmpty) return '[$input]format=rgba,colorchannelmixer=aa=$_wmAlpha[wm]';
  final size = label.length > 10 ? 9 : 10;
  final tw = (label.length * _adv * size).ceil() + 4, th = size + 4;
  return '[$input]format=rgba,pad=w=${_graphLevel('max(iw,$tw)')}:h=ih+$th:x=(ow-iw)/2:y=0:color=black@0,'
      '${b.text('atv_wmlabel', label, size, '0x18181C', '(w-text_w)/2', 'h-$th+1', '1', extra: ':borderw=1:bordercolor=white')},'
      'colorchannelmixer=aa=$_wmAlpha[wm]';
}
const _wmOverlay = 'overlay@atv_wm=x=W-w-$_wmMargin:y=H-h-$_wmMargin';

OverlayGraph _video(OverlayParams p, _B b, int firstInput) {
  final W = b.w, H = b.h;
  final ins = _logoInputs(p, firstInput);
  final pre = <String>[];
  final chain = <String>[]; // filters on the main video, in order; overlays need labelled pads
  var cur = 'v0';
  var n = 0;
  String next() => 'v${++n}';
  void filters(List<String> f) {
    final o = next();
    chain.add('[$cur]${f.join(',')}[$o]');
    cur = o;
  }

  void overlay(String src, String filter) {
    final o = next();
    chain.add('[$cur][$src]$filter[$o]');
    cur = o;
  }

  // 1. Normalise: (cropdetect) -> crop -> fit into WxH 4:3 -> pad centred, square pixels.
  final c = p.crop;
  final ar = '${W}/$H';
  pre.add([
    '[0:v]',
    c == null ? 'crop@atv_crop=w=iw:h=ih:x=0:y=0' : 'crop@atv_crop=w=${c.w}:h=${c.h}:x=${c.x}:y=${c.y}',
    ',scale=w=${_graphLevel('if(gt(dar,$ar),$W,2*trunc($H*dar/2))')}'
        ':h=${_graphLevel('if(gt(dar,$ar),2*trunc($W/dar/2),$H)')}:flags=bilinear',
    ',pad=$W:$H:(ow-iw)/2:(oh-ih)/2:black,setsar=1[v0]',
  ].join());

  // 2. Watermark, bottom-right.
  if (ins.wm != null) {
    pre.add(_wmPrep(ins.wm!, p.watermarkLabel, b));
    overlay('wm', _wmOverlay);
  }

  // Logo copies: banner (96x72, compact 64x48) and bug (48x36, faint).
  final lw = p.compactBanner ? 64 : 96, lh = p.compactBanner ? 48 : 72;
  const bw = 48, bh = 36;
  if (ins.logo != null) {
    final bug = p.bugLogo && p.cornerBug;
    pre.add('[${ins.logo}]${bug ? 'split=2[lg1][lg2];[lg1]' : ''}'
        'scale=$lw:$lh:force_original_aspect_ratio=decrease[blogo]'
        '${bug ? ';[lg2]scale=$bw:$bh:force_original_aspect_ratio=decrease,format=rgba,colorchannelmixer=aa=0.5[buglogo]' : ''}');
  }

  // 3. Persistent bug, top-left (under the tune banner while it shows): tiny logo + number, R badge below.
  final hasBugLogo = ins.logo != null && p.bugLogo && p.cornerBug;
  const m = 16;
  if (hasBugLogo) overlay('buglogo', 'overlay@atv_buglogo=x=$m+($bw-w)/2:y=$m+($bh-h)/2');
  final numX = hasBugLogo ? m + bw + 6 : m;
  filters([
    b.text('atv_bugnum', '${p.number}', 22, 'white@0.65', '$numX', '$m+${(bh - 22) ~/ 2}', p.cornerBug ? '1' : '0',
        extra: ':borderw=1:bordercolor=black@0.45:shadowcolor=black@0.6:shadowx=1:shadowy=1'),
    b.box('atv_rbox', m, m + bh + 6, 28, 28, _amber, '2', p.rated && p.ratedBadge ? '1' : '0'),
    b.text('atv_r', 'R', 20, _amber, '$m+(28-text_w)/2', '${m + bh + 6}+(28-text_h)/2', p.rated && p.ratedBadge ? '1' : '0'),
  ]);

  // 4. Viewer-discretion notice (6 s at tune): full card or a strip at the bottom.
  final showFor = bannerSeconds - p.secondsSinceTune;
  final card = p.rated && p.secondsIntoProgramme < 15 && p.discretionCard,
      strip = p.rated && p.secondsIntoProgramme >= 15 && p.discretionStrip;
  // The card marks an R programme starting in this process (each item is its own process), tune or not;
  // the strip only greets a viewer who tuned in mid-programme.
  final cardOn = card ? _between(0, bannerSeconds) : '0', stripOn = strip ? _between(0, showFor) : '0';
  const all = discretionLine.length + 3 + matureLine.length; // one line, two colours (mono font)
  filters([
    b.box('atv_dcard', 0, 0, W, H, 'black', 'fill', cardOn),
    b.text('atv_dcard1', discretionLine, 30, 'white', '(w-text_w)/2', 'h/2-44', cardOn),
    b.text('atv_dcard2', matureLine, 24, _amber, '(w-text_w)/2', 'h/2+14', cardOn),
    b.text('atv_dcard3', lateNightLine, 18, _amber, '(w-text_w)/2', 'h/2-96', p.lateNight && p.lateNightInCard ? cardOn : '0'),
    b.box('atv_dstrip', 0, H - 44, W, 44, 'black@0.87', 'fill', stripOn),
    b.text('atv_dstrip1', discretionLine, 17, 'white', '(w-text_w*$all/${discretionLine.length})/2', 'h-31', stripOn),
    b.text(
        'atv_dstrip2',
        matureLine,
        17,
        _amber,
        '(w-text_w*$all/${matureLine.length})/2+text_w*${discretionLine.length + 3}/${matureLine.length}',
        'h-31',
        stripOn),
  ]);

  // 5. Tune banner, top-left, first 6 s: logo + "12  NAME" (+ LATE NIGHT ADULT MODE).
  final on = p.tuneBanner ? _between(0, p.bannerSeconds - p.secondsSinceTune) : '0';
  final title = '${p.number}  ${p.name.toUpperCase()}';
  final hasLogo = ins.logo != null;
  const x0 = 16, y0 = 16, lateSize = 13;
  final pad = p.compactBanner ? 6 : 8, nameSize = p.compactBanner ? 20 : 26;
  final textX = x0 + pad + (hasLogo ? lw + 12 : 4);
  final textW = [title.length * _adv * nameSize, if (p.lateNight && p.lateNightInBanner) lateNightLine.length * _adv * lateSize]
      .reduce((a, c) => a > c ? a : c);
  final panelW = (textX - x0) + textW.ceil() + (p.compactBanner ? 10 : 14), panelH = lh + 2 * pad;
  filters([
    b.box('atv_bpanel', x0, y0, panelW, panelH, _navy, 'fill', on), // opaque: hides the bug underneath
    b.box('atv_bframe', x0, y0, panelW, panelH, '$_yellow@0.9', '2', on),
  ]);
  if (hasLogo)
    overlay('blogo', 'overlay@atv_blogo=x=${x0 + pad}+($lw-w)/2:y=${y0 + pad}+($lh-h)/2:enable=${_graphLevel(on)}');
  final late = p.lateNight && p.lateNightInBanner;
  final nameY = p.compactBanner ? (late ? 6 : 14) : (late ? 14 : 22);
  filters([
    b.text('atv_bname', title, nameSize, _yellow, '$textX', '${y0 + pad + nameY}', on),
    b.text('atv_blate', lateNightLine, lateSize, _amber, '$textX', '${y0 + pad + (p.compactBanner ? 31 : 50)}',
        late ? on : '0'),
  ]);
  chain[chain.length - 1] = chain.last.replaceFirst(RegExp(r'\[v\d+\]$'), '[vout]');

  return OverlayGraph(ins.args, [...pre, ...chain].join(';'), audioMap: '0:a?');
}

OverlayGraph _card(OverlayParams p, _B b) {
  final W = b.w, H = b.h;
  final ins = _logoInputs(p, 2);
  final args = [
    '-f',
    'lavfi',
    '-i',
    'color=c=$_cardBg:s=${W}x$H:r=30',
    '-f',
    'lavfi',
    '-i',
    'anullsrc=r=44100:cl=stereo',
    ...ins.args
  ];
  final g = <String>[];
  var cur = '0:v';

  // Vertical layout, centred: logo, "12  NAME", late-night line, message lines.
  const logoH = 180, nameSize = 28, lateSize = 14, msgSize = 20, msgLine = 28;
  final msg = p.message!;
  final lines = msg == standBy ? [standBy] : msg.split('\n');
  final total =
      (ins.logo != null ? logoH + 14 : 0) + nameSize + (p.lateNight ? 12 + lateSize : 0) + 22 + lines.length * msgLine;
  var y = (H - total) ~/ 2;

  if (ins.logo != null) {
    g.add('[${ins.logo}]scale=-1:$logoH[clogo]');
    g.add('[$cur][clogo]overlay=x=(W-w)/2:y=$y[c1]');
    cur = 'c1';
    y += logoH + 14;
  }
  if (ins.wm != null) {
    g.add(_wmPrep(ins.wm!, p.watermarkLabel, b));
    g.add('[$cur][wm]$_wmOverlay[c2]');
    cur = 'c2';
  }
  final t = <String>[
    b.text('atv_cname', '${p.number}  ${p.name.toUpperCase()}', nameSize, 'white', '(w-text_w)/2', '$y', '1'),
  ];
  y += nameSize;
  if (p.lateNight) {
    y += 12;
    t.add(b.text('atv_clate', lateNightLine, lateSize, _amber, '(w-text_w)/2', '$y', '1'));
    y += lateSize;
  }
  y += 22;
  if (msg == standBy) {
    // "STAND BY" + . .. ... every 450 ms; x from the 11-char width so the text never shifts (mono).
    for (var d = 1; d <= 3; d++) {
      final s = '$standBy${'.' * d}';
      t.add(b.text('atv_cmsg$d', s, msgSize, _blue, '(w-text_w*11/${s.length})/2', '$y',
          'between(mod(t,1.35),${_num((d - 1) * 0.45)},${_num(d * 0.45 - 0.001)})'));
    }
  } else {
    for (var i = 0; i < lines.length; i++) {
      t.add(b.text('atv_cmsg${i + 1}', lines[i], msgSize, _blue, '(w-text_w)/2', '${y + i * msgLine}', '1'));
    }
  }
  g.add('[$cur]${t.join(',')}[vout]');
  return OverlayGraph(args, g.join(';'), audioMap: '1:a');
}

/// A line for ffmpeg's stdin ('c' = send a filter command), e.g. `cdrawtext@atv_bname -1 enable 1`.
/// The engine must start ffmpeg WITHOUT -nostdin and with stdin as a pipe to use these.
String filterCommand(String target, String command, String arg) => 'c$target -1 $command $arg\n';

/// Shows the tune banner again from second [at] of the running process (t = output seconds; with -re
/// that is wall-clock seconds since the process started).
List<String> tuneBannerCommands(num at, {bool lateNight = false, num seconds = bannerSeconds}) => [
      for (final f in bannerTargets) filterCommand(f, 'enable', _between(at, at + seconds)),
      filterCommand(lateTarget, 'enable', lateNight ? _between(at, at + seconds) : '0'),
    ];

/// The R badge on/off (late-night window opens/closes while the process runs).
List<String> ratedCommands(bool on) => [for (final f in ratedTargets) filterCommand(f, 'enable', on ? '1' : '0')];

/// The viewer-discretion notice from second [at] (a new R programme starts): [card] or the strip.
List<String> discretionCommands(num at, {bool card = true}) => [
      for (final f in card ? cardTargets : stripTargets) filterCommand(f, 'enable', _between(at, at + bannerSeconds)),
    ];

/// A quick cropdetect probe of [url] at [offsetSeconds] (7 s decoded, no output). Feed its stderr lines
/// to a [CropDecider] sized to the source; pass the result as [OverlayParams.crop]. Run it ahead of time
/// (e.g. for the next item while the current one plays) so tuning isn't slowed down.
List<String> cropProbeArgs(String url, num offsetSeconds) => [
      '-hide_banner', '-nostdin', '-ss', '$offsetSeconds', '-i', url, '-t', '7', '-an', '-sn', //
      '-vf', 'cropdetect=$cropdetectOptions', '-f', 'null', '-',
    ];
