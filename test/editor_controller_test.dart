// 편집 창 컨트롤러(화면 없이). ffmpeg 도 재생기도 띄우지 않는다.
//
//   flutter test test/editor_controller_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videojoin/engine/ffmpeg_tools.dart';
import 'package:videojoin/engine/frame_grabber.dart';
import 'package:videojoin/engine/models.dart';
import 'package:videojoin/state/app_state.dart';
import 'package:videojoin/ui/editor/editor_controller.dart';

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
  late AppState state;
  late ClipItem clip;
  late ClipEditorController c;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    state = AppState();
    clip = ClipItem(id: 'x', spec: _spec(100));
    state.clips.add(clip);
    // 장면 뽑기는 없는 실행 파일을 가리켜서 바로 실패하게 둔다.
    final grabber = FrameGrabber(
      const FFTools(ffmpegPath: r'C:\nowhere\ffmpeg.exe', ffprobePath: ''),
    );
    c = ClipEditorController(
      state: state,
      clip: clip,
      grabber: grabber,
      createPlayer: false,
    );
  });

  tearDown(() {
    c.dispose();
    state.dispose();
  });

  test('처음엔 손댄 것이 없다', () {
    expect(c.isEdited, isFalse);
    expect(c.canUndo, isFalse);
    expect(c.nothingLeft, isFalse);
    expect(c.currentEdit.keep, isEmpty);
    expect(c.player, isNull);
    expect(c.playing, isFalse);
  });

  test('구간 시작 → 구간 끝 → 빼기 → 저장되는 편집', () {
    c.seek(30);
    c.markIn();
    c.seek(50);
    c.markOut();
    expect(c.sel, isNotNull);
    expect(c.sel!.lo, closeTo(30, 0.01));
    expect(c.sel!.hi, closeTo(50, 0.01));

    c.applySelection(false);
    expect(c.sel, isNull, reason: '빼고 나면 고른 구간은 비워진다');
    expect(c.canUndo, isTrue);
    expect(c.currentEdit.keep, const [TimeRange(0, 30), TimeRange(50, 100)]);
    expect(c.hint, contains('구간을 뺐습니다'));
  });

  test('구간 끝은 시작이 없거나 너무 가까우면 안내만 한다', () {
    c.seek(10);
    c.markOut();
    expect(c.sel, isNull);
    expect(c.hint, contains('여기를 구간 시작으로'));

    c.markIn();
    c.seek(10.2);
    c.markOut();
    expect(c.selB, isNull);
    expect(c.hint, contains('0.5초'));
  });

  test('고른 구간이 없을 때 빼기는 안내만 한다', () {
    c.applySelection(false);
    expect(c.hint, contains('구간'));
    expect(c.canUndo, isFalse);
  });

  test('고른 구간 다시 넣기', () {
    c.seek(20);
    c.markIn();
    c.seek(40);
    c.markOut();
    c.applySelection(false);
    // 뺀 구간 일부를 다시 고른다
    c.seek(25);
    c.markIn();
    c.seek(35);
    c.markOut();
    c.applySelection(true);
    expect(c.currentEdit.keep, const [
      TimeRange(0, 20),
      TimeRange(25, 35),
      TimeRange(40, 100),
    ]);
  });

  test('전부 빼는 구간은 거절한다', () {
    c.seek(0);
    c.markIn();
    // seek 은 끝에서 0.05초 모자라게 멈춘다
    c.seek(100);
    c.markOut();
    c.applySelection(false);
    expect(c.pieces.pieces.every((p) => p.keep), isTrue);
    expect(c.canUndo, isFalse);
    expect(c.hint, contains('남는 것이 없습니다'));
  });

  test('여기부터 쓰기 / 여기까지만 쓰기', () {
    c.seek(10);
    c.startHere();
    expect(c.currentEdit.keep, const [TimeRange(10, 100)]);
    c.seek(80);
    c.endHere();
    expect(c.currentEdit.keep, const [TimeRange(10, 80)]);
    expect(c.hint, contains('뒷부분'));
  });

  test('맨 앞·맨 끝에서는 앞/뒤를 자르지 않는다', () {
    c.startHere();
    expect(c.canUndo, isFalse);
    expect(c.hint, contains('맨 앞'));
    c.seek(100);
    c.endHere();
    expect(c.canUndo, isFalse);
    expect(c.hint, contains('맨 끝'));
  });

  test('되돌리기는 자른 것·소리·밝기·회전을 차례로 되돌린다', () {
    c.seek(10);
    c.startHere();
    c.setVolume(VolumeLevel.low);
    c.setBrightness(BrightnessLevel.brighter);
    c.rotateBy(90);
    expect(c.rotation, 90);

    c.undo();
    expect(c.rotation, 0);
    c.undo();
    expect(c.brightness, BrightnessLevel.normal);
    c.undo();
    expect(c.volume, VolumeLevel.normal);
    c.undo();
    expect(c.currentEdit.keep, isEmpty);
    expect(c.canUndo, isFalse);
    c.undo(); // 더 없어도 괜찮다
    expect(c.isEdited, isFalse);
  });

  test('같은 값을 다시 고르면 되돌리기 칸을 쓰지 않는다', () {
    c.setVolume(VolumeLevel.normal);
    c.setBrightness(BrightnessLevel.normal);
    expect(c.canUndo, isFalse);
  });

  test('처음 상태로 + 그것도 되돌릴 수 있다', () {
    c.seek(10);
    c.startHere();
    c.setVolume(VolumeLevel.mute);
    c.rotateBy(270);
    expect(c.isEdited, isTrue);

    c.resetAll();
    expect(c.isEdited, isFalse);
    expect(c.volume, VolumeLevel.normal);
    expect(c.rotation, 0);
    expect(c.currentEdit.keep, isEmpty);

    c.undo();
    expect(c.volume, VolumeLevel.mute);
    expect(c.rotation, 270);
    expect(c.currentEdit.keep, const [TimeRange(10, 100)]);
  });

  test('nothingLeft: 전부 뺀 상태는 적용할 수 없다', () {
    // 모든 조각을 뺀 상태를 직접 만든다
    c.pieces.pieces[0] = c.pieces.pieces[0].withKeep(false);
    expect(c.nothingLeft, isTrue);
    expect(c.apply(), isFalse);
    expect(c.hint, contains('남는 것이 없습니다'));
    expect(clip.edit.keep, isEmpty, reason: '저장하지 않는다');
  });

  test('apply 는 편집과 회전을 AppState 에 쓴다', () {
    c.seek(10);
    c.startHere();
    c.setVolume(VolumeLevel.low);
    c.rotateBy(90);
    expect(c.apply(), isTrue);
    expect(clip.edit.keep, const [TimeRange(10, 100)]);
    expect(clip.edit.volume, VolumeLevel.low);
    expect(clip.userRotation, 90);
  });

  test('시작 위치는 저장된 첫 구간 시작', () {
    final c2 = ClipEditorController(
      state: state,
      clip: ClipItem(
        id: 'y',
        spec: _spec(100),
        edit: const ClipEdit(keep: [TimeRange(20, 60)]),
      ),
      grabber: FrameGrabber(
        const FFTools(ffmpegPath: r'C:\nowhere\ffmpeg.exe', ffprobePath: ''),
      ),
      createPlayer: false,
    );
    expect(c2.pos, 20);
    expect(c2.canTrim, isTrue);
    c2.dispose();
  });

  test('바뀌면 듣는 쪽에 알린다', () {
    var n = 0;
    c.addListener(() => n++);
    c.seek(5);
    expect(n, greaterThan(0));
  });
}
