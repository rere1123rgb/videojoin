import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'state/app_state.dart';
import 'ui/home_screen.dart';
import 'ui/theme.dart';
import 'ui/widgets/signature.dart';

/// [args] 로 영상 경로가 들어오면 시작하자마자 목록에 올린다.
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  final plan = await _planWindow();

  final options = WindowOptions(
    size: plan.size,
    minimumSize: plan.minimumSize,
    center: true,
    title: kReleaseTag.isEmpty ? '영상 합치기' : '영상 합치기 ($kReleaseTag)',
    titleBarStyle: TitleBarStyle.normal,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  await _keepWindowOnScreen();

  final state = AppState();
  runApp(VideoJoinApp(state: state));
  await state.init();

  // 지난번에 끝내지 못한 대기열이 있으면 이어서 할지 물어보게 된다.
  state.enableQueueStore();

  if (args.isNotEmpty) {
    await state.addPaths(args);
  }

  unawaited(state.checkShortcutsOnStartup());
}

/// 화면에 맞는 창 크기를 계산한다.
///
/// 창 크기는 논리 픽셀 단위이고 논리 화면 크기는 배율이 올라갈수록 작아진다
/// (4K + 250% → 1536 × 864). 고정 크기는 창이 화면보다 커져 제목 표시줄이
/// 잘릴 수 있으므로 언제나 화면에서 역산한다.
Future<({Size size, Size minimumSize})> _planWindow() async {
  final work = await _workAreaSize();

  // 8% 는 창 그림자와 작업표시줄 여유.
  final w = math.min(1280.0, work.width * 0.92);
  final h = math.min(940.0, work.height * 0.92);

  // 최소 크기도 화면보다 크면 작은 화면에서 창이 갇힌다.
  final minW = math.min(880.0, work.width * 0.7);
  final minH = math.min(620.0, work.height * 0.7);

  return (
    size: Size(w.roundToDouble(), h.roundToDouble()),
    minimumSize: Size(minW.roundToDouble(), minH.roundToDouble()),
  );
}

/// 작업표시줄을 뺀 화면 크기(논리 픽셀).
/// 화면 정보를 못 읽으면 보수적인 값으로 물러선다.
Future<Size> _workAreaSize() async {
  try {
    final d = await screenRetriever.getPrimaryDisplay();
    final s = d.visibleSize ?? d.size;
    if (s.width > 200 && s.height > 200) return s;
  } on Object {
    // 아래 폴백으로 간다.
  }

  try {
    final view = ui.PlatformDispatcher.instance.views.first;
    final dpr = view.display.devicePixelRatio;
    if (dpr > 0) {
      final s = view.display.size;
      // 작업표시줄 몫으로 세로 6% 를 빼둔다.
      return Size(s.width / dpr, s.height / dpr * 0.94);
    }
  } on Object {
    // 아래 폴백으로 간다.
  }

  return const Size(1024, 700);
}

/// 창이 화면 밖으로 나갔거나 화면보다 크면 되돌린다.
///
/// 앞의 계산이 맞더라도 window_manager 나 OS 가 크기를 다르게 잡을 수 있다.
/// 여기서 한 번 더 확인해야 사용자가 창을 잡을 수 없는 상태에 빠지지 않는다.
Future<void> _keepWindowOnScreen() async {
  try {
    final d = await screenRetriever.getPrimaryDisplay();
    final work = d.visibleSize ?? d.size;
    final origin = d.visiblePosition ?? Offset.zero;

    final b = await windowManager.getBounds();

    final w = math.min(b.width, work.width);
    final h = math.min(b.height, work.height);
    final maxX = origin.dx + work.width - w;
    final maxY = origin.dy + work.height - h;
    final x = b.left.clamp(origin.dx, math.max(origin.dx, maxX)).toDouble();
    final y = b.top.clamp(origin.dy, math.max(origin.dy, maxY)).toDouble();

    const eps = 1.0;
    final needsFix = (w - b.width).abs() > eps ||
        (h - b.height).abs() > eps ||
        (x - b.left).abs() > eps ||
        (y - b.top).abs() > eps;

    if (needsFix) {
      await windowManager.setBounds(Rect.fromLTWH(x, y, w, h));
    }
  } on Object {
    // 보정에 실패해도 앱은 떠야 한다.
  }
}

class VideoJoinApp extends StatelessWidget {
  final AppState state;

  const VideoJoinApp({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final scale = autoUiScale() * state.uiScaleBoost;
        return MaterialApp(
          title: kReleaseTag.isEmpty ? '영상 합치기' : '영상 합치기 ($kReleaseTag)',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(scale),
          home: UiScale(
            factor: scale,
            child: HomeScreen(state: state),
          ),
        );
      },
    );
  }
}
