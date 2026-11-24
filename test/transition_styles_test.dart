// 겹치기 전환(디졸브 등) 계획·인자·저장 호환 검증. ffmpeg 을 돌리지 않는다.
//
//   flutter test test/transition_styles_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videojoin/engine/encoder_support.dart';
import 'package:videojoin/engine/executor.dart';
import 'package:videojoin/engine/ffmpeg_tools.dart';
import 'package:videojoin/engine/job_log.dart';
import 'package:videojoin/engine/fs_util.dart';
import 'package:videojoin/engine/job_queue.dart';
import 'package:videojoin/engine/models.dart';
import 'package:videojoin/engine/planner.dart';
import 'package:videojoin/engine/queue_store.dart';
import 'package:videojoin/engine/rational.dart';
import 'package:videojoin/engine/transitions.dart';
import 'package:videojoin/state/app_state.dart';
import 'package:videojoin/ui/theme.dart';
import 'package:videojoin/ui/widgets/settings_panel.dart';

VideoSpec _spec(String id, double duration, {bool audio = true}) => VideoSpec(
      path: 'C:\\v\\$id.mp4',
      fileSize: 1000000,
      fileModified: DateTime(2024, 1, 1),
      fileCreated: DateTime(2024, 1, 1),
      rawWidth: 1920,
      rawHeight: 1080,
      durationSec: duration,
      videoCodec: 'h264',
      pixFmt: 'yuv420p',
      hasAudio: audio,
      audioCodec: 'aac',
      audioSampleRate: 48000,
      audioChannels: 2,
    );

ClipItem _clip(String id,
        {double duration = 10,
        bool audio = true,
        int rot = 0,
        ClipEdit edit = ClipEdit.none}) =>
    ClipItem(
        id: id,
        spec: _spec(id, duration, audio: audio),
        userRotation: rot,
        edit: edit);

OutputSettings _s({
  TransitionStyle style = TransitionStyle.dissolve,
  TransitionLength length = TransitionLength.normal,
  bool smooth = true,
  bool ends = false,
  bool lossless = false,
  Rational fps = const Rational(30, 1),
}) =>
    OutputSettings(
      lossless: lossless,
      width: 1920,
      height: 1080,
      frameRate: fps,
      videoBitrate: 8000000,
      smoothTransitions: smooth,
      transitionStyle: style,
      transitionLength: length,
      fadeEnds: ends,
      outputDir: r'C:\out',
      outputName: 'x',
    );

String _arg(List<String> a, String flag, [int nth = 0]) {
  var seen = 0;
  for (var i = 0; i < a.length - 1; i++) {
    if (a[i] == flag && seen++ == nth) return a[i + 1];
  }
  throw StateError('$flag #$nth 없음: $a');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('스타일 표', () {
    test('8가지, 겹치기는 xfade 이름을 가진다', () {
      expect(TransitionStyle.values.length, 8);
      final x = {
        for (final v in TransitionStyle.values.where((v) => v.isOverlap))
          v: v.xfade
      };
      expect(x, {
        TransitionStyle.dissolve: 'fade',
        TransitionStyle.push: 'slideleft',
        TransitionStyle.wipe: 'smoothleft',
        TransitionStyle.zoom: 'zoomin',
        TransitionStyle.blur: 'hblur',
        TransitionStyle.grays: 'fadegrays',
      });
      expect(TransitionStyle.dipBlack.isOverlap, isFalse);
      expect(TransitionStyle.dipWhite.ffmpegName, 'white');
      expect(TransitionStyle.dissolve.endsDip, TransitionStyle.dipBlack);
      expect(TransitionStyle.dipWhite.endsDip, TransitionStyle.dipWhite);
    });
  });

  group('겹침 길이 d', () {
    test('길이 값의 2배, 보통 = 1.0초', () {
      expect(overlapSeconds(_s()), closeTo(1.0, 1e-9));
      expect(overlapSeconds(_s(length: TransitionLength.short)), closeTo(0.6, 1e-9));
      expect(overlapSeconds(_s(length: TransitionLength.long)), closeTo(2.0, 1e-9));
    });
    test('출력 프레임에 맞춰 반올림 (29.97 → 30프레임)', () {
      final d = overlapSeconds(_s(fps: const Rational(30000, 1001)));
      expect(d, closeTo(30 * 1001 / 30000, 1e-9));
      final d24 = overlapSeconds(
          _s(length: TransitionLength.short, fps: const Rational(24, 1)));
      expect(d24 * 24, closeTo((d24 * 24).round(), 1e-9));
    });
    test('거치기·꺼짐·무손실이면 0', () {
      expect(overlapSeconds(_s(style: TransitionStyle.dipBlack)), 0);
      expect(overlapSeconds(_s(smooth: false)), 0);
      expect(overlapSeconds(_s(lossless: true)), 0);
    });
  });

  group('조각 목록', () {
    test('두 영상: 몸통 / 전환 / 몸통', () {
      final s = _s();
      final u = Executor.buildUnits([_clip('a'), _clip('b')], s);
      expect(u.length, 3);
      expect(u.map((e) => e.join != null), [false, true, false]);
      // A 몸통: 0 ~ 9, 전환: A 9~10 + B 0~1, B 몸통: 1 ~ 10
      expect(u[0].range.start, 0);
      expect(u[0].range.end, closeTo(9, 1e-9));
      expect(u[0].trimmed, isTrue);
      final j = u[1].join!;
      expect(j.rangeA.start, closeTo(9, 1e-9));
      expect(j.rangeA.end, closeTo(10, 1e-9));
      expect(j.rangeB.start, 0);
      expect(j.rangeB.end, closeTo(1, 1e-9));
      expect(u[1].duration, closeTo(1, 1e-9));
      expect(u[2].range.start, closeTo(1, 1e-9));
      expect(u[2].range.end, closeTo(10, 1e-9));
      final total = u.fold<double>(0, (a, e) => a + e.duration);
      expect(total, closeTo(19, 1e-9));
      expect(outputDurationFor([_clip('a'), _clip('b')], s), closeTo(19, 1e-9));
    });

    test('가운데 영상은 앞뒤 모두 깎인다', () {
      final u = Executor.buildUnits(
          [_clip('a'), _clip('b'), _clip('c')], _s());
      expect(u.length, 5);
      expect(u[2].range.start, closeTo(1, 1e-9));
      expect(u[2].range.end, closeTo(9, 1e-9));
      expect(u[2].clipIndex, 1);
    });

    test('가운데를 자른 같은 영상 사이에도 전환이 들어간다', () {
      final c = _clip('a',
          edit: const ClipEdit(keep: [TimeRange(0, 4), TimeRange(5, 9)]));
      final u = Executor.buildUnits([c], _s());
      expect(u.length, 3);
      final j = u[1].join!;
      expect(j.clipB, same(c));
      expect(j.rangeA.start, closeTo(3, 1e-9));
      expect(j.rangeB.start, 5);
      expect(outputDurationFor([c], _s()), closeTo(7, 1e-9));
    });

    test('짧은 구간은 전환 없이 그냥 자른다', () {
      // 1.4초 구간: d=1.0 을 내주면 0.4 < 0.5
      final a = _clip('a', duration: 1.4);
      final u = Executor.buildUnits([a, _clip('b')], _s());
      expect(u.length, 2);
      expect(u.every((e) => e.join == null), isTrue);
      expect(outputDurationFor([a, _clip('b')], _s()), closeTo(11.4, 1e-9));
      // 뒤 구간이 짧아도 마찬가지
      final u2 = Executor.buildUnits([_clip('b'), a], _s());
      expect(u2.every((e) => e.join == null), isTrue);
    });

    test('중간 영상이 짧으면 한쪽 이음매만 전환', () {
      // b 는 2.4초: 앞 이음매 d 를 내주면 1.4, 뒤 이음매까지 내주면 0.4 → 뒤는 컷
      final clips = [_clip('a'), _clip('b', duration: 2.4), _clip('c')];
      final u = Executor.buildUnits(clips, _s());
      expect(u.where((e) => e.join != null).length, 1);
      expect(u.map((e) => e.join != null), [false, true, false, false]);
      expect(u[2].range.start, closeTo(1, 1e-9));
      expect(u[2].range.end, closeTo(2.4, 1e-9));
      expect(u[2].duration, closeTo(1.4, 1e-9));
      expect(outputDurationFor(clips, _s()), closeTo(22.4 - 1, 1e-9));
    });

    test('몸통은 항상 0.5초 이상', () {
      for (final dur in [1.4, 1.5, 2.0, 2.4, 2.5, 3.0]) {
        final clips = [_clip('a', duration: dur), _clip('b', duration: dur), _clip('c', duration: dur)];
        final u = Executor.buildUnits(clips, _s());
        for (final e in u.where((e) => e.join == null)) {
          expect(e.duration, greaterThanOrEqualTo(0.5 - 1e-9), reason: 'dur=$dur');
        }
      }
    });

    test('거치기 방식은 예전과 같은 모양(조각 수 그대로, 길이 그대로)', () {
      final s = _s(style: TransitionStyle.dipBlack);
      final clips = [_clip('a'), _clip('b')];
      final u = Executor.buildUnits(clips, s);
      expect(u.length, 2);
      expect(u.every((e) => e.join == null), isTrue);
      expect(u[0].fadeOut, isTrue);
      expect(u[1].fadeIn, isTrue);
      expect(outputDurationFor(clips, s), closeTo(20, 1e-9));
    });

    test('겹치기 + 처음·끝 서서히: 첫 몸통 fadeIn, 마지막 몸통 fadeOut', () {
      final u = Executor.buildUnits(
          [_clip('a'), _clip('b')], _s(ends: true));
      expect(u.first.fadeIn, isTrue);
      expect(u.first.fadeOut, isFalse);
      expect(u.last.fadeOut, isTrue);
      expect(u.last.fadeIn, isFalse);
      expect(u[1].fadeIn || u[1].fadeOut, isFalse);
    });

    test('처음·끝 서서히는 효과 종류와 상관없이 원래 길이로 정한다', () {
      // 4초 영상 + 길게(1초): 겹치기 몸통은 2초로 깎이지만 거치기처럼 서서히가 된다.
      final clips = [_clip('a', duration: 4), _clip('b', duration: 4)];
      for (final style in [TransitionStyle.dissolve, TransitionStyle.dipBlack]) {
        final u = Executor.buildUnits(
            clips, _s(style: style, length: TransitionLength.long, ends: true));
        expect(u.first.fadeIn, isTrue, reason: style.name);
        expect(u.last.fadeOut, isTrue, reason: style.name);
      }
      // 너무 짧은 영상(2.5초 < 3초)은 어느 쪽이든 서서히 없음
      final short = [_clip('a', duration: 2.5), _clip('b', duration: 2.5)];
      for (final style in [TransitionStyle.dissolve, TransitionStyle.dipBlack]) {
        final u = Executor.buildUnits(
            short, _s(style: style, length: TransitionLength.long, ends: true));
        expect(u.first.fadeIn, isFalse, reason: style.name);
      }
    });

    test('겹치기 스타일이어도 전환을 끄고 처음·끝만 켜면 거치기 경로', () {
      final u = Executor.buildUnits(
          [_clip('a'), _clip('b')], _s(smooth: false, ends: true));
      expect(u.length, 2);
      expect(u.first.fadeIn, isTrue);
      expect(u.last.fadeOut, isTrue);
      expect(u.first.fadeOut, isFalse);
    });

    test('이어하기: 같은 입력이면 같은 조각 목록', () {
      final clips = [_clip('a'), _clip('b', duration: 2.4), _clip('c')];
      String sig() => Executor.buildUnits(clips, _s())
          .map((e) =>
              '${e.clipIndex}|${e.range.start}|${e.range.end}|${e.join?.rangeB.start}')
          .join(';');
      expect(sig(), sig());
    });
  });

  group('ffmpeg 인자', () {
    final exec = Executor(
        tools: const FFTools(ffmpegPath: 'ffmpeg', ffprobePath: 'ffprobe'),
        encoders: const EncoderSupport(),
        log: JobLog(File(p.join(Directory.systemTemp.path, 'vj_unused.log'))));
    List<String> ex(SegmentUnit u, OutputSettings s, String out) =>
        exec.normalizeArgs(u, s, out, encoder: 'libx264');

    test('전환 조각: 입력 두 개, xfade 이름·offset·duration', () {
      final s = _s(style: TransitionStyle.push);
      final u = Executor.buildUnits([_clip('a'), _clip('b')], s);
      final a = ex(u[1], s, 'o.ts');
      expect(_arg(a, '-ss', 0), '9.000');
      expect(_arg(a, '-ss', 1), '0.000');
      expect(_arg(a, '-t', 0), '1.000');
      expect(a.where((x) => x == '-i').length, 2);
      final f = _arg(a, '-filter_complex');
      expect(f, contains('xfade=transition=slideleft:duration=1.000:offset=0'));
      expect(f, contains('[0:v:0]'));
      expect(f, contains('[1:v:0]'));
      expect('scale=1920:1080'.allMatches(f).length, 2);
      expect(f, contains('afade=t=out:st=0:d=1.000'));
      expect(f, contains('afade=t=in:st=0:d=1.000'));
      expect(f, contains('amix=inputs=2:normalize=0:duration=longest'));
      expect(f, contains('apad,atrim=0:1.000'));
      expect(_arg(a, '-f', 0), 'mpegts');
      expect(a.contains('-r'), isTrue);
      expect(a.last, 'o.ts');
    });

    test('소리 없는 영상은 무음 입력(번호 2부터)을 붙인다', () {
      final s = _s();
      final clips = [_clip('a', audio: false), _clip('b', audio: false)];
      final u = Executor.buildUnits(clips, s);
      final a = ex(u[1], s, 'o.ts');
      expect(a.where((x) => x == 'lavfi').length, 2);
      final f = _arg(a, '-filter_complex');
      expect(f, contains('[2:a:0]'));
      expect(f, contains('[3:a:0]'));
      expect(f, isNot(contains('[0:a:0]')));
      // 한쪽만 없으면 번호는 2 하나
      final u2 = Executor.buildUnits([_clip('a'), _clip('b', audio: false)], s);
      final f2 = _arg(ex(u2[1], s, 'o.ts'), '-filter_complex');
      expect(f2, contains('[0:a:0]'));
      expect(f2, contains('[2:a:0]'));
      expect(f2, isNot(contains('[3:a:0]')));
    });

    test('입력별 체인: 회전·밝기·소리 크기가 각자 따로 들어간다', () {
      final s = _s();
      final a = _clip('a', rot: 90);
      final b = _clip('b',
          edit: const ClipEdit(
              volume: VolumeLevel.high, brightness: BrightnessLevel.brighter));
      final u = Executor.buildUnits([a, b], s);
      final f = _arg(ex(u[1], s, 'o.ts'), '-filter_complex');
      final va = f.substring(f.indexOf('[0:v:0]'), f.indexOf('[va]'));
      final vb = f.substring(f.indexOf('[1:v:0]'), f.indexOf('[vb]'));
      expect(va, contains('transpose=1'));
      expect(va, isNot(contains('eq=gamma')));
      expect(vb, contains('eq=gamma=1.25'));
      expect(vb, isNot(contains('transpose')));
      expect(f, contains('volume='));
      expect(f, contains('alimiter'));
    });

    test('몸통 조각은 -ss/-t 가 깎인 구간으로 나간다', () {
      final s = _s();
      final u = Executor.buildUnits([_clip('a'), _clip('b')], s);
      final body = ex(u[2], s, 'o.ts');
      expect(_arg(body, '-ss'), '1.000');
      expect(_arg(body, '-t'), '9.000');
      expect(body.contains('-filter_complex'), isFalse);
    });
  });

  group('jobId', () {
    String id(OutputSettings s) =>
        Executor.jobIdFor([_clip('a'), _clip('b')], s);
    test('스타일·길이가 바뀌면 달라진다', () {
      expect(id(_s()), isNot(id(_s(style: TransitionStyle.push))));
      expect(id(_s()), isNot(id(_s(length: TransitionLength.long))));
      expect(id(_s(style: TransitionStyle.dipBlack)),
          isNot(id(_s(style: TransitionStyle.dissolve))));
    });
    test('전환이 꺼져 있거나 무손실이면 스타일은 영향 없음', () {
      expect(id(_s(smooth: false)),
          id(_s(smooth: false, style: TransitionStyle.zoom)));
      expect(id(_s(lossless: true)),
          id(_s(lossless: true, style: TransitionStyle.zoom, length: TransitionLength.long)));
    });
    test('처음·끝 서서히는 거치는 색만 따른다', () {
      expect(id(_s(smooth: false, ends: true, style: TransitionStyle.zoom)),
          id(_s(smooth: false, ends: true, style: TransitionStyle.dissolve)));
      expect(id(_s(smooth: false, ends: true, style: TransitionStyle.dipWhite)),
          isNot(id(_s(smooth: false, ends: true, style: TransitionStyle.dissolve))));
    });
  });

  group('전체 길이 helper', () {
    test('계획·예상 용량·대기열 요약이 같은 값을 쓴다', () {
      final clips = [_clip('a'), _clip('b'), _clip('c')];
      final s = _s();
      final plan = JobPlan.analyze(clips, smoothTransitions: true);
      expect(plan.totalDuration, 30);
      expect(plan.outputDuration(s), closeTo(28, 1e-9));
      final bytes = plan.estimateOutputBytes(s);
      final same = plan.estimateOutputBytes(_s(style: TransitionStyle.dipBlack));
      expect(bytes, lessThan(same));
      expect(bytes,
          ((s.videoBitrate + s.audioBitrate) * 28 / 8 * 1.02).round());
      final job = QueuedJob(id: 'q', clips: clips, settings: s, plan: plan);
      expect(job.totalDuration, closeTo(28, 1e-9));
    });
    test('무손실·꺼짐이면 예전 값 그대로', () {
      final clips = [_clip('a'), _clip('b')];
      final plan = JobPlan.analyze(clips);
      expect(plan.outputDuration(_s(smooth: false)), 20);
      expect(plan.outputDuration(_s(lossless: true)), 20);
    });
    test('소리 없는 영상·실패한 영상은 합계에서 제외', () {
      final bad = ClipItem(
          id: 'bad',
          spec: VideoSpec.failed(r'C:\v\bad.mp4', 'x'));
      final clips = [_clip('a'), bad, _clip('b', audio: false)];
      expect(outputDurationFor(clips, _s()), closeTo(19, 1e-9));
    });
  });

  group('저장 호환', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('vj_tstyle_'));
    tearDown(() => forceDeleteDir(dir));

    QueuedJob job(OutputSettings s) {
      final clips = [_clip('a'), _clip('b')];
      return QueuedJob(
          id: 'q1',
          clips: clips,
          settings: s,
          plan: JobPlan.analyze(clips, smoothTransitions: s.smoothTransitions));
    }

    Map<String, dynamic> oldJson(Object? color) => {
          'version': 1,
          'jobs': [
            {
              'clips': [
                {'path': r'C:\v\a.mp4', 'rotation': 0},
              ],
              'settings': {
                'lossless': false,
                'width': 1920,
                'height': 1080,
                'fpsNum': 30,
                'fpsDen': 1,
                'videoBitrate': 8000000,
                'smooth': true,
                'transColor': ?color,
                'outputDir': r'C:\out',
                'outputName': 'old',
              },
            },
          ],
        };

    test('QueueStore 왕복: 새 스타일', () {
      final store = QueueStore(p.join(dir.path, 'q.json'));
      for (final st in TransitionStyle.values) {
        store.save([job(_s(style: st, length: TransitionLength.long))]);
        final r = store.load().single.settings;
        expect(r.transitionStyle, st);
        expect(r.transitionLength, TransitionLength.long);
      }
    });

    test('옛 transColor white/black → dipWhite/dipBlack', () {
      TransitionStyle load(Object? color) {
        final path = p.join(dir.path, 'old_$color.json');
        File(path).writeAsBytesSync(utf8.encode(jsonEncode(oldJson(color))));
        return QueueStore(path).load().single.settings.transitionStyle;
      }

      expect(load('white'), TransitionStyle.dipWhite);
      expect(load('black'), TransitionStyle.dipBlack);
      expect(load(null), TransitionStyle.dipBlack);
      expect(load('pink'), TransitionStyle.dipBlack);
    });

    test('OutputSettings.clone 이 스타일을 복사한다', () {
      expect(_s(style: TransitionStyle.zoom).clone().transitionStyle,
          TransitionStyle.zoom);
    });
  });

  group('AppState', () {
    final root = Directory.current.path;
    final testdata = p.join(root, 'testdata');
    final outDir = p.join(root, 'out', 'transition_styles_test');

    setUpAll(() {
      final d = Directory(outDir);
      forceDeleteDir(d);
      d.createSync(recursive: true);
    });

    Future<AppState> ready() async {
      final s = AppState();
      await s.init();
      await s.setAutoNaming(false);
      await s.setUseGpu(false);
      return s;
    }

    Future<void> addTwo(AppState s) async {
      await s.addPaths([
        p.join(testdata, 'same_a.mp4'),
        p.join(testdata, 'same_b.mp4'),
      ]);
      await s.setOutputDir(outDir);
    }

    test('setter → buildSettings, prefs 로 기억, 무손실은 계속 막힌다', () async {
      SharedPreferences.setMockInitialValues({});
      final s = await ready();
      await addTwo(s);
      s.setOutputName('st');
      await s.setSmoothTransitions(true);
      await s.setTransitionStyle(TransitionStyle.wipe);
      expect(s.plan!.losslessPossible, isFalse);
      expect(s.plan!.losslessBlockedReason,
          '영상 사이를 부드럽게 넘기려면 다시 만들어야 합니다.');
      s.setLossless(false);
      final b = s.buildSettings()!;
      expect(b.transitionStyle, TransitionStyle.wipe);
      expect(overlapActive(b), isTrue);
      s.dispose();

      final s2 = await ready();
      expect(s2.transitionStyle, TransitionStyle.wipe);
      s2.dispose();
    });

    test('옛 prefs transitionColor 를 읽는다', () async {
      SharedPreferences.setMockInitialValues({'transitionColor': 'white'});
      final s = await ready();
      expect(s.transitionStyle, TransitionStyle.dipWhite);
      s.dispose();
      SharedPreferences.setMockInitialValues({'transitionColor': 'black'});
      final s2 = await ready();
      expect(s2.transitionStyle, TransitionStyle.dipBlack);
      s2.dispose();
    });

    test('새 키가 옛 키보다 우선, 손상된 값은 기본값', () async {
      SharedPreferences.setMockInitialValues(
          {'transitionColor': 'white', 'transitionStyle': 'zoom'});
      final s = await ready();
      expect(s.transitionStyle, TransitionStyle.zoom);
      s.dispose();
      SharedPreferences.setMockInitialValues({'transitionStyle': 'pink'});
      final s2 = await ready();
      expect(s2.transitionStyle, TransitionStyle.dipBlack);
      s2.dispose();
    });
  });

  group('UI', () {
    Future<AppState> pumpCard(WidgetTester tester, double scale, double width,
        {TransitionStyle? style}) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1400, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      await state.setSmoothTransitions(true);
      if (style != null) await state.setTransitionStyle(style);
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(scale),
        home: UiScale(
          factor: scale,
          child: Scaffold(
            body: SingleChildScrollView(
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  child: SmoothTransitionCard(
                      state: state, losslessPossibleWithout: true),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      return state;
    }

    testWidgets('좁은 패널(500px)·배율 2.16 에서도 넘치지 않고 8가지가 다 보인다',
        (tester) async {
      final state = await pumpCard(tester, 2.16, 500);
      expect(tester.takeException(), isNull);
      for (final st in TransitionStyle.values) {
        expect(find.text(st.label), findsOneWidget);
        expect(find.text(st.description), findsOneWidget);
      }
      state.dispose();
    });

    testWidgets('거치기는 길이 안내 없음, 겹치기는 안내 문구', (tester) async {
      const note = '영상이 겹치는 만큼 전체 길이가 조금 짧아집니다.';
      var state = await pumpCard(tester, 1.0, 900);
      expect(find.text(note), findsNothing);
      state.dispose();
      state = await pumpCard(tester, 1.0, 900, style: TransitionStyle.push);
      expect(find.text(note), findsOneWidget);
      state.dispose();
    });

    testWidgets('효과를 누르면 상태가 바뀐다', (tester) async {
      final state = await pumpCard(tester, 1.0, 900);
      await tester.tap(find.text('밀어내기'));
      await tester.pump();
      expect(state.transitionStyle, TransitionStyle.push);
      state.dispose();
    });
  });
}
