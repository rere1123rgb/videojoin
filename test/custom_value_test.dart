// 직접 입력한 수치가 실제 인코딩 설정까지 제대로 전달되는지 확인한다.
//
//   flutter test test/custom_value_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videojoin/engine/fs_util.dart';
import 'package:videojoin/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final testdata = p.join(Directory.current.path, 'testdata');

  // AppState.init() 은 ffmpeg 을 띄우므로 testWidgets 가 아니라 test() 를 쓴다.
  Future<AppState> ready() async {
    SharedPreferences.setMockInitialValues({});
    final s = AppState();
    await s.init();
    await s.addPaths([
      p.join(testdata, 'same_a.mp4'),
      p.join(testdata, 'uhd_4k.mp4'),
    ]);
    s.setLossless(false);
    return s;
  }

  test('아무것도 켜지 않으면 프리셋 값이 그대로 쓰인다', () async {
    final s = await ready();
    expect(s.useCustomResolution, isFalse);
    expect(s.effectiveWidth, s.resolution!.width);
    expect(s.effectiveHeight, s.resolution!.height);
    expect(s.effectiveBitrate, s.selectedBitrate!.bps);
    expect(s.customValueIssue, isNull);
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('직접 넣은 해상도·비트레이트·프레임레이트가 설정에 반영된다', () async {
    final s = await ready();

    s.setUseCustomResolution(true);
    s.setCustomResolution(width: 1440, height: 1080);
    s.setUseCustomBitrate(true);
    s.setCustomBitrate(12.5);
    s.setUseCustomFps(true);
    s.setCustomFps(24);

    expect(s.customValueIssue, isNull);

    final out = s.buildSettings()!;
    expect(out.width, 1440);
    expect(out.height, 1080);
    expect(out.videoBitrate, 12500000);
    expect(out.frameRate.toDouble(), closeTo(24.0, 0.001));
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('홀수 크기는 짝수로 맞춘다 (H.264 요구사항)', () async {
    final s = await ready();
    s.setUseCustomResolution(true);
    s.setCustomResolution(width: 1281, height: 721);

    expect(s.effectiveWidth, 1282);
    expect(s.effectiveHeight, 722);
    expect(s.buildSettings()!.width.isEven, isTrue);
    expect(s.buildSettings()!.height.isEven, isTrue);
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('29.97 을 넣으면 정확한 분수(30000/1001)로 맞춘다', () async {
    final s = await ready();
    s.setUseCustomFps(true);
    s.setCustomFps(29.97);

    final f = s.effectiveFps;
    expect(f.num, 30000);
    expect(f.den, 1001);
    // ffmpeg 에 넘어가는 인자도 분수 형태여야 한다.
    expect(s.buildSettings()!.frameRate.toFFmpegArg(), '30000/1001');
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('범위를 벗어난 값은 실행을 막는다', () async {
    final s = await ready();

    s.setUseCustomResolution(true);
    s.setCustomResolution(width: 40, height: 40);
    expect(s.customValueIssue, isNotNull);
    expect(s.blockingIssue, isNotNull);

    s.setCustomResolution(width: 1920, height: 1080);
    expect(s.customValueIssue, isNull);

    s.setUseCustomBitrate(true);
    s.setCustomBitrate(0.05);
    expect(s.customValueIssue, isNotNull);

    s.setCustomBitrate(8);
    s.setUseCustomFps(true);
    s.setCustomFps(999);
    expect(s.customValueIssue, isNotNull);
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('껐다 켜도 프리셋 동작으로 되돌아온다', () async {
    final s = await ready();
    final presetW = s.resolution!.width;

    s.setUseCustomResolution(true);
    s.setCustomResolution(width: 640, height: 480);
    expect(s.effectiveWidth, 640);

    s.setUseCustomResolution(false);
    expect(s.effectiveWidth, presetW);
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('무손실 모드에서는 직접 입력 오류가 실행을 막지 않는다', () async {
    final s = await ready();
    s.setUseCustomBitrate(true);
    s.setCustomBitrate(0.01); // 범위 밖
    expect(s.customValueIssue, isNotNull);

    // 무손실은 재인코딩을 하지 않으므로 이 값이 쓰이지 않는다.
    s.setLossless(true);
    expect(s.blockingIssue, isNull);
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('직접 넣은 값으로 실제 인코딩이 된다', () async {
    final s = await ready();
    final outDir = p.join(Directory.current.path, 'out', 'custom_test');
    final d = Directory(outDir);
    forceDeleteDir(d);
    d.createSync(recursive: true);

    s.setUseCustomResolution(true);
    s.setCustomResolution(width: 854, height: 480);
    s.setUseCustomBitrate(true);
    s.setCustomBitrate(2.0);
    await s.setOutputDir(outDir);
    s.setOutputName('커스텀_결과');

    expect(s.enqueueCurrent(), isNull);

    final deadline = DateTime.now().add(const Duration(minutes: 3));
    while (DateTime.now().isBefore(deadline)) {
      if (s.queue.every((j) => j.isFinished)) break;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    final job = s.queue.single;
    expect(job.status.name, 'done', reason: job.errorMessage ?? '');
    final f = File(job.resultPath!);
    expect(f.existsSync(), isTrue);
    expect(f.lengthSync(), greaterThan(10000));
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 4)));
}
