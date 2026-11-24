// 영상별 편집이 AppState 에서 어떻게 다뤄지는지 검증.
// 실제 testdata 영상(ffprobe)을 쓴다.
//
//   flutter test test/clip_edit_state_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videojoin/engine/fs_util.dart';
import 'package:videojoin/engine/job_queue.dart';
import 'package:videojoin/engine/models.dart';
import 'package:videojoin/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final root = Directory.current.path;
  final testdata = p.join(root, 'testdata');
  final outDir = p.join(root, 'out', 'clip_edit_state_test');

  setUpAll(() {
    final d = Directory(outDir);
    forceDeleteDir(d);
    d.createSync(recursive: true);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<AppState> ready() async {
    final s = AppState();
    await s.init();
    expect(s.fatalError, isNull);
    await s.setAutoNaming(false);
    await s.setUseGpu(false);
    return s;
  }

  const r = TimeRange.new;

  group('setClipEdit', () {
    test('구간 보정: 전체 구간은 비우고, 범위를 넘는 값은 자른다', () async {
      final s = await ready();
      await s.addPaths([p.join(testdata, 'same_a.mp4')]);
      final c = s.clips.single;
      final d = c.spec.durationSec;
      expect(d, greaterThan(2), reason: '테스트 영상 길이를 읽어야 한다');

      // 영상 전체를 남기는 구간 하나 = 자르지 않은 것
      s.setClipEdit(c.id, ClipEdit(keep: [r(0, d)]));
      expect(c.edit.keep, isEmpty);
      expect(s.editedClipCount, 0);

      // 길이를 넘는 끝은 영상 길이 전체와 같으므로 마찬가지
      s.setClipEdit(c.id, ClipEdit(keep: [r(0, d + 50)]));
      expect(c.edit.keep, isEmpty);

      // 0.05초 이내 오차는 전체로 본다
      s.setClipEdit(c.id, ClipEdit(keep: [r(0.03, d - 0.03)]));
      expect(c.edit.keep, isEmpty);

      // 진짜 일부만 남기면 유지
      s.setClipEdit(c.id, ClipEdit(keep: [r(1, 2.5)]));
      expect(c.edit.keep, [r(1, 2.5)]);
      expect(c.edit.isTrimmed, isTrue);
      expect(s.editedClipCount, 1);

      // 겹치는 구간은 합치고 범위 밖은 자른다
      s.setClipEdit(c.id, ClipEdit(keep: [r(-4, 1.5), r(1, 2), r(3, d + 9)]));
      expect(c.edit.keep, [r(0, 2), r(3, d)]);

      // 0.5초 미만 구간만 있으면 비운다
      s.setClipEdit(c.id, ClipEdit(keep: [r(1, 1.3)]));
      expect(c.edit.keep, isEmpty);

      s.dispose();
    });

    test('구간을 비워도 소리·밝기는 유지된다', () async {
      final s = await ready();
      await s.addPaths([p.join(testdata, 'same_a.mp4')]);
      final c = s.clips.single;
      s.setClipEdit(
          c.id,
          ClipEdit(
            keep: [r(0, c.spec.durationSec)],
            volume: VolumeLevel.low,
            brightness: BrightnessLevel.brighter,
          ));
      expect(c.edit.keep, isEmpty);
      expect(c.edit.volume, VolumeLevel.low);
      expect(c.edit.brightness, BrightnessLevel.brighter);
      expect(s.editedClipCount, 1);
      s.dispose();
    });

    test('편집하면 무손실이 막히고 전체 지우기로 되돌아온다', () async {
      final s = await ready();
      await s.addPaths([
        p.join(testdata, 'same_a.mp4'),
        p.join(testdata, 'same_b.mp4'),
      ]);
      expect(s.plan!.losslessPossible, isTrue);
      final before = s.plan!.totalDuration;

      s.setClipEdit(s.clips[0].id, ClipEdit(keep: [r(0.5, 2.5)]));
      expect(s.plan!.losslessPossible, isFalse);
      expect(s.plan!.losslessBlockedReason, contains('손봤기 때문에'));
      expect(s.plan!.totalDuration, closeTo(before - s.clips[0].spec.durationSec + 2, 0.01));

      s.setClipEdit(s.clips[1].id, const ClipEdit(volume: VolumeLevel.mute));
      expect(s.editedClipCount, 2);

      s.clearAllEdits();
      expect(s.editedClipCount, 0);
      expect(s.clips.every((c) => c.edit.isDefault), isTrue);
      expect(s.plan!.losslessPossible, isTrue);
      expect(s.plan!.totalDuration, closeTo(before, 0.01));
      s.dispose();
    });
  });

  group('부드럽게 넘기기', () {
    test('켜면 무손실이 막히고 설정에 반영된다', () async {
      final s = await ready();
      await s.addPaths([
        p.join(testdata, 'same_a.mp4'),
        p.join(testdata, 'same_b.mp4'),
      ]);
      await s.setOutputDir(outDir);
      s.setOutputName('smooth');
      expect(s.plan!.losslessPossible, isTrue);

      await s.setSmoothTransitions(true);
      expect(s.smoothTransitions, isTrue);
      expect(s.plan!.losslessPossible, isFalse);

      s.setLossless(false);
      expect(s.buildSettings()!.smoothTransitions, isTrue);

      await s.setSmoothTransitions(false);
      expect(s.plan!.losslessPossible, isTrue);
      expect(s.buildSettings()!.smoothTransitions, isFalse);
      s.dispose();
    });
  });

  test('대기열에 넣었다가 되돌려도 편집과 부드럽게 설정이 남아 있다', () async {
    final s = await ready();

    // 1번: 오래 걸리는 작업. 이게 도는 동안 2번이 대기 상태로 남는다.
    await s.addPaths([
      p.join(testdata, 'uhd_4k.mp4'),
      p.join(testdata, 'hdr_4k.mp4'),
    ]);
    await s.setOutputDir(outDir);
    s.setOutputName('편집유지_1');
    s.setLossless(false);
    expect(s.enqueueCurrent(), isNull);

    // 2번: 편집한 영상 두 개
    await s.addPaths([
      p.join(testdata, 'same_a.mp4'),
      p.join(testdata, 'same_b.mp4'),
    ]);
    await s.setOutputDir(outDir);
    s.setOutputName('편집유지_2');
    final edit = ClipEdit(
      keep: [r(0.5, 1.5), r(2, 3.5)],
      volume: VolumeLevel.high,
      brightness: BrightnessLevel.brighter,
    );
    s.setClipEdit(s.clips[0].id, edit);
    s.setClipEdit(s.clips[1].id, const ClipEdit(volume: VolumeLevel.mute));
    await s.setSmoothTransitions(true);
    s.setLossless(false);
    expect(s.enqueueCurrent(), isNull);
    expect(s.clips, isEmpty);

    final second = s.queue[1];
    expect(second.status, QueuedStatus.waiting,
        reason: '1번이 아직 돌고 있어야 이 검사가 의미 있다');
    // 대기열에 복사된 목록에 편집이 들어 있다.
    expect(second.clips[0].edit, edit);
    expect(second.clips[1].edit.volume, VolumeLevel.mute);
    expect(second.settings.smoothTransitions, isTrue);

    // 화면 설정을 바꿔도 예약된 작업은 영향이 없다.
    await s.setSmoothTransitions(false);
    expect(second.settings.smoothTransitions, isTrue);

    expect(s.editQueued(second.id), isNull);
    expect(s.clips.length, 2);
    expect(s.clips[0].edit, edit);
    expect(s.clips[1].edit.volume, VolumeLevel.mute);
    expect(s.clips[1].edit.isTrimmed, isFalse);
    expect(s.smoothTransitions, isTrue, reason: '작업의 설정이 되살아나야 한다');
    expect(s.editedClipCount, 2);

    await s.cancelRunning();
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('되돌릴 때 무손실 가능 여부는 화면이 아니라 그 작업의 전환 설정을 따른다',
      () async {
    final s = await ready();
    await s.addPaths([
      p.join(testdata, 'uhd_4k.mp4'),
      p.join(testdata, 'hdr_4k.mp4'),
    ]);
    await s.setOutputDir(outDir);
    s.setOutputName('전환_1');
    s.setLossless(false);
    expect(s.enqueueCurrent(), isNull);

    Future<void> addSame(String name, {required bool smooth}) async {
      await s.addPaths([
        p.join(testdata, 'same_a.mp4'),
        p.join(testdata, 'same_b.mp4'),
      ]);
      await s.setOutputDir(outDir);
      s.setOutputName(name);
      await s.setSmoothTransitions(smooth);
      if (!smooth) s.setLossless(true);
      expect(s.enqueueCurrent(), isNull);
    }

    await addSame('전환_켬', smooth: true);
    await addSame('전환_끔', smooth: false);
    final smoothJob = s.queue[1];
    final plainJob = s.queue[2];
    expect(smoothJob.settings.smoothTransitions, isTrue);
    expect(plainJob.settings.lossless, isTrue);

    // 화면은 끔 → 전환 켠 작업을 되돌리면 무손실이 막혀야 한다.
    await s.setSmoothTransitions(false);
    expect(s.editQueued(smoothJob.id), isNull);
    expect(s.smoothTransitions, isTrue);
    expect(s.plan!.losslessPossible, isFalse);
    expect(s.useLossless, isFalse);
    s.clearAll();

    // 화면은 켬 → 무손실 작업을 되돌리면 무손실이 그대로 가능해야 한다.
    await s.setSmoothTransitions(true);
    expect(s.editQueued(plainJob.id), isNull);
    expect(s.smoothTransitions, isFalse);
    expect(s.plan!.losslessPossible, isTrue);
    expect(s.useLossless, isTrue);

    await s.cancelRunning();
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
