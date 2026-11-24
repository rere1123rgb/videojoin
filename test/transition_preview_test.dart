import 'package:flutter_test/flutter_test.dart';
import 'package:videojoin/ui/transition_preview.dart';

void main() {
  const last = TransitionPreview.frames - 1;
  const before = TransitionPreview.holdBeforeMs;

  test('맛보기: 앞 정지 → 고른 길이만큼 전환 → 뒤 정지', () {
    for (final sec in [0.6, 1.0, 2.0]) {
      final ms = (sec * 1000).round();
      expect(TransitionPreview.frameAt(0, sec), 0);
      expect(TransitionPreview.frameAt(before, sec), 0);
      expect(TransitionPreview.frameAt(before + ms ~/ 2, sec),
          closeTo(last / 2, 1));
      expect(TransitionPreview.frameAt(before + ms, sec), last);
      expect(TransitionPreview.frameAt(before + ms + 500, sec), last);
    }
  });

  test('맛보기: 길이가 길수록 같은 시각에 덜 진행된다', () {
    const at = before + 300;
    expect(TransitionPreview.frameAt(at, 0.6),
        greaterThan(TransitionPreview.frameAt(at, 1.0)));
    expect(TransitionPreview.frameAt(at, 1.0),
        greaterThan(TransitionPreview.frameAt(at, 2.0)));
  });

  test('맛보기: 한 바퀴 돌면 처음으로', () {
    const sec = 1.0;
    const loop = before + 1000 + TransitionPreview.holdAfterMs;
    expect(TransitionPreview.frameAt(loop, sec), 0);
    expect(TransitionPreview.frameAt(loop + before + 500, sec),
        TransitionPreview.frameAt(before + 500, sec));
  });
}
