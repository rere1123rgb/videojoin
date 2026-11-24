import 'dart:async';
import 'dart:io';

import 'editor_controller.dart';

/// 진단용. 환경 변수 `VIDEOJOIN_DEBUG_EDIT` 값. 없으면 빈 문자열.
String get editorDebugMode =>
    Platform.environment['VIDEOJOIN_DEBUG_EDIT'] ?? '';

/// 진단 모드가 켜져 있는가. 켜져 있으면 홈 화면이 첫 영상의 손보기 창을
/// 클릭 없이 바로 띄운다.
bool get editorDebugEnabled =>
    Platform.environment['VIDEOJOIN_DEBUG_EDIT'] != null;

/// [mode] 에 따라 화면 상태를 만들어 둔다. 기본값은 환경 변수.
///  - demo: 가운데를 하나 빼고, 다른 구간을 골라 둔 상태
///  - mark: 구간 시작만 찍어 둔 상태
///  - play: 1.5초 뒤 재생 시작, 3.5초에 정지
///
/// 창이 닫힌 뒤에 타이머가 울려도 컨트롤러가 알아서 무시한다(dispose 후 no-op).
void applyEditorDebugScenario(ClipEditorController c, {String? mode}) {
  final m = mode ?? editorDebugMode;
  if (m.contains('demo') && c.canTrim) {
    final dur = c.dur;
    c.pieces.setRange(dur * 0.30, dur * 0.45, false);
    c.selA = dur * 0.62;
    c.selB = dur * 0.78;
    c.pos = dur * 0.55;
  }
  if (m.contains('mark') && c.canTrim) {
    c.selA = c.dur * 0.40;
    c.selB = null;
    c.pos = c.dur * 0.55;
  }
  if (m.contains('play')) {
    Timer(const Duration(milliseconds: 1500), () {
      if (!c.disposed) c.play();
    });
    Timer(const Duration(milliseconds: 3500), () {
      if (!c.disposed) c.stop();
    });
  }
}
