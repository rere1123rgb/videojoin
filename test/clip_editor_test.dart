// 편집 화면의 조각 로직과 화면 그리기.
//
//   flutter test test/clip_editor_test.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videojoin/engine/ffmpeg_tools.dart';
import 'package:videojoin/engine/frame_grabber.dart';
import 'package:videojoin/engine/models.dart';
import 'package:videojoin/state/app_state.dart';
import 'package:videojoin/ui/theme.dart';
import 'package:videojoin/ui/editor/parts/editor_controls.dart';
import 'package:videojoin/ui/widgets/clip_editor.dart';
import 'package:videojoin/ui/widgets/clip_list.dart';

List<(double, double, bool)> _dump(EditPieces e) =>
    [for (final p in e.pieces) (p.start, p.end, p.keep)];

VideoSpec _spec(double dur) => VideoSpec(
      path: r'C:\nowhere\a.mp4',
      fileSize: 1,
      fileModified: DateTime(2026),
      fileCreated: DateTime(2026),
      rawWidth: 1920,
      rawHeight: 1080,
      durationSec: dur,
      hasAudio: true,
    );

void main() {
  group('EditPieces', () {
    test('편집 없음 → 조각 하나, 남길 구간 없음', () {
      final e = EditPieces.fromKeep(10, const []);
      expect(_dump(e), [(0.0, 10.0, true)]);
      expect(e.toKeep(), isEmpty);
      expect(e.keptDuration, 10);
    });

    test('가운데 빼기: 두 번 자르고 사이를 뺀다', () {
      final e = EditPieces.fromKeep(10, const []);
      expect(e.cutAt(3), 1);
      expect(e.cutAt(6), 2);
      e.toggleAt(4.5);
      e.mergeSame();
      expect(e.toKeep(), const [TimeRange(0, 3), TimeRange(6, 10)]);
      expect(e.keptDuration, 7);
      expect(e.cutPoints, [3.0, 6.0]);
    });

    test('경계에 너무 가까우면 자르지 않는다', () {
      final e = EditPieces.fromKeep(10, const []);
      expect(e.cutAt(0.2), isNull);
      expect(e.cutAt(9.8), isNull);
      e.cutAt(5);
      expect(e.cutAt(5.3), isNull);
    });

    test('여기부터 쓰기 / 여기까지만 쓰기', () {
      final e = EditPieces.fromKeep(10, const []);
      e.startHere(2);
      e.endHere(8);
      e.mergeSame();
      expect(e.toKeep(), const [TimeRange(2, 8)]);
    });

    test('여기부터 쓰기는 이미 뺀 조각 안에서 눌러도 그 지점부터 살린다', () {
      final e = EditPieces.fromKeep(10, const [TimeRange(5, 10)]);
      e.startHere(3);
      e.mergeSame();
      expect(e.toKeep(), const [TimeRange(3, 10)]);
    });

    test('저장된 구간에서 되살리면 같은 구간이 나온다', () {
      const keep = [TimeRange(1, 3), TimeRange(5, 7.5)];
      final e = EditPieces.fromKeep(10, keep);
      expect(_dump(e), [
        (0.0, 1.0, false),
        (1.0, 3.0, true),
        (3.0, 5.0, false),
        (5.0, 7.5, true),
        (7.5, 10.0, false),
      ]);
      expect(e.toKeep(), keep);
    });

    test('다시 넣기로 전부 살리면 자르지 않은 것과 같다', () {
      final e = EditPieces.fromKeep(10, const [TimeRange(0, 4)]);
      e.toggleAt(6);
      e.mergeSame();
      expect(e.toKeep(), isEmpty);
      expect(e.pieces.length, 1);
    });

    test('끌어서 고른 구간 빼기/다시 넣기는 조각 경계와 상관없이 된다', () {
      final e = EditPieces.fromKeep(20, const []);
      e.setRange(5, 8, false);
      expect(e.toKeep(), const [TimeRange(0, 5), TimeRange(8, 20)]);
      // 뺀 곳과 남긴 곳에 걸친 구간을 또 뺀다
      e.setRange(7, 12, false);
      expect(e.toKeep(), const [TimeRange(0, 5), TimeRange(12, 20)]);
      // 뺀 구간 일부만 되살린다
      e.setRange(6, 9, true);
      expect(e.toKeep(),
          const [TimeRange(0, 5), TimeRange(6, 9), TimeRange(12, 20)]);
      // 뒤집힌 순서로 줘도 같다
      e.setRange(20, 12, false);
      expect(e.toKeep(), const [TimeRange(0, 5), TimeRange(6, 9)]);
    });

    test('0.5초 미만 부스러기는 옆 조각에 붙는다', () {
      final e = EditPieces.fromKeep(20, const []);
      e.setRange(0.2, 6, false); // 앞에 0.2초가 남는다 → 같이 빠진다
      expect(_dump(e), [(0.0, 6.0, false), (6.0, 20.0, true)]);
      e.setRange(6.3, 10, false); // 사이에 0.3초 → 같이 빠진다
      expect(_dump(e), [(0.0, 10.0, false), (10.0, 20.0, true)]);
    });

    test('copy 는 서로 영향을 주지 않는다(되돌리기)', () {
      final e = EditPieces.fromKeep(10, const []);
      final snap = e.copy();
      e.cutAt(5);
      expect(snap.pieces.length, 1);
      expect(e.pieces.length, 2);
    });
  });

  test('formatClock', () {
    expect(formatClock(0), '0:00');
    expect(formatClock(83.47, precise: true), '1:23.4');
    expect(formatClock(3723), '1:02:03');
  });

  test('TimeRange.fromJson 은 숫자가 아닌 값에도 예외 없이 null', () {
    expect(TimeRange.fromJson({'s': 'x', 'e': 5}), isNull);
    expect(ClipEdit.fromJson({'keep': [{'s': 'x', 'e': 5}, {'s': 1, 'e': 3}]}).keep,
        const [TimeRange(1, 3)]);
  });

  group('편집 창 그리기', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    // (창 크기, 글씨 배율). 넓은 4K 화면은 자동 배율 1.6 에 사용자가
    // '아주 크게'(1.35)를 고르면 2.16 까지 간다. 작은 창은 최소 크기 880×620.
    for (final (size, scale) in const [
      (Size(1600, 1000), 1.0),
      (Size(1280, 720), 1.0),
      (Size(1280, 940), 2.16),
      (Size(880, 620), 1.35),
    ]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()} 배율 $scale 에서 예외 없이 그려지고 적용된다',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final state = AppState();
        final clip = ClipItem(
          id: 'x',
          spec: _spec(20),
          edit: const ClipEdit(keep: [TimeRange(2, 9), TimeRange(12, 18)]),
        );
        state.clips.add(clip);

        // 장면 뽑기는 없는 실행 파일을 가리켜서 바로 실패하게 둔다.
        final grabber = FrameGrabber(
            const FFTools(ffmpegPath: r'C:\nowhere\ffmpeg.exe', ffprobePath: ''));

        await tester.pumpWidget(MaterialApp(
          home: UiScale(
            factor: scale,
            child: Scaffold(
              body: ClipEditorDialog(
                  state: state, clip: clip, grabber: grabber, position: 2, count: 3),
            ),
          ),
        ));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        expect(find.text('여기부터 쓰기'), findsOneWidget);
        expect(find.text('빠짐'), findsWidgets);
        expect(find.text('이전 영상'), findsOneWidget);
        expect(find.text('다음 영상'), findsOneWidget);
        expect(find.text('재생'), findsOneWidget);
        final previewH =
            tester.getSize(find.byKey(const ValueKey('clip-editor-preview'))).height;
        expect(previewH, greaterThanOrEqualTo(200));

        // 소리 끄기 → 적용
        await tester.ensureVisible(find.text('소리 끄기'));
        await tester.tap(find.text('소리 끄기'));
        await tester.pump();
        await tester.ensureVisible(find.text('적용'));
        await tester.pump();
        await tester.tap(find.text('적용'));
        await tester.pump();
        expect(clip.edit.volume, VolumeLevel.mute);
        expect(clip.edit.keep, const [TimeRange(2, 9), TimeRange(12, 18)]);
        expect(tester.takeException(), isNull);
        state.dispose();
      });
    }
  });

  group('목록 줄(손보기 버튼 포함)', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));
    for (final (width, scale) in const [
      (1200.0, 1.0),
      (820.0, 1.0),
      (1200.0, 1.35),
      (1200.0, 2.16),
      (820.0, 1.35),
    ]) {
      testWidgets('폭 $width 배율 $scale 에서 넘치지 않는다', (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final state = AppState();
        state.clips.addAll([
          ClipItem(id: '1', spec: _spec(20)),
          ClipItem(
            id: '2',
            spec: _spec(30),
            userRotation: 90,
            edit: const ClipEdit(
              keep: [TimeRange(2, 9)],
              volume: VolumeLevel.mute,
              brightness: BrightnessLevel.brighter,
            ),
          ),
        ]);
        await tester.pumpWidget(MaterialApp(
          home: UiScale(
            factor: scale,
            child: Scaffold(
              body: SingleChildScrollView(child: ClipList(state: state)),
            ),
          ),
        ));
        await tester.pump();
        expect(tester.takeException(), isNull);
        state.dispose();
      });
    }
  });

  group('편집 창 조작', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<(AppState, ClipItem)> open(WidgetTester tester,
        {ClipEdit edit = ClipEdit.none}) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      final clip = ClipItem(id: 'x', spec: _spec(100), edit: edit);
      state.clips.add(clip);
      final grabber = FrameGrabber(
          const FFTools(ffmpegPath: 'nowhere-ffmpeg.exe', ffprobePath: ''));
      await tester.pumpWidget(MaterialApp(
        home: UiScale(
          factor: 1.0,
          child: Scaffold(
            body: ClipEditorDialog(state: state, clip: clip, grabber: grabber),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));
      return (state, clip);
    }

    testWidgets('[구간 시작] → 띠를 눌러 이동 → [구간 끝]: 시작점이 지워지지 않는다', (tester) async {
      // 띠를 눌러 옮겨도 시작점이 지워지면 안 된다.
      final (state, clip) = await open(tester);
      final r = tester.getRect(find.byKey(const ValueKey('clip-editor-strip')));
      await tester.tapAt(Offset(r.left + r.width * 0.20, r.center.dy));
      await tester.pump();
      await tester.tap(find.text('여기를 구간 시작으로'));
      await tester.pump();
      expect(find.text('시작'), findsOneWidget, reason: '시작 깃발');
      expect(find.textContaining('구간 시작: '), findsOneWidget);
      await tester.tapAt(Offset(r.left + r.width * 0.35, r.center.dy));
      await tester.pump();
      expect(find.text('시작'), findsOneWidget, reason: '띠를 눌러도 남아 있어야 한다');
      await tester.tap(find.text('여기를 구간 끝으로'));
      await tester.pump();
      expect(find.textContaining('고른 구간: '), findsOneWidget);
      await tester.tap(find.textContaining('고른 구간 빼기 ('));
      await tester.pump();
      await tester.tap(find.text('적용'));
      await tester.pump();
      expect(clip.edit.keep.length, 2);
      expect(clip.edit.keep[0].end, closeTo(20, 1));
      expect(clip.edit.keep[1].start, closeTo(35, 1));
      await tester.pump(const Duration(seconds: 5));
      state.dispose();
    });

    testWidgets('끝을 시작보다 앞에 찍어도 구간이 된다 · [고르기 취소]', (tester) async {
      final (state, clip) = await open(tester);
      final r = tester.getRect(find.byKey(const ValueKey('clip-editor-strip')));
      await tester.tapAt(Offset(r.left + r.width * 0.50, r.center.dy));
      await tester.pump();
      await tester.tap(find.text('여기를 구간 시작으로'));
      await tester.pump();
      await tester.tapAt(Offset(r.left + r.width * 0.40, r.center.dy));
      await tester.pump();
      await tester.tap(find.text('여기를 구간 끝으로'));
      await tester.pump();
      expect(find.textContaining('고른 구간: '), findsOneWidget);
      await tester.tap(find.text('고르기 취소'));
      await tester.pump();
      expect(find.textContaining('고른 구간: '), findsNothing);
      expect(find.text('시작'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      state.dispose();
    });

    testWidgets('띠를 끌어 고르고 [고른 구간 빼기] → [적용]', (tester) async {
      final (state, clip) = await open(tester);
      final strip = find.byKey(const ValueKey('clip-editor-strip'));
      final r = tester.getRect(strip);
      // 100초 영상의 30%~50% 를 끈다
      final g = await tester.startGesture(
          Offset(r.left + r.width * 0.30, r.center.dy));
      await g.moveBy(const Offset(20, 0));
      await tester.pump();
      await g.moveTo(Offset(r.left + r.width * 0.50, r.center.dy));
      await tester.pump();
      await g.up();
      await tester.pump();
      await tester.tap(find.textContaining('고른 구간 빼기 ('));
      await tester.pump();
      expect(find.text('빠짐'), findsOneWidget);
      await tester.tap(find.text('적용'));
      await tester.pump();
      expect(clip.edit.keep.length, 2);
      expect(clip.edit.keep[0].start, 0);
      expect(clip.edit.keep[0].end, closeTo(30, 1.0));
      expect(clip.edit.keep[1].start, closeTo(50, 1.0));
      expect(clip.edit.keep[1].end, 100);
      expect(tester.takeException(), isNull);
      state.dispose();
    });

    testWidgets('뺀 부분을 누르면 [고른 구간 다시 넣기] 가 나오고 되살아난다', (tester) async {
      final (state, clip) = await open(tester,
          edit: const ClipEdit(keep: [TimeRange(0, 40), TimeRange(60, 100)]));
      final r = tester.getRect(find.byKey(const ValueKey('clip-editor-strip')));
      await tester.tapAt(Offset(r.left + r.width * 0.5, r.center.dy));
      await tester.pump();
      expect(find.text('고른 구간 다시 넣기'), findsOneWidget);
      await tester.tap(find.text('고른 구간 다시 넣기'));
      await tester.pump();
      expect(find.text('빠짐'), findsNothing);
      await tester.tap(find.text('적용'));
      await tester.pump();
      expect(clip.edit.keep, isEmpty, reason: '전부 되살리면 자르지 않은 것');
      await tester.pump(const Duration(seconds: 5)); // 안내 문구 타이머
      state.dispose();
    });

    testWidgets('키보드: 옮기고 I, 옮기고 O, Delete 로 정확한 구간 빼기', (tester) async {
      final (state, clip) = await open(tester);
      // 10초로 이동: → 10번
      for (var i = 0; i < 10; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.pump();
      // 12.5초로: Shift+→ (5초)… 대신 → 2번 + Ctrl+→ 5번(0.1초씩)
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      for (var i = 0; i < 5; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      await tester.tap(find.text('적용'));
      await tester.pump();
      expect(clip.edit.keep.length, 2);
      expect(clip.edit.keep[0].end, closeTo(10.0, 0.01));
      expect(clip.edit.keep[1].start, closeTo(12.5, 0.01));
      state.dispose();
    });

    testWidgets('[여기를 구간 시작으로]·[여기를 구간 끝으로] 버튼', (tester) async {
      final (state, clip) = await open(tester);
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      }
      await tester.tap(find.text('여기를 구간 시작으로'));
      await tester.pump();
      for (var i = 0; i < 4; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      }
      await tester.tap(find.text('여기를 구간 끝으로'));
      await tester.pump();
      expect(find.textContaining('고른 구간 빼기 (0:04)'), findsOneWidget);
      await tester.tap(find.textContaining('고른 구간 빼기 ('));
      await tester.pump();
      await tester.tap(find.text('적용'));
      await tester.pump();
      expect(clip.edit.keep, const [TimeRange(0, 3), TimeRange(7, 100)]);
      state.dispose();
    });

    testWidgets('[처음 상태로]: 손댄 게 없으면 눌러도 묻지 않는다', (tester) async {
      final (state, _) = await open(tester);
      await tester.tap(find.text('처음 상태로'));
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      state.dispose();
    });

    testWidgets('[처음 상태로] → [그만두기] 는 편집을 그대로 둔다', (tester) async {
      final (state, clip) = await open(tester,
          edit: const ClipEdit(volume: VolumeLevel.low));
      await tester.tap(find.text('처음 상태로'));
      await tester.pump();
      expect(find.text('처음 상태로 되돌릴까요?'), findsOneWidget);
      expect(find.text('이 영상에서 자른 것·소리·밝기·회전을 모두 지웁니다.'),
          findsOneWidget);
      await tester.tap(find.text('그만두기'));
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.text('적용'));
      await tester.pump();
      expect(clip.edit.volume, VolumeLevel.low);
      state.dispose();
    });

    testWidgets('[처음 상태로] → 확인하면 자른 것·소리·밝기·회전이 모두 지워진다',
        (tester) async {
      final (state, clip) = await open(tester,
          edit: const ClipEdit(
            keep: [TimeRange(10, 50)],
            volume: VolumeLevel.low,
            brightness: BrightnessLevel.brighter,
          ));
      await tester.tap(find.text('처음 상태로'));
      await tester.pump();
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog), matching: find.text('처음 상태로')));
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('빠짐'), findsNothing);
      await tester.tap(find.text('적용'));
      await tester.pump();
      expect(clip.edit.keep, isEmpty);
      expect(clip.edit.volume, VolumeLevel.normal);
      expect(clip.edit.brightness, BrightnessLevel.normal);
      state.dispose();
    });

    testWidgets('자르기 줄의 [되돌리기] 가 방금 한 것을 취소한다', (tester) async {
      final (state, clip) = await open(tester);
      // 손댄 게 없으면 꺼진 모양이고, 눌러도 아무 일 없다
      await tester.tap(find.text('되돌리기'));
      await tester.pump();
      await tester.tap(find.text('소리 끄기'));
      await tester.pump();
      // 머리줄이 아니라 자르기 줄에 있다
      expect(find.text('되돌리기'), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(EditorCutRow), matching: find.text('되돌리기')),
          findsOneWidget);
      await tester.tap(find.text('되돌리기'));
      await tester.pump();
      await tester.tap(find.text('적용'));
      await tester.pump();
      expect(clip.edit.volume, VolumeLevel.normal);
      state.dispose();
    });
  });
}
