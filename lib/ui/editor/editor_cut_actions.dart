import '../../engine/models.dart';
import '../format.dart';
import 'editor_controller.dart';

/// 구간 고르기와 자르기 동작. `editor_controller.dart` 가 이 파일을 다시 내보낸다.
extension ClipEditorCutActions on ClipEditorController {
  void clearSelection() {
    selA = selB = null;
    refresh();
  }

  void beginDrag(double t) {
    stop();
    dragStart = t;
    selA = t;
    selB = t;
    pos = t;
    refresh();
    requestFrame();
  }

  void updateDrag(double t) {
    selB = t;
    pos = t.clamp(0.0, dur <= 0.05 ? 0.0 : dur - 0.05);
    refresh();
    requestFrame();
  }

  void endDrag() {
    dragStart = null;
    if (sel == null) selA = selB = null;
    refresh();
  }

  /// 띠를 한 번 눌렀을 때. 뺀 구간을 누르면 그 구간이 통째로 골라져서
  /// 바로 [고른 구간 다시 넣기] 를 누를 수 있다. 그 밖에는 그 자리로 이동한다.
  void tapStrip(double t) {
    stop();
    final p = pieces.pieces[pieces.indexAt(t)];
    // 남는 곳을 누르면 자리만 옮기고 고르던 구간은 지우지 않는다.
    // [여기를 구간 시작으로] 뒤에 띠를 눌러 끝 자리로 가는 순서가 자연스럽다.
    if (!p.keep) {
      selA = p.start;
      selB = p.end;
    }
    pos = t.clamp(0.0, dur <= 0.05 ? 0.0 : dur - 0.05);
    refresh();
    requestFrame(immediate: true);
  }

  /// 지금 자리를 고를 구간의 시작으로. 긴 영상에서는 끌기보다 정확하다
  /// (0.1초 단위로 맞춘 뒤 누름). I 키.
  void markIn() {
    stop();
    selA = pos;
    final b = selB;
    if (b != null && b <= pos) selB = null;
    refresh();
    showHint(
      '구간 시작 ${formatClock(pos, precise: true)}. '
      '끝낼 곳으로 옮긴 뒤 [여기를 구간 끝으로].',
    );
  }

  /// 지금 자리를 고를 구간의 끝으로(O 키).
  void markOut() {
    stop();
    final a = selA;
    if (a == null) {
      showHint('먼저 [여기를 구간 시작으로]를 누르세요.');
      return;
    }
    // 끝을 시작보다 앞에 찍어도 받아 준다(둘을 바꿔 쓴다).
    if ((pos - a).abs() < kMinRangeSec) {
      showHint('구간 끝은 시작에서 0.5초 이상 떨어져야 합니다. 조금 더 옮긴 뒤 누르세요.');
      return;
    }
    if (pos < a) {
      selB = a;
      selA = pos;
    } else {
      selB = pos;
    }
    refresh();
    final s = sel;
    if (s != null) {
      showHint('${formatClock(s.lo, precise: true)} ~ ${formatClock(s.hi, precise: true)} 을 '
          '골랐습니다. 빼려면 [고른 구간 빼기].');
    }
  }

  /// 고른 구간을 빼거나([keep] false) 다시 넣는다.
  void applySelection(bool keep) {
    final s = sel;
    if (s == null) {
      showHint('먼저 아래 장면 띠를 마우스로 끌어서 구간을 고르세요.');
      return;
    }
    stop();
    final next = pieces.copy()..setRange(s.lo, s.hi, keep);
    if (!next.pieces.any((p) => p.keep)) {
      showHint('전부 빼면 남는 것이 없습니다.');
      return;
    }
    remember();
    pieces = next;
    selA = selB = null;
    refresh();
    if (!keep) {
      showHint(
        '${formatClock(s.lo)} ~ ${formatClock(s.hi)} 구간을 뺐습니다. '
        '잘못 뺐으면 [되돌리기].',
      );
    }
  }

  void startHere() {
    if (pos < kMinRangeSec) {
      showHint('맨 앞입니다. 쓰기 시작할 곳으로 옮긴 뒤 누르세요.');
      return;
    }
    stop();
    remember();
    pieces.startHere(pos);
    pieces.mergeSame();
    selA = selB = null;
    refresh();
    showHint('${formatClock(pos)} 앞부분을 뺐습니다.');
  }

  void endHere() {
    if (dur - pos < kMinRangeSec) {
      showHint('맨 끝입니다. 끝낼 곳으로 옮긴 뒤 누르세요.');
      return;
    }
    stop();
    remember();
    pieces.endHere(pos);
    pieces.mergeSame();
    selA = selB = null;
    refresh();
    showHint('${formatClock(pos)} 뒷부분을 뺐습니다.');
  }
}
