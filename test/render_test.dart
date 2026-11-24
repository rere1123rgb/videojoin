// 화면이 예외 없이 그려지는지 확인한다.
//
// 흰 화면(렌더링 실패)은 로그도 안 남고 원인을 찾기 어렵다.
// 레이아웃을 건드릴 때마다 이 테스트를 돌려서 잡는다.
//
// `testWidgets` 는 가상 시간이라 실제 프로세스를 `await` 하면 멈추므로
// ffmpeg 을 띄우는 AppState.init() 은 부르지 않는다.
//
//   flutter test test/render_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videojoin/main.dart';
import 'package:videojoin/state/app_state.dart';
import 'package:videojoin/ui/theme.dart';
import 'package:videojoin/ui/widgets/common.dart';
import 'package:videojoin/ui/widgets/signature.dart';

Widget _wrap(Widget child, {double width = 900}) {
  return MaterialApp(
    home: UiScale(
      factor: 1.0,
      child: Scaffold(body: SizedBox(width: width, child: child)),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('앱 뼈대가 예외 없이 그려진다', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 초기화 전 화면이 그려지는지만 본다.
    final state = AppState();
    await tester.pumpWidget(VideoJoinApp(state: state));
    await tester.pump();

    expect(tester.takeException(), isNull);
    state.dispose();
  });

  group('선택지 줄(ChoiceRow)', () {
    testWidgets('좁은 폭에서 깨지지 않는다', (tester) async {
      tester.view.physicalSize = const Size(700, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_wrap(
        ChoiceRow(
          selected: true,
          label: '그대로 이어붙이기',
          value: '1.2 GB',
          badge: '추천',
          note: '화질 손실 없음 · 아주 빠름 (모든 영상 설정이 같습니다)',
          onTap: () {},
        ),
        width: 380,
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('그대로 이어붙이기'), findsOneWidget);
    });

    testWidgets('넓은 폭에서 깨지지 않는다', (tester) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_wrap(
        ChoiceRow(
          selected: false,
          label: '원본 유지',
          value: '63 Mbps',
          badge: '원본',
          note: '원본 최대 · uhd_4k.mp4',
          onTap: () {},
        ),
        width: 1100,
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('원본 유지'), findsOneWidget);
    });

    testWidgets('값과 비고가 없어도 그려진다', (tester) async {
      await tester.pumpWidget(_wrap(
        ChoiceRow(selected: false, label: '30p', onTap: () {}),
        width: 600,
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('서명', () {
    testWidgets('문구를 넣지 않고 빌드하면 서명 없이 버전만', (tester) async {
      await tester.pumpWidget(
          _wrap(const Signature(author: '', cheer: '')));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('만든 사람'), findsNothing);
    });

    testWidgets('눈에 띄지 않게 그려진다', (tester) async {
      await tester.pumpWidget(_wrap(const Signature(author: '만든 사람 : 시험', cheer: '시험 인사')));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('만든 사람'), findsOneWidget);
    });

    testWidgets('20번 누르면 인사가 나오고 정상적으로 사라진다', (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_wrap(const Signature(author: '만든 사람 : 시험', cheer: '시험 인사')));
      await tester.pump();

      // 19번까지는 아무 일도 없어야 한다.
      for (var i = 0; i < 19; i++) {
        await tester.tap(find.textContaining('만든 사람'));
        await tester.pump();
      }
      expect(find.text('시험 인사'), findsNothing);

      await tester.tap(find.textContaining('만든 사람'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('시험 인사'), findsOneWidget);

      // 애니메이션이 끝나면 스스로 사라져야 한다.
      await tester.pump(const Duration(seconds: 4));
      expect(tester.takeException(), isNull);
      expect(find.text('시험 인사'), findsNothing);
    });
  });
}
