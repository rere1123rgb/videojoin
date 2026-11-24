// 넘기기 옵션(색·길이·처음과 끝 서서히) 검증.
//
//   flutter test test/transition_options_test.dart

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
import 'package:videojoin/state/app_state.dart';
import 'package:videojoin/ui/theme.dart';
import 'package:videojoin/ui/widgets/settings_panel.dart';

VideoSpec _spec(String path, double duration) => VideoSpec(
      path: path,
      fileSize: 1000000,
      fileModified: DateTime(2024, 1, 1),
      fileCreated: DateTime(2024, 1, 1),
      rawWidth: 1920,
      rawHeight: 1080,
      durationSec: duration,
      videoCodec: 'h264',
      pixFmt: 'yuv420p',
      hasAudio: true,
      audioCodec: 'aac',
      audioSampleRate: 48000,
      audioChannels: 2,
    );

ClipItem _clip(String id, {double duration = 10}) =>
    ClipItem(id: id, spec: _spec('C:\\v\\$id.mp4', duration));

OutputSettings _settings({
  bool lossless = false,
  bool smooth = false,
  TransitionStyle color = TransitionStyle.dipBlack,
  TransitionLength length = TransitionLength.normal,
  bool ends = false,
}) =>
    OutputSettings(
      lossless: lossless,
      width: 1920,
      height: 1080,
      frameRate: const Rational(30, 1),
      videoBitrate: 8000000,
      smoothTransitions: smooth,
      transitionStyle: color,
      transitionLength: length,
      fadeEnds: ends,
      outputDir: r'C:\out',
      outputName: 'x',
    );

String _vf(SegmentUnit u, OutputSettings s) => Executor.buildFilterChain(
      u.clip,
      s,
      fadeIn: u.fadeIn,
      fadeOut: u.fadeOut,
      duration: u.duration,
      fadeSec: u.fadeSec,
      fadeColor: u.fadeColor,
    );

String _af(SegmentUnit u) => Executor.buildAudioFilter(
      u.clip,
      fadeIn: u.fadeIn,
      fadeOut: u.fadeOut,
      duration: u.duration,
      fadeSec: u.fadeSec,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('유닛 플래그와 필터', () {
    test('기본값은 지금까지와 같다: 0.5초, 색 인자 없음', () {
      final s = _settings(smooth: true);
      final u = Executor.buildUnits([_clip('a'), _clip('b')], s);
      expect(u[0].fadeSec, kFadeSec);
      final vf = _vf(u[1], s);
      expect(vf, contains('fade=t=in:st=0:d=0.5'));
      expect(vf, isNot(contains('d=0.5:color')));
      expect(vf, isNot(contains('color=white')));
    });

    test('흰 화면은 색 인자가 붙고 검은 화면은 안 붙는다', () {
      final s = _settings(smooth: true, color: TransitionStyle.dipWhite);
      final u = Executor.buildUnits([_clip('a'), _clip('b'), _clip('c')], s);
      final vf = _vf(u[1], s);
      expect(vf, contains('fade=t=in:st=0:d=0.5:color=white'));
      expect(vf, contains('fade=t=out:st=9.500:d=0.5:color=white'));
      // 오디오에는 색이 없다.
      expect(_af(u[1]), isNot(contains('color')));
    });

    test('길이 0.3 / 1.0 이 d= 와 st= 에 반영된다', () {
      var s = _settings(smooth: true, length: TransitionLength.short);
      var u = Executor.buildUnits([_clip('a'), _clip('b'), _clip('c')], s);
      expect(_vf(u[1], s), contains('fade=t=in:st=0:d=0.3'));
      expect(_vf(u[1], s), contains('fade=t=out:st=9.700:d=0.3'));
      expect(_af(u[1]), contains('afade=t=in:st=0:d=0.3'));
      expect(_af(u[1]), contains('afade=t=out:st=9.700:d=0.3'));

      s = _settings(smooth: true, length: TransitionLength.long);
      u = Executor.buildUnits([_clip('a'), _clip('b'), _clip('c')], s);
      expect(_vf(u[1], s), contains('fade=t=in:st=0:d=1.0'));
      expect(_vf(u[1], s), contains('fade=t=out:st=9.000:d=1.0'));
      expect(_af(u[1]), contains('afade=t=out:st=9.000:d=1.0'));
    });

    test('짧은 조각 생략은 고른 길이의 3배 기준', () {
      // 2초: 보통(1.5 필요)은 적용, 길게(3 필요)는 생략
      final two = [_clip('a'), _clip('b', duration: 2), _clip('c')];
      var u = Executor.buildUnits(two, _settings(smooth: true));
      expect(u[1].fadeIn, isTrue);
      u = Executor.buildUnits(
          two, _settings(smooth: true, length: TransitionLength.long));
      expect(u[1].fadeIn, isFalse);
      expect(u[1].fadeOut, isFalse);
      // 1초: 짧게(0.9)는 적용
      final one = [_clip('a'), _clip('b', duration: 1), _clip('c')];
      u = Executor.buildUnits(
          one, _settings(smooth: true, length: TransitionLength.short));
      expect(u[1].fadeIn, isTrue);
    });

    test('fadeEnds 만 켜면 첫 조각 fadeIn, 마지막 조각 fadeOut 만 생긴다', () {
      final s = _settings(ends: true);
      final u = Executor.buildUnits([_clip('a'), _clip('b'), _clip('c')], s);
      expect([u[0].fadeIn, u[0].fadeOut], [true, false]);
      expect([u[1].fadeIn, u[1].fadeOut], [false, false]);
      expect([u[2].fadeIn, u[2].fadeOut], [false, true]);
      expect(_vf(u[0], s), contains('fade=t=in'));
      expect(_af(u[0]), contains('afade=t=in'));
      expect(_vf(u[2], s), contains('fade=t=out'));
      expect(_af(u[2]), contains('afade=t=out'));
    });

    test('영상 하나뿐이면 fadeEnds 로 양쪽 모두', () {
      final u = Executor.buildUnits([_clip('a')], _settings(ends: true));
      expect([u.single.fadeIn, u.single.fadeOut], [true, true]);
    });

    test('둘 다 켜면 모든 조각에 양쪽', () {
      final s = _settings(smooth: true, ends: true);
      final u = Executor.buildUnits([_clip('a'), _clip('b'), _clip('c')], s);
      for (final x in u) {
        expect([x.fadeIn, x.fadeOut], [true, true]);
      }
    });

    test('smooth 만 켜면 양 끝은 건드리지 않는다', () {
      final u = Executor.buildUnits(
          [_clip('a'), _clip('b')], _settings(smooth: true));
      expect(u.first.fadeIn, isFalse);
      expect(u.last.fadeOut, isFalse);
    });

    test('무손실이면 fadeEnds 도 무시', () {
      final u = Executor.buildUnits(
          [_clip('a'), _clip('b')], _settings(lossless: true, ends: true));
      expect(u.any((x) => x.fadeIn || x.fadeOut), isFalse);
    });

    test('fadeEnds 첫 조각이 너무 짧으면 그 조각은 건너뛴다', () {
      final u = Executor.buildUnits(
          [_clip('a', duration: 1), _clip('b')], _settings(ends: true));
      expect(u.first.fadeIn, isFalse);
    });

    test('normalizeArgs 에 색·길이가 들어간다', () {
      final ex = Executor(
        tools: const FFTools(ffmpegPath: 'ffmpeg', ffprobePath: 'ffprobe'),
        encoders: const EncoderSupport(),
        log: JobLog(File(p.join(Directory.systemTemp.path, 'unused_vj.log'))),
      );
      final s = _settings(
          smooth: true,
          ends: true,
          color: TransitionStyle.dipWhite,
          length: TransitionLength.long);
      final u = Executor.buildUnits([_clip('a'), _clip('b')], s);
      final args = ex.normalizeArgs(u[0], s, 'o.mp4', encoder: 'libx264');
      final vf = args[args.indexOf('-vf') + 1];
      expect(vf, contains('fade=t=in:st=0:d=1.0:color=white'));
      expect(vf, contains('fade=t=out:st=9.000:d=1.0:color=white'));
      final af = args[args.indexOf('-af') + 1];
      expect(af, contains('afade=t=out:st=9.000:d=1.0'));
    });
  });

  group('작업 폴더 식별자', () {
    String id(OutputSettings s) => Executor.jobIdFor([_clip('a')], s);

    test('색·길이·처음끝·전환이 바뀌면 달라진다', () {
      final base = id(_settings(smooth: true));
      expect(id(_settings(smooth: true, color: TransitionStyle.dipWhite)),
          isNot(base));
      expect(id(_settings(smooth: true, length: TransitionLength.long)),
          isNot(base));
      expect(id(_settings(smooth: true, ends: true)), isNot(base));
      expect(id(_settings(ends: true)), isNot(id(_settings())));
      expect(id(_settings(smooth: true)), isNot(id(_settings())));
      expect(id(_settings(ends: true, color: TransitionStyle.dipWhite)),
          isNot(id(_settings(ends: true))));
    });

    test('같은 설정이면 같고, 무손실이면 옵션이 영향 없다', () {
      expect(id(_settings(smooth: true)), id(_settings(smooth: true)));
      expect(
          id(_settings(lossless: true, ends: true, smooth: true,
              color: TransitionStyle.dipWhite)),
          id(_settings(lossless: true)));
    });

    test('전환을 껐으면 색·길이는 결과에 영향이 없으므로 같다', () {
      expect(id(_settings(color: TransitionStyle.dipWhite)), id(_settings()));
    });
  });

  group('플래너', () {
    test('fadeEnds 는 무손실을 막고 이유를 준다', () {
      final plan = JobPlan.analyze([_clip('a'), _clip('b')], fadeEnds: true);
      expect(plan.losslessPossible, isFalse);
      expect(plan.losslessBlockedReason, '처음과 끝을 서서히 하려면 다시 만들어야 합니다.');
    });

    test('둘 다 켜면 전환 이유가 먼저', () {
      final plan = JobPlan.analyze([_clip('a'), _clip('b')],
          smoothTransitions: true, fadeEnds: true);
      expect(plan.losslessBlockedReason,
          '영상 사이를 부드럽게 넘기려면 다시 만들어야 합니다.');
    });

    test('기본은 막지 않는다', () {
      expect(JobPlan.analyze([_clip('a'), _clip('b')]).losslessBlockedReason,
          isNot(contains('서서히')));
    });
  });

  group('OutputSettings·QueueStore', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('vj_trans_'));
    tearDown(() => forceDeleteDir(dir));

    test('clone 이 새 필드를 복사한다', () {
      final c = _settings(
              smooth: true,
              ends: true,
              color: TransitionStyle.dipWhite,
              length: TransitionLength.short)
          .clone();
      expect(c.transitionStyle, TransitionStyle.dipWhite);
      expect(c.transitionLength, TransitionLength.short);
      expect(c.fadeEnds, isTrue);
    });

    test('기본 생성자 값', () {
      final s = _settings();
      expect(s.transitionStyle, TransitionStyle.dipBlack);
      expect(s.transitionLength, TransitionLength.normal);
      expect(s.fadeEnds, isFalse);
    });

    QueuedJob job(OutputSettings s) {
      final clips = [_clip('a'), _clip('b')];
      return QueuedJob(
        id: 'q1',
        clips: clips,
        settings: s,
        plan: JobPlan.analyze(clips,
            smoothTransitions: s.smoothTransitions, fadeEnds: s.fadeEnds),
      );
    }

    test('QueueStore 왕복', () {
      final store = QueueStore(p.join(dir.path, 'q.json'));
      store.save([
        job(_settings(
            smooth: true,
            ends: true,
            color: TransitionStyle.dipWhite,
            length: TransitionLength.long)),
      ]);
      final s = store.load().single.settings;
      expect(s.smoothTransitions, isTrue);
      expect(s.transitionStyle, TransitionStyle.dipWhite);
      expect(s.transitionLength, TransitionLength.long);
      expect(s.fadeEnds, isTrue);
    });

    test('QueueStore: 새 키 없는 옛 파일은 기본값', () {
      final path = p.join(dir.path, 'old.json');
      File(path).writeAsBytesSync(utf8.encode(jsonEncode({
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
              'outputDir': r'C:\out',
              'outputName': 'old',
            },
          },
        ],
      })));
      final s = QueueStore(path).load().single.settings;
      expect(s.smoothTransitions, isTrue);
      expect(s.transitionStyle, TransitionStyle.dipBlack);
      expect(s.transitionLength, TransitionLength.normal);
      expect(s.fadeEnds, isFalse);
    });

    test('QueueStore: 알 수 없는 값은 기본값', () {
      final path = p.join(dir.path, 'bad.json');
      File(path).writeAsBytesSync(utf8.encode(jsonEncode({
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
              'transColor': 'pink',
              'transLen': 'forever',
              'outputDir': r'C:\out',
              'outputName': 'bad',
            },
          },
        ],
      })));
      final s = QueueStore(path).load().single.settings;
      expect(s.transitionStyle, TransitionStyle.dipBlack);
      expect(s.transitionLength, TransitionLength.normal);
    });
  });

  group('AppState', () {
    final root = Directory.current.path;
    final testdata = p.join(root, 'testdata');
    final outDir = p.join(root, 'out', 'transition_options_test');

    setUpAll(() {
      final d = Directory(outDir);
      forceDeleteDir(d);
      d.createSync(recursive: true);
    });
    setUp(() => SharedPreferences.setMockInitialValues({}));

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

    test('fadeEnds: 무손실을 막고 buildSettings 에 반영, 끄면 복구', () async {
      final s = await ready();
      await addTwo(s);
      s.setOutputName('ends');
      expect(s.plan!.losslessPossible, isTrue);

      await s.setFadeEnds(true);
      expect(s.plan!.losslessPossible, isFalse);
      expect(s.plan!.losslessBlockedReason, contains('처음과 끝'));
      s.setLossless(false);
      final b = s.buildSettings()!;
      expect(b.fadeEnds, isTrue);
      expect(b.smoothTransitions, isFalse);

      await s.setFadeEnds(false);
      expect(s.plan!.losslessPossible, isTrue);
      expect(s.buildSettings()!.fadeEnds, isFalse);
      s.dispose();
    });

    test('색·길이 setter 는 buildSettings 에 들어가고 prefs 에 저장된다', () async {
      final s = await ready();
      await addTwo(s);
      s.setOutputName('cl');
      await s.setSmoothTransitions(true);
      await s.setTransitionStyle(TransitionStyle.dipWhite);
      await s.setTransitionLength(TransitionLength.long);
      await s.setFadeEnds(true);
      s.setLossless(false);
      final b = s.buildSettings()!;
      expect(b.transitionStyle, TransitionStyle.dipWhite);
      expect(b.transitionLength, TransitionLength.long);
      expect(b.fadeEnds, isTrue);
      s.dispose();

      // 다시 켜도 기억한다.
      final s2 = await ready();
      expect(s2.transitionStyle, TransitionStyle.dipWhite);
      expect(s2.transitionLength, TransitionLength.long);
      expect(s2.fadeEnds, isTrue);
      s2.dispose();
    });

    test('손상된 prefs 값은 기본값', () async {
      SharedPreferences.setMockInitialValues(
          {'transitionStyle': 'pink', 'transitionLength': 'x'});
      final s = await ready();
      expect(s.transitionStyle, TransitionStyle.dipBlack);
      expect(s.transitionLength, TransitionLength.normal);
      s.dispose();
    });

    test('editQueued 가 작업의 옵션을 되살리고 무손실 판단에 반영한다', () async {
      final s = await ready();
      // 첫 작업은 곧바로 실행되므로 고칠 작업은 그 뒤에 넣는다.
      await s.addPaths([
        p.join(testdata, 'uhd_4k.mp4'),
        p.join(testdata, 'hdr_4k.mp4'),
      ]);
      await s.setOutputDir(outDir);
      s.setOutputName('q_first');
      s.setLossless(false);
      expect(s.enqueueCurrent(), isNull);

      await addTwo(s);
      s.setOutputName('q_ends');
      await s.setFadeEnds(true);
      await s.setTransitionStyle(TransitionStyle.dipWhite);
      await s.setTransitionLength(TransitionLength.short);
      s.setLossless(false);
      expect(s.enqueueCurrent(), isNull);
      final job = s.queue[1];
      expect(job.settings.fadeEnds, isTrue);
      expect(job.settings.transitionStyle, TransitionStyle.dipWhite);

      // 화면 값은 다르게 해 둔 뒤 되돌린다.
      await s.setFadeEnds(false);
      await s.setTransitionStyle(TransitionStyle.dipBlack);
      await s.setTransitionLength(TransitionLength.long);
      expect(s.editQueued(job.id), isNull);
      expect(s.fadeEnds, isTrue);
      expect(s.transitionStyle, TransitionStyle.dipWhite);
      expect(s.transitionLength, TransitionLength.short);
      expect(s.plan!.losslessPossible, isFalse,
          reason: '계획을 세우기 전에 fadeEnds 가 되살아나야 한다');
      expect(s.useLossless, isFalse);

      await s.cancelRunning();
      s.dispose();
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('위젯 레이아웃', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    for (final (width, scale) in const [(500.0, 2.16), (900.0, 1.0)]) {
      for (final white in [false, true]) {
        testWidgets('폭 $width 배율 $scale 흰색=$white 에서 넘치지 않는다',
            (tester) async {
          tester.view.physicalSize = Size(width, 1400);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);
          final state = AppState();
          state.smoothTransitions = true;
          state.fadeEnds = true;
          if (white) state.transitionStyle = TransitionStyle.dipWhite;
          await tester.pumpWidget(MaterialApp(
            home: UiScale(
              factor: scale,
              child: Scaffold(
                body: SingleChildScrollView(
                  child: Column(
                    children: [
                      SmoothTransitionCard(
                          state: state, losslessPossibleWithout: true),
                      FadeEndsToggle(
                          state: state, losslessPossibleWithout: true),
                    ],
                  ),
                ),
              ),
            ),
          ));
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(find.text('검은 화면 거치기'), findsOneWidget);
          expect(find.text('흰 화면 거치기'), findsOneWidget);
          expect(find.text('짧게'), findsOneWidget);
          expect(find.text('길게'), findsOneWidget);
          expect(find.text('맨 처음과 맨 끝도 서서히'), findsOneWidget);
          state.dispose();
        });
      }
    }

    testWidgets('끄면 선택 줄이 숨고, 누르면 상태가 바뀐다', (tester) async {
      tester.view.physicalSize = const Size(900, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      Widget build() => MaterialApp(
            home: UiScale(
              factor: 1.0,
              child: Scaffold(
                body: ListenableBuilder(
                  listenable: state,
                  builder: (context, child) => SingleChildScrollView(
                    child: Column(children: [
                      SmoothTransitionCard(
                          state: state, losslessPossibleWithout: false),
                      FadeEndsToggle(
                          state: state, losslessPossibleWithout: false),
                    ]),
                  ),
                ),
              ),
            ),
          );
      await tester.pumpWidget(build());
      expect(find.text('흰 화면 거치기'), findsNothing);

      await tester.tap(find.text('영상 사이를 부드럽게 넘기기'));
      await tester.pump();
      expect(state.smoothTransitions, isTrue);
      expect(find.text('흰 화면 거치기'), findsOneWidget);

      await tester.tap(find.text('흰 화면 거치기'));
      await tester.pump();
      expect(state.transitionStyle, TransitionStyle.dipWhite);
      await tester.tap(find.text('길게'));
      await tester.pump();
      expect(state.transitionLength, TransitionLength.long);

      await tester.tap(find.text('맨 처음과 맨 끝도 서서히'));
      await tester.pump();
      expect(state.fadeEnds, isTrue);
      expect(tester.takeException(), isNull);
      state.dispose();
    });
  });
}
