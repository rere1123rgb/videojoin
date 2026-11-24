// 목록을 끌어서 순서를 바꿨을 때 원하는 자리에 정확히 들어가는지.
// Flutter 3.47 에서 onReorder 가 onReorderItem 으로 바뀌며 newIndex 의 뜻이
// 달라졌다. 옛 방식대로 1 을 빼면 한 칸씩 어긋나므로 실제로 끌어서 확인한다.
//
//   flutter test test/reorder_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videojoin/engine/models.dart';
import 'package:videojoin/state/app_state.dart';
import 'package:videojoin/ui/theme.dart';
import 'package:videojoin/ui/widgets/clip_list.dart';

VideoSpec _spec(String name) => VideoSpec(
      path: 'C:\\nowhere\\$name.mp4',
      fileSize: 1,
      fileModified: DateTime(2026),
      fileCreated: DateTime(2026),
      rawWidth: 1920,
      rawHeight: 1080,
      durationSec: 10,
      hasAudio: true,
    );

Future<AppState> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final state = AppState();
  for (final n in ['A', 'B', 'C', 'D']) {
    state.clips.add(ClipItem(id: n, spec: _spec(n)));
  }
  await tester.pumpWidget(MaterialApp(
    home: UiScale(
      factor: 1.0,
      child: Scaffold(body: SingleChildScrollView(child: ClipList(state: state))),
    ),
  ));
  await tester.pump();
  return state;
}

Future<void> _drag(WidgetTester tester, int from, int to) async {
  final handles = find.byType(ReorderableDragStartListener);
  final start = tester.getCenter(handles.at(from));
  final target = tester.getCenter(handles.at(to));
  // 목표 줄의 중심을 조금 넘기면 그 자리로 들어간다.
  final dy = target.dy - start.dy + (to > from ? 10 : -10);
  final g = await tester.startGesture(start);
  await tester.pump(const Duration(milliseconds: 100));
  for (var i = 1; i <= 10; i++) {
    await g.moveTo(start + Offset(0, dy * i / 10));
    await tester.pump(const Duration(milliseconds: 30));
  }
  await g.up();
  // 썸네일 자리의 돌아가는 표시 때문에 pumpAndSettle 은 끝나지 않는다.
  // 내려놓는 애니메이션이 끝날 만큼 프레임을 여러 번 돌린다.
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('첫 줄을 셋째 자리로 끌면 B C A D', (tester) async {
    final state = await _pump(tester);
    await _drag(tester, 0, 2);
    expect(state.clips.map((c) => c.id).join(), 'BCAD');
    state.dispose();
  });

  testWidgets('넷째 줄을 첫 자리로 끌면 D A B C', (tester) async {
    final state = await _pump(tester);
    await _drag(tester, 3, 0);
    expect(state.clips.map((c) => c.id).join(), 'DABC');
    state.dispose();
  });
}
