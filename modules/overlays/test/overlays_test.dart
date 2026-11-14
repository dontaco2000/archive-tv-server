import 'package:archive_tv_overlays/archive_tv_overlays.dart';
import 'package:test/test.dart';

void main() {
  group('escapeDrawtext', () {
    test('plain text unchanged', () => expect(escapeDrawtext('12  WARP'), '12  WARP'));
    test('colon', () => expect(escapeDrawtext('a:b'), r'a\\:b'));
    test('quote', () => expect(escapeDrawtext("it's"), r"it\\\'s"));
    test('backslash', () => expect(escapeDrawtext(r'a\b'), r'a\\\\b'));
    test('graph separators', () => expect(escapeDrawtext('a,b;[c]'), r'a\,b\;\[c\]'));
    test('percent is left alone (expansion=none)', () => expect(escapeDrawtext('100%'), '100%'));
    test('ffmpeg docs example', () {
      expect(escapeDrawtext("this is a 'string': may contain one, or more, special characters"),
          r"this is a \\\'string\\\'\\: may contain one\, or more\, special characters");
    });
    test('windows font path', () => expect(escapeDrawtext('C:/Windows/Fonts/x.ttf'), r'C\\:/Windows/Fonts/x.ttf'));
  });

  group('video graph', () {
    const base = OverlayParams(number: 12, name: 'Warp', logoPath: '/l/warp.png', watermarkPath: '/w.png');

    test('deterministic', () => expect(buildFilterGraph(base).filterComplex, buildFilterGraph(base).filterComplex));

    test('inputs: logo then watermark, from firstInput', () {
      expect(buildFilterGraph(base).inputArgs, ['-i', '/l/warp.png', '-i', '/w.png']);
      final g = buildFilterGraph(base, firstInput: 2);
      expect(g.filterComplex, contains('[2:v]split=2'));
      expect(g.filterComplex, contains('[3:v]format=rgba,colorchannelmixer=aa=0.5[wm]'));
    });

    test('ends at [vout], audio from source', () {
      final g = buildFilterGraph(base);
      expect(g.filterComplex, endsWith('[vout]'));
      expect(g.filterComplex, startsWith('[0:v]'));
      expect(g.audioMap, '0:a?');
      expect(g.args.sublist(g.args.length - 4), ['-map', '[vout]', '-map', '0:a?']);
    });

    test('banner first 6 s of a fresh tune, with logo and upper-case name', () {
      final f = buildFilterGraph(base).filterComplex;
      expect(f, contains(r'text=12  WARP'));
      expect(f, contains(r'drawbox@atv_bpanel=x=16:y=16:w=256:h=88:color=0x101A5C:t=fill:enable=between(t\,0\,6)'));
      expect(f, contains(r'overlay@atv_blogo=x=24+(96-w)/2:y=24+(72-h)/2:enable=between(t\,0\,6)'));
    });

    test('banner shortened when joined 4 s after tune, off after 6 s', () {
      expect(buildFilterGraph(const OverlayParams(number: 1, name: 'A', secondsSinceTune: 4)).filterComplex,
          contains(r'enable=between(t\,0\,2)'));
      final late = buildFilterGraph(const OverlayParams(number: 1, name: 'A', secondsSinceTune: 600)).filterComplex;
      expect(late, isNot(contains('between')));
      expect(late, contains('drawtext@atv_bname')); // still present for re-triggering
    });

    test('no logo: no extra inputs, no overlay filters, text moves left', () {
      final g = buildFilterGraph(const OverlayParams(number: 5, name: 'Storytime', watermark: false));
      expect(g.inputArgs, isEmpty);
      expect(g.filterComplex, isNot(contains('overlay')));
      expect(g.filterComplex,
          contains('drawtext@atv_bname=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf'));
      expect(g.filterComplex, contains(':x=28:y=46'));
    });

    test('watermark off by flag or no path', () {
      expect(
          buildFilterGraph(const OverlayParams(number: 1, name: 'A', watermarkPath: '/w.png', watermark: false))
              .inputArgs,
          isEmpty);
      expect(buildFilterGraph(const OverlayParams(number: 1, name: 'A')).inputArgs, isEmpty);
    });

    test('bugLogo off: no split, number at the right edge', () {
      final f = buildFilterGraph(const OverlayParams(number: 12, name: 'Warp', logoPath: '/l.png', bugLogo: false))
          .filterComplex;
      expect(f, isNot(contains('split')));
      expect(f, contains(':x=16:y=16+7'));
    });

    test('R badge, late-night line and discretion card', () {
      final plain = buildFilterGraph(base).filterComplex;
      expect(plain, contains('drawbox@atv_rbox=x=16:y=58:w=28:h=28:color=0xFFB300:t=2:enable=0'));
      expect(
          plain,
          contains(
              r'drawtext@atv_blate=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf:expansion=none:text=LATE NIGHT ADULT MODE:fontsize=13:fontcolor=0xFFB300:x=132:y=74:enable=0'));
      final late = buildFilterGraph(const OverlayParams(number: 12, name: 'Warp', lateNight: true)).filterComplex;
      expect(late, contains('drawbox@atv_rbox=x=16:y=58:w=28:h=28:color=0xFFB300:t=2:enable=0'));
      expect(late,
          contains(r'text=LATE NIGHT ADULT MODE:fontsize=13:fontcolor=0xFFB300:x=28:y=74:enable=between(t\,0\,6)'));
      expect(late, contains('drawbox@atv_dcard=x=0:y=0:w=640:h=480:color=black:t=fill:enable=0'));
      final rated = buildFilterGraph(const OverlayParams(number: 12, name: 'Warp', lateNight: true, mature: true, secondsSinceTune: 600)).filterComplex;
      expect(rated, contains('drawbox@atv_rbox=x=16:y=58:w=28:h=28:color=0xFFB300:t=2:enable=1'));
      expect(rated, contains(r'drawbox@atv_dcard=x=0:y=0:w=640:h=480:color=black:t=fill:enable=between(t\,0\,6)'));
      expect(late, contains('drawbox@atv_dstrip=x=0:y=436:w=640:h=44:color=black@0.87:t=fill:enable=0'));
    });

    test('mature joined mid-programme: strip, not card; no late-night line', () {
      final f = buildFilterGraph(const OverlayParams(number: 9, name: 'Haunt', mature: true, secondsIntoProgramme: 300))
          .filterComplex;
      expect(f, contains('drawbox@atv_dcard=x=0:y=0:w=640:h=480:color=black:t=fill:enable=0'));
      expect(f, contains(r'drawbox@atv_dstrip=x=0:y=436:w=640:h=44:color=black@0.87:t=fill:enable=between(t\,0\,6)'));
      expect(f, contains('text=LATE NIGHT ADULT MODE:fontsize=13:fontcolor=0xFFB300:x=28:y=74:enable=0'));
      expect(f, contains('drawbox@atv_rbox=x=16:y=58:w=28:h=28:color=0xFFB300:t=2:enable=1'));
    });

    test('crop rect, cropdetect, and no-crop passthrough', () {
      expect(buildFilterGraph(const OverlayParams(number: 1, name: 'A')).filterComplex,
          startsWith('[0:v]crop@atv_crop=w=iw:h=ih:x=0:y=0,scale='));
      final f =
          buildFilterGraph(const OverlayParams(number: 1, name: 'A', crop: CropRect(106, 0, 640, 480))).filterComplex;
      expect(f, startsWith('[0:v]crop@atv_crop=w=640:h=480:x=106:y=0,'));
      expect(f, contains(r'pad=640:480:(ow-iw)/2:(oh-ih)/2:black,setsar=1[v0]'));
    });

    test('custom font is escaped', () {
      final f = buildFilterGraph(const OverlayParams(number: 1, name: 'A'), fontFile: "C:/F's.ttf").filterComplex;
      expect(f, contains(r"fontfile=C\\:/F\\\'s.ttf:"));
    });

    test('name with special characters stays one option', () {
      final f = buildFilterGraph(const OverlayParams(number: 1, name: "Rock'n:Roll, 100%")).filterComplex;
      expect(f, contains(r"text=1  ROCK\\\'N\\:ROLL\, 100%:"));
    });
  });

  group('card graph', () {
    test('STAND BY: lavfi inputs, logo, animated dots, silent audio', () {
      final g = buildFilterGraph(
          const OverlayParams(number: 12, name: 'Warp', logoPath: '/l.png', watermarkPath: '/w.png', message: standBy));
      expect(g.inputArgs, [
        '-f', 'lavfi', '-i', 'color=c=0x0A0A3A:s=640x480:r=30', //
        '-f', 'lavfi', '-i', 'anullsrc=r=44100:cl=stereo', '-i', '/l.png', '-i', '/w.png',
      ]);
      expect(g.audioMap, '1:a');
      expect(g.filterComplex, contains('[2:v]scale=-1:180[clogo]'));
      expect(g.filterComplex, contains('[3:v]format=rgba,colorchannelmixer=aa=0.5[wm]'));
      for (final d in ['.', '..', '...']) {
        expect(g.filterComplex, contains('text=STAND BY$d:'));
      }
      expect(g.filterComplex, contains(r'enable=between(mod(t\,1.35)\,0\,0.45)'));
      expect(g.filterComplex, contains(r'enable=between(mod(t\,1.35)\,0.90\,1.35)'));
      expect(g.filterComplex, endsWith('[vout]'));
    });

    test('build-mode notice: two centred lines, comma escaped', () {
      final f =
          buildFilterGraph(const OverlayParams(number: 3, name: 'Sakura', message: buildModeNotice)).filterComplex;
      expect(f, contains(r'text=This channel is in its build mode\,:'));
      expect(f, contains('text=please choose another channel for now.:'));
      expect(f, isNot(contains('STAND BY')));
    });

    test('late night line on the card', () {
      expect(
          buildFilterGraph(const OverlayParams(number: 3, name: 'X', message: offAir, lateNight: true)).filterComplex,
          contains('text=LATE NIGHT ADULT MODE'));
      expect(buildFilterGraph(const OverlayParams(number: 3, name: 'X', message: offAir)).filterComplex,
          isNot(contains('LATE NIGHT')));
    });
  });

  group('commands', () {
    test('tune banner re-trigger', () {
      expect(tuneBannerCommands(100), [
        'cdrawbox@atv_bpanel -1 enable between(t,100,106)\n',
        'cdrawbox@atv_bframe -1 enable between(t,100,106)\n',
        'coverlay@atv_blogo -1 enable between(t,100,106)\n',
        'cdrawtext@atv_bname -1 enable between(t,100,106)\n',
        'cdrawtext@atv_blate -1 enable 0\n',
      ]);
      expect(tuneBannerCommands(12.5, lateNight: true).last, 'cdrawtext@atv_blate -1 enable between(t,12.50,18.50)\n');
    });
    test('rated',
        () => expect(ratedCommands(true), ['cdrawbox@atv_rbox -1 enable 1\n', 'cdrawtext@atv_r -1 enable 1\n']));
    test('discretion', () {
      expect(discretionCommands(60, card: false).first, 'cdrawbox@atv_dstrip -1 enable between(t,60,66)\n');
      expect(discretionCommands(60), hasLength(3));
    });
    test('crop probe', () {
      expect(cropProbeArgs('http://x/a.mp4', 90), [
        '-hide_banner', '-nostdin', '-ss', '90', '-i', 'http://x/a.mp4', '-t', '7', '-an', '-sn', //
        '-vf', 'cropdetect=limit=24:round=2:reset=0', '-f', 'null', '-',
      ]);
    });
  });
}
