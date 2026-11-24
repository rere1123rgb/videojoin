// 편집 창을 실제 한글 글꼴·실제 영상 장면으로 그려 PNG 로 남긴다.
// 눈으로 화면을 확인하기 위한 것이라 평소 테스트에서는 건너뛴다.
//
//   $env:VJ_SNAPSHOT_DIR = 'C:\some\dir'; flutter test test/visual/editor_snapshot_test.dart
//
// 화면이 잠겨 있거나 원격 세션이라 실제 창을 캡처할 수 없을 때도 쓸 수 있다.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videojoin/engine/ffmpeg_tools.dart';
import 'package:videojoin/engine/frame_grabber.dart';
import 'package:videojoin/engine/models.dart';
import 'package:videojoin/engine/planner.dart';
import 'package:videojoin/engine/prober.dart';
import 'package:videojoin/engine/thumbnailer.dart';
import 'package:videojoin/state/app_state.dart';
import 'package:videojoin/ui/theme.dart';
import 'package:videojoin/ui/widgets/clip_editor.dart';
import 'package:videojoin/ui/widgets/clip_list.dart';
import 'package:videojoin/ui/widgets/settings_panel.dart';

final _outDir = Platform.environment['VJ_SNAPSHOT_DIR'];
final _root = Directory.current.path;
final _tools = FFTools(
  ffmpegPath: p.join(_root, 'tools', 'ffmpeg.exe'),
  ffprobePath: p.join(_root, 'tools', 'ffprobe.exe'),
);

Future<void> _loadFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    if (File(f).existsSync()) {
      final bytes = File(f).readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
  }
  await loader.load();
}

Future<void> _loadFonts() async {
  const win = r'C:\Windows\Fonts';
  await _loadFont('Malgun Gothic',
      ['$win\\malgun.ttf', '$win\\malgunbd.ttf']);
  // 테스트의 기본 글꼴(Roboto 자리)은 글자를 네모로 그린다. 맑은 고딕을 씌운다.
  for (final fam in ['Roboto', 'Segoe UI']) {
    await _loadFont(fam, ['$win\\malgun.ttf', '$win\\malgunbd.ttf']);
  }
  // 머티리얼 아이콘 글꼴은 Flutter SDK 안에 있다.
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ??
      p.dirname(p.dirname(Platform.resolvedExecutable));
  final candidates = [
    p.join(flutterRoot, 'bin', 'cache', 'artifacts', 'material_fonts',
        'MaterialIcons-Regular.otf'),
  ];
  await _loadFont('MaterialIcons', candidates);
}

Future<void> _snap(WidgetTester tester, GlobalKey key, String name) async {
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File(p.join(_outDir!, name)).writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

/// 실제 시간으로 기다리면서 화면을 갱신한다(장면 뽑기·이미지 해독).
Future<void> _settleReal(WidgetTester tester, {int ms = 2500}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  // 화면에 걸린 파일 이미지들을 실제로 해독시킨다.
  final images = tester.widgetList<Image>(find.byType(Image)).toList();
  for (final img in images) {
    final el = tester.element(find.byWidget(img));
    await tester.runAsync(() => precacheImage(img.image, el));
  }
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final skip = _outDir == null ? 'VJ_SNAPSHOT_DIR 가 없어서 건너뜀' : null;

  for (final (w, h, scale, tag) in const [
    (1600.0, 1000.0, 1.0, 'normal'),
    (1280.0, 900.0, 1.35, 'bigtext'),
  ]) {
    testWidgets('편집 창 스냅샷 $tag', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await _loadFonts();
      tester.view.physicalSize = Size(w, h);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final spec = (await tester.runAsync(() =>
          Prober(_tools).probe(Platform.environment['VJ_SNAPSHOT_FILE'] ??
              p.join(_root, 'testdata', 'vfr_phone.mp4'))))!;
      final thumb = await tester.runAsync(() => Thumbnailer(_tools).generate(spec));
      final state = AppState()..tools = _tools;
      final clip = ClipItem(
        id: 'x',
        spec: spec,
        thumbnailPath: thumb,
        edit: ClipEdit(
          keep: [
            TimeRange(0, spec.durationSec * 0.30),
            TimeRange(spec.durationSec * 0.45, spec.durationSec),
          ],
          volume: VolumeLevel.normal,
        ),
      );
      state.clips.add(clip);

      final key = GlobalKey();
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(scale),
        debugShowCheckedModeBanner: false,
        home: UiScale(
          factor: scale,
          child: RepaintBoundary(
            key: key,
            child: Scaffold(
              backgroundColor: const Color(0xFF555555),
              body: ClipEditorDialog(
                state: state,
                clip: clip,
                grabber: FrameGrabber(_tools),
                position: 2,
                count: 5,
              ),
            ),
          ),
        ),
      ));
      await _settleReal(tester, ms: 4000);
      await _snap(tester, key, 'editor_$tag.png');

      // 띠를 끌어서 구간을 고른 모습
      final strip = find.byType(Row).evaluate().isEmpty ? null : null;
      expect(strip, isNull);
      state.dispose();
    }, skip: skip != null);
  }

  testWidgets('목록 스냅샷', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _loadFonts();
    tester.view.physicalSize = const Size(1200, 420);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final prober = Prober(_tools);
    final a = (await tester.runAsync(
        () => prober.probe(p.join(_root, 'testdata', 'same_a.mp4'))))!;
    final b = (await tester.runAsync(
        () => prober.probe(p.join(_root, 'testdata', 'vfr_phone.mp4'))))!;
    final ta = await tester.runAsync(() => Thumbnailer(_tools).generate(a));
    final tb = await tester.runAsync(() => Thumbnailer(_tools).generate(b));
    final state = AppState()..tools = _tools;
    state.clips.addAll([
      ClipItem(id: '1', spec: a, thumbnailPath: ta),
      ClipItem(
        id: '2',
        spec: b,
        thumbnailPath: tb,
        edit: ClipEdit(
          keep: [TimeRange(1, b.durationSec * 0.6)],
          volume: VolumeLevel.low,
        ),
      ),
    ]);
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(1.0),
      debugShowCheckedModeBanner: false,
      home: UiScale(
        factor: 1.0,
        child: RepaintBoundary(
          key: key,
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: SingleChildScrollView(child: ClipList(state: state)),
            ),
          ),
        ),
      ),
    ));
    await _settleReal(tester, ms: 1000);
    await _snap(tester, key, 'list.png');
    state.dispose();
  }, skip: skip != null);

  // 폭·배율을 바꿔 가며 전환 설정 카드를 그린다. 마지막은 좁은 패널 + 큰 글자.
  for (final c in const [
    ('transitions.png', 900.0, 1.0, 1100.0),
    ('transitions_narrow.png', 540.0, 2.16, 2600.0),
  ]) {
    testWidgets('전환 설정 스냅샷 ${c.$1}', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await _loadFonts();
      tester.view.physicalSize = Size(c.$2, c.$4);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      await state.setSmoothTransitions(true);
      await state.setTransitionStyle(TransitionStyle.push);
      final key = GlobalKey();
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(c.$3),
        debugShowCheckedModeBanner: false,
        home: UiScale(
          factor: c.$3,
          child: RepaintBoundary(
            key: key,
            child: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: SingleChildScrollView(
                  child: Column(children: [
                    SmoothTransitionCard(
                        state: state, losslessPossibleWithout: true),
                    const SizedBox(height: 12),
                    FadeEndsToggle(
                        state: state, losslessPossibleWithout: true),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ));
      // 맛보기 그림(자산)을 실제로 읽어 들일 시간을 준다.
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(tester.takeException(), isNull);
      await _snap(tester, key, c.$1);
      state.dispose();
    }, skip: skip != null);
  }
}
