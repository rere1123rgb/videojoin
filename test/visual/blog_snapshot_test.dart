// 블로그용 화면 5장을 실제 글꼴·실제 샘플 영상으로 그려 PNG 로 남긴다.
//   $env:VJ_SNAPSHOT_DIR='...'; flutter test test/visual/blog_snapshot_test.dart
// 개인 정보가 나오지 않도록 D:\sample 의 영상만 쓴다.

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
import 'package:videojoin/engine/job_queue.dart';
import 'package:videojoin/engine/models.dart';
import 'package:videojoin/engine/prober.dart';
import 'package:videojoin/engine/thumbnailer.dart';
import 'package:videojoin/engine/transition_style.dart';
import 'package:videojoin/state/app_state.dart';
import 'package:videojoin/ui/home_screen.dart';
import 'package:videojoin/ui/theme.dart';
import 'package:videojoin/ui/widgets/clip_editor.dart';
import 'package:videojoin/ui/widgets/clip_list.dart';
import 'package:videojoin/ui/widgets/queue_panel.dart';
import 'package:videojoin/ui/widgets/settings_panel.dart';

final _outDir = Platform.environment['VJ_SNAPSHOT_DIR'];
final _root = Directory.current.path;
final _tools = FFTools(
  ffmpegPath: p.join(_root, 'tools', 'ffmpeg.exe'),
  ffprobePath: p.join(_root, 'tools', 'ffprobe.exe'),
);
const _sample = r'D:\sample';
const _clipNames = [
  '01 호숫가 산책.mp4',
  '02 점심 식사.mp4',
  '03 전망대.mp4',
  '04 돌아오는 길.mp4',
];

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
  await _loadFont('Malgun Gothic', ['$win\\malgun.ttf', '$win\\malgunbd.ttf']);
  // 글꼴을 지정하지 않은 글자(눈금 숫자 등)는 테스트 기본 글꼴로 그려진다.
  await _loadFont('FlutterTest', ['$win\\malgun.ttf', '$win\\malgunbd.ttf']);
  for (final fam in ['Roboto', 'Segoe UI']) {
    // 숫자·영문은 Segoe UI, 한글은 맑은 고딕(fontFamilyFallback)이 맡는다.
    await _loadFont(fam, ['$win\\segoeui.ttf', '$win\\segoeuib.ttf']);
  }
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ??
      p.dirname(p.dirname(Platform.resolvedExecutable));
  await _loadFont('MaterialIcons', [
    p.join(flutterRoot, 'bin', 'cache', 'artifacts', 'material_fonts',
        'MaterialIcons-Regular.otf'),
  ]);
}

Future<void> _snap(WidgetTester tester, GlobalKey key, String name) async {
  await tester.runAsync(() async {
    Directory(_outDir!).createSync(recursive: true);
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File(p.join(_outDir!, name)).writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

Future<void> _settleReal(WidgetTester tester, {int ms = 2500}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  final images = tester.widgetList<Image>(find.byType(Image)).toList();
  for (final img in images) {
    final el = tester.element(find.byWidget(img));
    await tester.runAsync(() => precacheImage(img.image, el));
  }
  await tester.pump();
}

Future<void> _setup(WidgetTester tester, double w, double h) async {
  SharedPreferences.setMockInitialValues({
    'askedDesktopShortcut': true,
    'outputDir': _sample,
  });
  await _loadFonts();
  // 작업표시줄 플러그인은 테스트에 없으므로 호출을 삼킨다.
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('com.alexmercerind/windows_taskbar'),
          (call) async => null);
  tester.view.physicalSize = Size(w, h);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 앱 테마의 글자 모양에는 글꼴 이름이 없어서 테스트에서는 네모 글꼴로 떨어진다.
/// 맑은 고딕(한글·숫자·영문 모두 들어 있음)을 이름으로 박아 준다.
ThemeData _withFont(ThemeData t) => t.copyWith(
      textTheme: t.textTheme.apply(fontFamily: 'Malgun Gothic'),
      primaryTextTheme: t.primaryTextTheme.apply(fontFamily: 'Malgun Gothic'),
    );

/// 다이얼로그까지 한 장에 담기도록 MaterialApp 바깥에서 찍는다.
Widget _app(GlobalKey key, double scale, Widget home) => RepaintBoundary(
      key: key,
      child: MaterialApp(
        theme: _withFont(buildAppTheme(scale)),
        debugShowCheckedModeBanner: false,
        builder: (context, child) => UiScale(factor: scale, child: child!),
        home: home,
      ),
    );

Future<AppState> _stateWith(WidgetTester tester, List<String> paths) async {
  final state = AppState()
    ..tools = _tools
    ..initialized = true
    ..outputDir = _sample;
  await tester.runAsync(() => state.addPaths(paths));
  return state;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final skip = _outDir == null ? 'VJ_SNAPSHOT_DIR 가 없어서 건너뜀' : null;
  final samples = [for (final n in _clipNames) p.join(_sample, n)];

  testWidgets('01 메인 화면', (tester) async {
    await _setup(tester, 1600, 3500);
    final state = await _stateWith(tester, samples);
    final key = GlobalKey();
    await tester.pumpWidget(_app(key, 1.0, HomeScreen(state: state)));
    await _settleReal(tester, ms: 5000);
    expect(find.textContaining('만든 사람'), findsNothing);
    await _snap(tester, key, '01_main.png');
    state.dispose();
  }, skip: skip != null);

  testWidgets('02 편집 창', (tester) async {
    await _setup(tester, 1600, 1000);
    final spec = (await tester.runAsync(
        () => Prober(_tools).probe(p.join(_sample, _clipNames[0]))))!;
    final thumb =
        await tester.runAsync(() => Thumbnailer(_tools).generate(spec));
    final state = AppState()..tools = _tools;
    final clip = ClipItem(id: 'x', spec: spec, thumbnailPath: thumb);
    state.clips.add(clip);
    final key = GlobalKey();
    await tester.pumpWidget(_app(
        key,
        1.0,
        Scaffold(
          backgroundColor: const Color(0xFF555555),
          body: ClipEditorDialog(
            state: state,
            clip: clip,
            grabber: FrameGrabber(_tools),
            position: 1,
            count: 4,
          ),
        )));
    await _settleReal(tester, ms: 2500);
    // 단축키: Home -> 오른쪽(Shift 5초, 그냥 1초) -> I(시작) -> 이동 -> O(끝)
    final d = spec.durationSec;
    // ignore: avoid_print
    print('duration=$d');
    Future<void> right(int n, {bool shift = false}) async {
      for (var i = 0; i < n; i++) {
        if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      }
    }

    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    final startSec = d * 0.35;
    final span = d * 0.25;
    await right((startSec / 5).floor(), shift: true);
    await right((startSec % 5).round());
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await right((span / 5).floor(), shift: true);
    await right((span % 5).round());
    await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
    await _settleReal(tester, ms: 3500);
    await _snap(tester, key, '02_editor.png');
    state.dispose();
  }, skip: skip != null);

  testWidgets('03 전환 설정', (tester) async {
    await _setup(tester, 1100, 1000);
    final state = AppState();
    await state.setSmoothTransitions(true);
    await state.setTransitionStyle(TransitionStyle.dissolve);
    final key = GlobalKey();
    await tester.pumpWidget(_app(
        key,
        1.0,
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: Column(children: [
                SmoothTransitionCard(
                    state: state, losslessPossibleWithout: true),
                const SizedBox(height: 12),
                FadeEndsToggle(state: state, losslessPossibleWithout: true),
              ]),
            ),
          ),
        )));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await _snap(tester, key, '03_transitions.png');
    state.dispose();
  }, skip: skip != null);

  testWidgets('04 대기열 완료', (tester) async {
    await _setup(tester, 1300, 700);
    final state = await _stateWith(tester, samples);
    final settings = state.buildSettings()!;
    state.queue.add(QueuedJob(
      id: 'q0',
      clips: [for (final c in state.clips) c],
      settings: settings,
      plan: state.plan!,
      status: QueuedStatus.done,
    )
      ..resultPath = p.join(_sample, '${settings.outputName}.mp4')
      ..progress = 1);
    final key = GlobalKey();
    await tester.pumpWidget(_app(
        key,
        1.0,
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(child: QueuePanel(state: state)),
          ),
        )));
    await _settleReal(tester, ms: 1500);
    // ignore: avoid_print
    print('queue out=${state.queue.first.resultPath}');
    await _snap(tester, key, '04_queue_done.png');
    state.dispose();
  }, skip: skip != null);

  testWidgets('05 순서 질문', (tester) async {
    await _setup(tester, 1300, 800);
    final cam = Directory(p.join(_sample, 'camera'))
        .listSync()
        .whereType<File>()
        .map((f) => f.path)
        .where((f) => f.toLowerCase().endsWith('.mp4'))
        .toList()
      ..sort();
    final state = await _stateWith(tester, cam);
    final key = GlobalKey();
    await tester.pumpWidget(_app(
        key,
        1.0,
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(child: ClipList(state: state)),
          ),
        )));
    await _settleReal(tester, ms: 1500);
    await tester.tap(find.text('이름순'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('어느 순서가 맞습니까?'), findsOneWidget);
    await _snap(tester, key, '05_sort_question.png');
    state.dispose();
  }, skip: skip != null);
}
