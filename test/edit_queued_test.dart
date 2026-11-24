// 대기 중인 작업을 편집기로 되돌리는 기능 검증.
//
// 이미 만들고 있는 작업은 손댈 수 없고, 순서를 기다리는 작업만 고칠 수 있다.
//
//   flutter test test/edit_queued_test.dart

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
  final outDir = p.join(root, 'out', 'edit_queued_test');

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    final d = Directory(outDir);
    forceDeleteDir(d);
    d.createSync(recursive: true);
  });

  test('기다리는 작업은 되돌려 고칠 수 있고, 돌고 있는 작업은 못 고친다', () async {
    final state = AppState();
    await state.init();
    expect(state.fatalError, isNull);

    await state.setAutoNaming(false);
    // 1번 작업이 금방 끝나 버리면 2번이 대기 상태로 남지 않는다.
    // 4K 를 CPU 로 다시 만들게 해서 충분히 오래 걸리게 한다.
    await state.setUseGpu(false);

    // 1번: 오래 걸리는 작업. 이게 도는 동안 2번이 줄을 선다
    await state.addPaths([
      p.join(testdata, 'uhd_4k.mp4'),
      p.join(testdata, 'hdr_4k.mp4'),
    ]);
    await state.setOutputDir(outDir);
    state.setOutputName('편집_1');
    state.setLossless(false);
    expect(state.enqueueCurrent(), isNull);

    await state.addPaths([
      p.join(testdata, 'same_a.mp4'),
      p.join(testdata, 'same_b.mp4'),
      p.join(testdata, 'same_c.mp4'),
    ]);
    // 뒤집힌 영상을 바로잡아 둔다. 되돌린 뒤에도 남아 있어야 한다.
    state.rotateClip(state.clips.first.id, 180);
    await state.setOutputDir(outDir);
    state.setOutputName('편집_2');
    expect(state.enqueueCurrent(), isNull);
    expect(state.clips, isEmpty, reason: '넣은 뒤 목록은 비워진다');

    final running = state.queue[0];
    final second = state.queue[1];
    expect(second.status, QueuedStatus.waiting,
        reason: '1번이 아직 돌고 있어야 이 검사가 의미 있다');

    final wantedFps = second.settings.frameRate;
    final wantedBitrate = second.settings.videoBitrate;
    final wantedWidth = second.settings.width;

    // 돌고 있는 작업은 고칠 수 없다 — 멈추라고 알려 줘야 한다.
    expect(state.editQueued(running.id), isNotNull);

    // 없는 작업도 막는다.
    expect(state.editQueued('없는id'), isNotNull);

    expect(state.editQueued(second.id), isNull);
    expect(state.queue.any((j) => j.id == second.id), isFalse,
        reason: '되돌린 작업은 대기열에서 빠져야 한다 '
            '(남겨두면 고치는 사이에 옛 설정으로 만들어진다)');

    // 목록·순서·회전이 그대로 살아난다.
    expect(state.clips.length, 3);
    expect(state.clips.map((c) => c.spec.fileName).toList(),
        ['same_a.mp4', 'same_b.mp4', 'same_c.mp4']);
    expect(state.clips.first.userRotation, 180, reason: '회전이 사라졌다');

    expect(state.effectiveFps, wantedFps);
    expect(state.effectiveBitrate, wantedBitrate);
    expect(state.effectiveWidth, wantedWidth);

    expect(state.effectiveOutputName, '편집_2');
    expect(state.effectiveOutputDir, outDir);

    state.setOutputName('편집_2_고침');
    expect(state.enqueueCurrent(), isNull);
    expect(state.queue.length, 2);
    expect(state.queue[1].settings.outputName, '편집_2_고침');

    await state.cancelRunning();
    state.dispose();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('프리셋에 없는 수치는 직접 입력으로 되살아난다', () async {
    final state = AppState();
    await state.init();
    await state.setAutoNaming(false);
    await state.setUseGpu(false);

    // 1번: 자리를 차지해 둘 긴 작업
    await state.addPaths([
      p.join(testdata, 'uhd_4k.mp4'),
      p.join(testdata, 'hdr_4k.mp4'),
    ]);
    await state.setOutputDir(outDir);
    state.setOutputName('직접_1');
    state.setLossless(false);
    expect(state.enqueueCurrent(), isNull);

    // 2번: 프리셋에 없는 해상도·비트레이트로 만든다.
    await state.addPaths([p.join(testdata, 'same_a.mp4')]);
    await state.setOutputDir(outDir);
    state.setOutputName('직접_2');
    state.setLossless(false);
    state.setUseCustomResolution(true);
    state.setCustomResolution(width: 1234, height: 694);
    state.setUseCustomBitrate(true);
    state.setCustomBitrate(6.3);
    expect(state.enqueueCurrent(), isNull);

    final second = state.queue[1];
    expect(second.status, QueuedStatus.waiting);
    expect(state.editQueued(second.id), isNull);

    // 짝수 보정(1234×694)까지 포함해 같은 값이 나와야 한다.
    expect(state.useCustomResolution, isTrue);
    expect(state.effectiveWidth, second.settings.width);
    expect(state.effectiveHeight, second.settings.height);
    expect(state.useCustomBitrate, isTrue);
    expect(state.effectiveBitrate, second.settings.videoBitrate);

    // 화면에 안 보이는 값이 결과를 좌우하면 안 되므로 접힌 칸을 펴 준다.
    expect(state.advancedOpen, isTrue);

    await state.cancelRunning();
    state.dispose();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
