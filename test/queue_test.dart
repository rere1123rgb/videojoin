// 대기열 동작 검증.
//
// UI 대신 실제 ffmpeg 을 돌려 대기열 로직을 검증한다.
//
//   flutter test test/queue_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videojoin/engine/fs_util.dart';
import 'package:videojoin/engine/ffmpeg_tools.dart';
import 'package:videojoin/engine/job_queue.dart';
import 'package:videojoin/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final root = Directory.current.path;
  final testdata = p.join(root, 'testdata');
  final outDir = p.join(root, 'out', 'queue_test');

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    final d = Directory(outDir);
    forceDeleteDir(d);
    d.createSync(recursive: true);
  });

  test('ffmpeg 을 찾을 수 있다', () {
    expect(FFTools.locate(), isNotNull,
        reason: 'tools/ffmpeg.exe 가 있어야 한다');
  });

  test('대기열에 연달아 넣으면 순서대로 하나씩 처리된다', () async {
    final state = AppState();
    await state.init();
    expect(state.fatalError, isNull);

    // 이 테스트는 이름을 직접 지정해 순서를 확인하므로 자동 이름을 끈다.
    await state.setAutoNaming(false);

    await state.addPaths([
      p.join(testdata, 'same_a.mp4'),
      p.join(testdata, 'same_b.mp4'),
    ]);
    expect(state.clips.length, 2);

    await state.setOutputDir(outDir);
    state.setOutputName('큐테스트_1');

    expect(state.enqueueCurrent(), isNull, reason: '1번 작업이 들어가야 한다');

    // 대기열에 넣으면 목록이 비워져서 곧바로 다음 묶음을 준비할 수 있다.
    expect(state.clips, isEmpty, reason: '넣은 뒤 목록이 비워져야 한다');
    expect(state.queue.length, 1);

    // 2번 작업: 1번이 끝나기를 기다리지 않고 바로 추가한다
    await state.addPaths([
      p.join(testdata, 'same_c.mp4'),
      p.join(testdata, 'ntsc_2997.mp4'),
    ]);
    await state.setOutputDir(outDir);
    state.setOutputName('큐테스트_2');

    expect(state.enqueueCurrent(), isNull, reason: '2번 작업이 들어가야 한다');
    expect(state.queue.length, 2);

    // 한 번에 하나만 돌아야 한다.
    final running =
        state.queue.where((j) => j.status == QueuedStatus.running).length;
    expect(running, lessThanOrEqualTo(1),
        reason: '동시에 두 개를 처리하면 안 된다');

    final deadline = DateTime.now().add(const Duration(minutes: 5));
    while (DateTime.now().isBefore(deadline)) {
      if (state.queue.every((j) => j.isFinished)) break;
      // 처리 중에도 동시 실행은 언제나 1개 이하여야 한다.
      final n =
          state.queue.where((j) => j.status == QueuedStatus.running).length;
      expect(n, lessThanOrEqualTo(1), reason: '순차 처리가 깨졌다');
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    expect(state.queue.every((j) => j.isFinished), isTrue,
        reason: '제한 시간 안에 모두 끝나야 한다');

    for (final j in state.queue) {
      expect(j.status, QueuedStatus.done,
          reason: '${j.title} 실패: ${j.errorMessage}');
      expect(j.resultPath, isNotNull);
      final f = File(j.resultPath!);
      expect(f.existsSync(), isTrue, reason: '${j.title} 파일이 없다');
      expect(f.lengthSync(), greaterThan(10000));
    }

    // 순서대로 처리됐는지 — 넣은 순서가 유지되어야 한다.
    expect(p.basename(state.queue[0].resultPath!), '큐테스트_1.mp4');
    expect(p.basename(state.queue[1].resultPath!), '큐테스트_2.mp4');

    state.dispose();
  }, timeout: const Timeout(Duration(minutes: 6)));

  test('같은 출력 이름을 두 번 넣으면 막는다', () async {
    final state = AppState();
    await state.init();
    await state.setAutoNaming(false); // 수동 이름일 때의 동작을 본다

    await state.addPaths([p.join(testdata, 'same_a.mp4')]);
    await state.setOutputDir(outDir);
    state.setOutputName('중복테스트');
    expect(state.enqueueCurrent(), isNull);

    await state.addPaths([p.join(testdata, 'same_b.mp4')]);
    await state.setOutputDir(outDir);
    state.setOutputName('중복테스트');
    final err = state.enqueueCurrent();
    expect(err, isNotNull, reason: '같은 이름은 거절해야 한다');

    await state.cancelRunning();
    state.dispose();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
