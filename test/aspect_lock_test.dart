// 원본 비율 고정 검증.
//
//   flutter test test/aspect_lock_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videojoin/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final testdata = p.join(Directory.current.path, 'testdata');

  Future<AppState> withClips(List<String> names) async {
    SharedPreferences.setMockInitialValues({});
    final s = AppState();
    await s.init();
    await s.addPaths([for (final n in names) p.join(testdata, n)]);
    return s;
  }

  test('원본이 16:9 면 비율도 16:9 로 읽힌다', () async {
    final s = await withClips(['same_a.mp4']);
    expect(s.plan, isNotNull);
    expect(s.sourceAspectLabel, '16:9');
    expect(s.sourceAspect, closeTo(16 / 9, 0.001));
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('꺼져 있으면 한쪽만 바뀐다', () async {
    final s = await withClips(['same_a.mp4']);
    s.setUseCustomResolution(true);
    expect(s.lockAspect, isFalse, reason: '기본은 꺼짐');

    s.setCustomResolution(width: 1000);
    expect(s.customWidth, 1000);
    expect(s.customHeight, isNot(562), reason: '묶이지 않았으므로 세로는 그대로');
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('켜면 지금 가로에 맞춰 세로가 정리된다', () async {
    final s = await withClips(['same_a.mp4']);
    s.setUseCustomResolution(true);
    s.setCustomResolution(width: 1000, height: 999);

    s.setLockAspect(true);
    // 1000 / (16/9) = 562.5 → 짝수로 562
    expect(s.customHeight, 562);
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('가로를 고치면 세로가 따라오고, 세로를 고치면 가로가 따라온다', () async {
    final s = await withClips(['same_a.mp4']);
    s.setUseCustomResolution(true);
    s.setLockAspect(true);

    s.setCustomResolution(width: 1280);
    expect(s.customHeight, 720);

    s.setCustomResolution(height: 1080);
    expect(s.customWidth, 1920);

    s.setCustomResolution(width: 3840);
    expect(s.customHeight, 2160);
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('따라오는 쪽은 언제나 짝수다', () async {
    final s = await withClips(['same_a.mp4']);
    s.setUseCustomResolution(true);
    s.setLockAspect(true);

    // 홀수가 나올 법한 값들을 훑는다. 따라오는 값은 프로그램이 정하므로
    // "홀수는 짝수로 맞춥니다" 안내가 뜰 일을 만들면 안 된다.
    for (final w in [641, 999, 1001, 1235, 1777]) {
      s.setCustomResolution(width: w);
      expect(s.customHeight.isEven, isTrue,
          reason: '가로 $w → 세로 ${s.customHeight} 가 홀수다');
    }
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('세로 영상이면 세로 기준 비율로 묶인다', () async {
    final s = await withClips(['portrait_real.mp4']);
    s.setUseCustomResolution(true);
    s.setLockAspect(true);

    final a = s.sourceAspect!;
    expect(a, lessThan(1), reason: '세로가 더 긴 영상이어야 한다');

    s.setCustomResolution(width: 720);
    expect(s.customHeight, closeTo(720 / a, 2));
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('끄면 다시 따로 논다', () async {
    final s = await withClips(['same_a.mp4']);
    s.setUseCustomResolution(true);
    s.setLockAspect(true);
    s.setCustomResolution(width: 1280);
    expect(s.customHeight, 720);

    s.setLockAspect(false);
    s.setCustomResolution(width: 640);
    expect(s.customWidth, 640);
    expect(s.customHeight, 720, reason: '풀었으면 세로는 그대로 있어야 한다');
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('가로·세로를 한 번에 주면 손대지 않는다', () async {
    final s = await withClips(['same_a.mp4']);
    s.setUseCustomResolution(true);
    s.setLockAspect(true);

    // 되돌리기(editQueued) 같은 복원 경로에서 정확한 값을 넣는 경우다.
    s.setCustomResolution(width: 1000, height: 300);
    expect(s.customWidth, 1000);
    expect(s.customHeight, 300);
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('영상이 없으면 비율을 알 수 없다', () async {
    SharedPreferences.setMockInitialValues({});
    final s = AppState();
    await s.init();

    expect(s.sourceAspect, isNull);
    expect(s.sourceAspectLabel, isNull);

    // 비율을 몰라도 터지지 않고, 값도 건드리지 않는다.
    s.setLockAspect(true);
    final before = s.customHeight;
    s.setCustomResolution(width: 1000);
    expect(s.customHeight, before);
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
