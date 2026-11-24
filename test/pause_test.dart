// 일시정지 검증.
//
// 죽였다 다시 켜는 방식이 아니라 프로세스를 그 자리에서 얼린다.
// 얼어 있는 동안 진행률이 멈추고, 녹이면 이어서 진행되는지 본다.
//
//   flutter test test/pause_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videojoin/engine/fs_util.dart';
import 'package:videojoin/engine/job_queue.dart';
import 'package:videojoin/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final root = Directory.current.path;
  final testdata = p.join(root, 'testdata');
  final outDir = p.join(root, 'out', 'pause_test');

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    final d = Directory(outDir);
    forceDeleteDir(d);
    d.createSync(recursive: true);
  });

  /// 조건이 참이 될 때까지 기다린다. 실제 프로세스를 상대하므로
  /// 고정된 시간을 자면 느린 PC 에서 흔들린다.
  Future<bool> waitUntil(bool Function() cond, Duration limit) async {
    final deadline = DateTime.now().add(limit);
    while (DateTime.now().isBefore(deadline)) {
      if (cond()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    return cond();
  }

  test('일시정지하면 진행이 멈추고, 계속하면 이어서 끝난다', () async {
    final state = AppState();
    await state.init();
    expect(state.fatalError, isNull);

    await state.setAutoNaming(false);
    // 금방 끝나 버리면 멈출 틈이 없다. 4K 를 CPU 로 다시 만들게 한다.
    await state.setUseGpu(false);

    await state.addPaths([
      p.join(testdata, 'uhd_4k.mp4'),
      p.join(testdata, 'hdr_4k.mp4'),
    ]);
    await state.setOutputDir(outDir);
    state.setOutputName('일시정지테스트');
    state.setLossless(false);
    expect(state.enqueueCurrent(), isNull);

    final job = state.queue.single;
    expect(job.status, QueuedStatus.running);
    expect(state.isPaused, isFalse);

    // 진행률이 실제로 오르기 시작할 때까지 기다린다.
    final moved = await waitUntil(
        () => job.progress > 0.01, const Duration(seconds: 60));
    expect(moved, isTrue, reason: '인코딩이 시작되지 않았다');

    state.pauseRunning();
    expect(state.isPaused, isTrue);

    // 얼린 직후의 값이 아니라, 잔여 이벤트가 가라앉은 뒤의 값을 기준으로 본다.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    final frozenAt = job.progress;

    await Future<void>.delayed(const Duration(seconds: 3));
    expect(job.progress, frozenAt,
        reason: '멈춰 있는 동안 진행률이 움직였다 (프로세스가 안 얼었다)');
    expect(job.status, QueuedStatus.running,
        reason: '일시정지는 진행 중인 상태다 — 끝난 것으로 보면 안 된다');
    expect(state.hasUnfinishedWork, isTrue,
        reason: '멈춰 있어도 닫을 때 물어봐야 한다');

    state.resumeRunning();
    expect(state.isPaused, isFalse);

    final wentOn = await waitUntil(
        () => job.progress > frozenAt, const Duration(seconds: 60));
    expect(wentOn, isTrue, reason: '계속하기를 눌러도 진행되지 않았다');

    // 얼렸다 녹인 것이 결과를 망치면 안 된다.
    final finished =
        await waitUntil(() => job.isFinished, const Duration(minutes: 8));
    expect(finished, isTrue, reason: '제한 시간 안에 끝나지 않았다');
    expect(job.status, QueuedStatus.done, reason: '실패: ${job.errorMessage}');

    final f = File(job.resultPath!);
    expect(f.existsSync(), isTrue);
    expect(f.lengthSync(), greaterThan(10000));

    state.dispose();
  }, timeout: const Timeout(Duration(minutes: 12)));

  test('작업이 없으면 일시정지는 아무 일도 하지 않는다', () async {
    final state = AppState();
    await state.init();

    expect(state.isPaused, isFalse);
    expect(state.hasUnfinishedWork, isFalse, reason: '대기열이 비면 그냥 닫힌다');

    expect(state.pauseRunning, returnsNormally);
    expect(state.resumeRunning, returnsNormally);
    expect(state.isPaused, isFalse);

    state.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('멈춘 채로 중지하면 정리되고 대기열이 풀린다', () async {
    final state = AppState();
    await state.init();
    await state.setAutoNaming(false);
    await state.setUseGpu(false);

    await state.addPaths([
      p.join(testdata, 'uhd_4k.mp4'),
      p.join(testdata, 'hdr_4k.mp4'),
    ]);
    await state.setOutputDir(outDir);
    state.setOutputName('멈춘채중지');
    state.setLossless(false);
    expect(state.enqueueCurrent(), isNull);

    final job = state.queue.single;
    await waitUntil(() => job.progress > 0.01, const Duration(seconds: 60));

    state.pauseRunning();
    expect(state.isPaused, isTrue);

    // 얼어 있는 프로세스도 확실히 정리돼야 한다.
    // 녹이지 않고 죽이면 뒷정리가 진행되지 않아 영영 안 끝난다.
    await state.cancelRunning();
    final ended =
        await waitUntil(() => job.isFinished, const Duration(seconds: 60));
    expect(ended, isTrue, reason: '멈춘 작업을 중지했는데 끝나지 않았다');
    expect(state.isPaused, isFalse);

    state.dispose();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
