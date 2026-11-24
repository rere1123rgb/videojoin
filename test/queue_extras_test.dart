// 대기열 보강 기능 검증: 차례 바꾸기, 실패한 작업 수정, 꺼졌다 켜도 남는
// 대기열, 일시정지 중 절전 허용, 접미사 저장 방식.
//
//   flutter test test/queue_extras_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videojoin/engine/fs_util.dart';
import 'package:videojoin/engine/job_queue.dart';
import 'package:videojoin/engine/power.dart';
import 'package:videojoin/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final root = Directory.current.path;
  final testdata = p.join(root, 'testdata');
  final outDir = p.join(root, 'out', 'queue_extras_test');
  final storePath = p.join(outDir, 'pending_queue.json');

  setUpAll(() {
    final d = Directory(outDir);
    forceDeleteDir(d);
    d.createSync(recursive: true);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final f = File(storePath);
    if (f.existsSync()) f.deleteSync();
  });

  Future<bool> waitUntil(bool Function() cond, Duration limit) async {
    final deadline = DateTime.now().add(limit);
    while (DateTime.now().isBefore(deadline)) {
      if (cond()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    return cond();
  }

  Future<AppState> ready() async {
    final s = AppState();
    await s.init();
    await s.setAutoNaming(false);
    // 맨 앞 작업이 오래 걸려야 뒤의 작업들이 대기 상태로 남는다.
    await s.setUseGpu(false);
    return s;
  }

  /// 오래 걸리는 작업 하나를 걸어 대기열 맨 앞을 차지하게 한다.
  Future<void> enqueueSlow(AppState s, String name) async {
    await s.addPaths([
      p.join(testdata, 'uhd_4k.mp4'),
      p.join(testdata, 'hdr_4k.mp4'),
    ]);
    await s.setOutputDir(outDir);
    s.setOutputName(name);
    s.setLossless(false);
    expect(s.enqueueCurrent(), isNull);
  }

  Future<void> enqueueQuick(AppState s, String name, String file) async {
    await s.addPaths([p.join(testdata, file)]);
    await s.setOutputDir(outDir);
    s.setOutputName(name);
    expect(s.enqueueCurrent(), isNull);
  }

  test('기다리는 작업끼리 차례를 바꿀 수 있다', () async {
    final s = await ready();
    await enqueueSlow(s, '차례_앞');
    await enqueueQuick(s, '차례_A', 'same_a.mp4');
    await enqueueQuick(s, '차례_B', 'same_b.mp4');

    final a = s.queue[1];
    final b = s.queue[2];
    expect(a.status, QueuedStatus.waiting);
    expect(b.status, QueuedStatus.waiting);
    expect(s.isFirstWaiting(a.id), isTrue);
    expect(s.isLastWaiting(b.id), isTrue);

    s.moveQueued(b.id, -1);
    expect(s.queue[1].id, b.id, reason: 'B 가 앞으로 와야 한다');
    expect(s.queue[2].id, a.id);
    expect(s.queue[0].status, QueuedStatus.running,
        reason: '만드는 중인 작업은 자리를 지켜야 한다');

    // 더 갈 데가 없으면 아무 일도 없다.
    s.moveQueued(b.id, -1);
    expect(s.queue[1].id, b.id);

    // 만드는 중인 작업은 옮길 수 없다.
    final running = s.queue[0].id;
    s.moveQueued(running, 1);
    expect(s.queue[0].id, running);

    await s.cancelRunning();
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('중지한 작업도 편집기로 되돌려 고칠 수 있다', () async {
    final s = await ready();
    await enqueueSlow(s, '중지후수정');
    final job = s.queue.single;

    await s.cancelRunning();
    final stopped =
        await waitUntil(() => job.isFinished, const Duration(seconds: 60));
    expect(stopped, isTrue);
    expect(job.status, QueuedStatus.skipped);

    expect(s.editQueued(job.id), isNull);
    expect(s.queue, isEmpty);
    expect(s.clips.length, 2);
    expect(s.effectiveOutputName, '중지후수정');
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('꺼졌다 켜도 끝내지 못한 대기열이 남아 있다', () async {
    final s = await ready();
    s.enableQueueStore(storePath);
    expect(s.pendingRestoreCount, 0);

    await enqueueSlow(s, '복구_1');
    await s.addPaths([
      p.join(testdata, 'same_a.mp4'),
      p.join(testdata, 'ntsc_2997.mp4'),
    ]);
    s.rotateClip(s.clips.first.id, 180);
    await s.setOutputDir(outDir);
    s.setOutputName('복구_2 한글');
    s.setLossless(false);
    expect(s.enqueueCurrent(), isNull);

    final want = s.queue[1].settings;
    expect(File(storePath).existsSync(), isTrue);

    // 창을 닫는다. 닫으면서 생기는 "취소됨"이 파일에 적히면 안 된다.
    await s.prepareForExit();
    s.dispose();
    await Future<void>.delayed(const Duration(seconds: 2));

    final again = AppState();
    await again.init();
    again.enableQueueStore(storePath);
    expect(again.pendingRestoreCount, 2,
        reason: '만들던 작업과 기다리던 작업이 모두 남아 있어야 한다');
    expect(again.queue, isEmpty, reason: '물어보기 전에는 시작하지 않는다');

    final lost = await again.answerRestore(true);
    expect(lost, 0);
    expect(again.queue.length, 2);

    final got = again.queue[1];
    expect(got.settings.outputName, '복구_2 한글');
    expect(got.settings.outputDir, want.outputDir);
    expect(got.settings.width, want.width);
    expect(got.settings.height, want.height);
    expect(got.settings.frameRate, want.frameRate,
        reason: '29.97 같은 분수 프레임레이트가 그대로 돌아와야 한다');
    expect(got.settings.videoBitrate, want.videoBitrate);
    expect(got.settings.lossless, want.lossless);
    expect(got.clips.length, 2);
    expect(got.clips.first.userRotation, 180);

    await again.prepareForExit();
    again.dispose();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('버리기를 고르면 남은 대기열이 지워진다', () async {
    final s = await ready();
    s.enableQueueStore(storePath);
    await enqueueSlow(s, '버리기_1');
    await s.prepareForExit();
    s.dispose();
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(File(storePath).existsSync(), isTrue);

    final again = AppState();
    await again.init();
    again.enableQueueStore(storePath);
    expect(again.pendingRestoreCount, 1);

    expect(await again.answerRestore(false), 0);
    expect(again.queue, isEmpty);
    expect(again.pendingRestoreCount, 0);
    expect(File(storePath).existsSync(), isFalse);
    again.dispose();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('영상이 없어진 작업은 되살리지 않고 몇 개인지 알려 준다', () async {
    // 영상을 복사해 걸어 둔 뒤, 꺼져 있는 사이에 지워진 상황을 만든다.
    final tmp = p.join(outDir, '사라질 영상.mp4');
    File(p.join(testdata, 'same_a.mp4')).copySync(tmp);

    final s = await ready();
    s.enableQueueStore(storePath);
    await enqueueSlow(s, '없어짐_앞');
    await s.addPaths([tmp]);
    await s.setOutputDir(outDir);
    s.setOutputName('없어짐_2');
    expect(s.enqueueCurrent(), isNull);
    await s.prepareForExit();
    s.dispose();
    await Future<void>.delayed(const Duration(seconds: 1));

    File(tmp).deleteSync();

    final again = AppState();
    await again.init();
    again.enableQueueStore(storePath);
    expect(again.pendingRestoreCount, 2);
    expect(await again.answerRestore(true), 1);
    expect(again.queue.length, 1);
    expect(again.queue.single.settings.outputName, '없어짐_앞');

    await again.prepareForExit();
    again.dispose();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('일시정지한 동안에는 절전을 막지 않는다', () async {
    final s = await ready();
    await s.setPreventSleep(true);
    expect(KeepAwake.held, isFalse, reason: '만들기 전에는 붙잡지 않는다');

    await enqueueSlow(s, '절전_일시정지');
    expect(KeepAwake.held, isTrue);

    s.pauseRunning();
    expect(KeepAwake.held, isFalse, reason: '멈춰 둔 동안은 잠들 수 있어야 한다');

    s.resumeRunning();
    expect(KeepAwake.held, isTrue, reason: '다시 만들기 시작하면 다시 막는다');

    await s.cancelRunning();
    await waitUntil(() => !s.queueActive, const Duration(seconds: 60));
    expect(KeepAwake.held, isFalse);
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('접미사는 화면에 바로 반영되고 저장은 잠시 뒤에 된다', () async {
    final s = AppState();
    await s.init();
    var notified = 0;
    s.addListener(() => notified++);

    // 기다리지 않고 연달아 친다.
    s.setNameSuffix('_모');
    s.setNameSuffix('_모음');
    expect(s.nameSuffix, '_모음');
    expect(notified, 2, reason: '저장을 기다리지 않고 곧바로 알려야 한다');

    await Future<void>.delayed(const Duration(milliseconds: 900));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('nameSuffix'), '_모음',
        reason: '마지막으로 친 값이 저장돼야 한다');
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
