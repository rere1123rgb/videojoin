// 한글 조합 중 커서 표시 보정 검증.
//
// 윈도우 Flutter 엔진은 조합 중인 글자 '앞'에 커서를 보낸다.
// 여기서 지키려는 것은 두 가지다.
//
//   1. 커서가 조합 중인 글자 뒤에 그려진다.
//   2. **입력칸의 값은 절대 바뀌지 않는다.** 값을 고치면 실제 IME 에서
//      조합이 끊겨 글자가 망가진다.
//
//   flutter test test/hangul_caret_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:videojoin/ui/hangul_caret.dart';

/// 엔진이 보내오는(버그가 있는) 값을 흉내낸다.
/// 조합 구간은 [start]~[end], 커서는 엔진이 계산한 [caret].
TextEditingValue fromEngine(String text, int start, int end, int caret) {
  return TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: caret),
    composing: TextRange(start: start, end: end),
  );
}

void main() {
  group('잘못 놓인 커서 판별', () {
    test("'테' 를 치는 중 — 커서가 맨 앞에 와 있으면 잘못된 것", () {
      expect(caretIsMisplaced(fromEngine('테', 0, 1, 0)), isTrue);
    });

    test("'테스트용' 의 '용' 을 치는 중 — 커서가 '트'와 '용' 사이면 잘못된 것", () {
      expect(caretIsMisplaced(fromEngine('테스트용', 3, 4, 3)), isTrue);
    });

    test('커서가 이미 조합 글자 뒤면 문제없다', () {
      expect(caretIsMisplaced(fromEngine('테스트용', 3, 4, 4)), isFalse);
    });

    test('조합이 끝난 값은 해당 없다', () {
      const v = TextEditingValue(
        text: '테스트용',
        selection: TextSelection.collapsed(offset: 2),
      );
      expect(caretIsMisplaced(v), isFalse);
    });

    test('글자를 범위로 골라 둔 상태는 해당 없다', () {
      const v = TextEditingValue(
        text: '테스트용',
        selection: TextSelection(baseOffset: 0, extentOffset: 4),
        composing: TextRange(start: 3, end: 4),
      );
      expect(caretIsMisplaced(v), isFalse);
    });

    test('조합 도중 커서를 직접 옮긴 경우는 존중한다', () {
      // 일본어·중국어 IME 는 긴 조합 안에서 커서를 옮길 수 있다.
      expect(caretIsMisplaced(fromEngine('がっこう', 0, 4, 2)), isFalse);
    });

    test('조합 구간이 글자 수를 넘으면 손대지 않는다', () {
      expect(caretIsMisplaced(fromEngine('테', 0, 5, 0)), isFalse);
    });
  });

  group('HangulCaretFix', () {
    Future<TextEditingController> pumpField(WidgetTester tester) async {
      final c = TextEditingController();
      addTearDown(c.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              child: HangulCaretFix(
                controller: c,
                builder: (context, cursorColor) => TextField(
                  controller: c,
                  cursorColor: cursorColor,
                  style: const TextStyle(fontSize: 20),
                ),
              ),
            ),
          ),
        ),
      ));
      return c;
    }

    testWidgets('입력칸의 값을 바꾸지 않는다', (tester) async {
      final c = await pumpField(tester);

      final engine = fromEngine('테스트용', 3, 4, 3);
      c.value = engine;
      await tester.pump();
      await tester.pump();

      // 한 글자, 한 칸도 달라지면 안 된다. 값이 달라지면 Flutter 가 그 값을
      // 엔진으로 되돌려 보내고, 엔진은 그 순간 조합 상태를 잃는다.
      expect(c.value, engine);
    });

    testWidgets('조합 중에는 커서를 글자 뒤에 대신 그린다', (tester) async {
      final c = await pumpField(tester);
      expect(find.byKey(HangulCaretFix.caretKey), findsNothing);

      c.value = fromEngine('테스트', 2, 3, 2);
      await tester.pump();
      await tester.pump();
      final x3 = tester.getTopLeft(find.byKey(HangulCaretFix.caretKey)).dx;

      // 글자가 하나 늘면 커서도 그만큼 오른쪽으로 가야 한다.
      c.value = fromEngine('테스트용', 3, 4, 3);
      await tester.pump();
      await tester.pump();
      final x4 = tester.getTopLeft(find.byKey(HangulCaretFix.caretKey)).dx;
      expect(x4, greaterThan(x3));

      // 입력칸의 글자 영역 안, 마지막 글자 뒤에 있어야 한다.
      final field = tester.getRect(find.byType(EditableText));
      expect(x4, greaterThan(field.left));
      expect(x4, lessThanOrEqualTo(field.right));

      // 진짜 커서는 그동안 숨겨 둔다(안 그러면 커서가 두 개 보인다).
      final editable = tester.widget<EditableText>(find.byType(EditableText));
      expect(editable.cursorColor, Colors.transparent);
    });

    testWidgets('조합이 끝나면 대신 그린 커서를 치우고 원래대로 돌아간다', (tester) async {
      final c = await pumpField(tester);

      c.value = fromEngine('테스트용', 3, 4, 3);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(HangulCaretFix.caretKey), findsOneWidget);

      c.value = const TextEditingValue(
        text: '테스트용',
        selection: TextSelection.collapsed(offset: 4),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(HangulCaretFix.caretKey), findsNothing);

      final editable = tester.widget<EditableText>(find.byType(EditableText));
      expect(editable.cursorColor, isNot(Colors.transparent));
    });

    testWidgets('커서를 대신 그렸다 치웠다 해도 입력칸이 새로 만들어지지 않는다', (tester) async {
      // 그릴 때만 다른 위젯으로 감싸면 입력칸이 트리에서 자리를 옮겨
      // 새 입력칸으로 취급되어 포커스와 조합을 잃는다.
      final c = await pumpField(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      final before = tester.state<EditableTextState>(find.byType(EditableText));
      expect(before.widget.focusNode.hasFocus, isTrue);

      c.value = fromEngine('테', 0, 1, 0);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(HangulCaretFix.caretKey), findsOneWidget);
      final during = tester.state<EditableTextState>(find.byType(EditableText));
      expect(identical(before, during), isTrue, reason: '입력칸이 새로 만들어졌다');
      expect(during.widget.focusNode.hasFocus, isTrue, reason: '포커스를 잃었다');

      c.value = const TextEditingValue(
        text: '테',
        selection: TextSelection.collapsed(offset: 1),
      );
      await tester.pump();
      await tester.pump();
      final after = tester.state<EditableTextState>(find.byType(EditableText));
      expect(identical(before, after), isTrue);
      expect(after.widget.focusNode.hasFocus, isTrue);
    });

    testWidgets('영문 입력에는 끼어들지 않는다', (tester) async {
      final c = await pumpField(tester);
      c.value = const TextEditingValue(
        text: 'merged',
        selection: TextSelection.collapsed(offset: 6),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(HangulCaretFix.caretKey), findsNothing);
    });
  });
}
