// 영상별 편집(자르기·소리·밝기·부드럽게 넘기기) 엔진 검증. ffmpeg 없이 도는 순수 테스트.
//
//   flutter test test/clip_edit_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:videojoin/engine/encoder_support.dart';
import 'package:videojoin/engine/executor.dart';
import 'package:videojoin/engine/ffmpeg_tools.dart';
import 'package:videojoin/engine/fs_util.dart';
import 'package:videojoin/engine/job_log.dart';
import 'package:videojoin/engine/job_queue.dart';
import 'package:videojoin/engine/joblist_file.dart';
import 'package:videojoin/engine/models.dart';
import 'package:videojoin/engine/planner.dart';
import 'package:videojoin/engine/queue_store.dart';
import 'package:videojoin/engine/rational.dart';

VideoSpec spec({
  String path = r'C:\v\a.mp4',
  double duration = 10,
  bool hasAudio = true,
}) =>
    VideoSpec(
      path: path,
      fileSize: 1000000,
      fileModified: DateTime(2024, 1, 1),
      fileCreated: DateTime(2024, 1, 1),
      rawWidth: 1920,
      rawHeight: 1080,
      durationSec: duration,
      videoCodec: 'h264',
      pixFmt: 'yuv420p',
      hasAudio: hasAudio,
      audioCodec: hasAudio ? 'aac' : null,
      audioSampleRate: hasAudio ? 48000 : null,
      audioChannels: hasAudio ? 2 : null,
    );

ClipItem clip(
  String id, {
  double duration = 10,
  bool hasAudio = true,
  ClipEdit edit = ClipEdit.none,
  int rotation = 0,
}) =>
    ClipItem(
      id: id,
      spec: spec(path: 'C:\\v\\$id.mp4', duration: duration, hasAudio: hasAudio),
      edit: edit,
      userRotation: rotation,
    );

OutputSettings settings({bool lossless = false, bool smooth = false}) =>
    OutputSettings(
      lossless: lossless,
      width: 1920,
      height: 1080,
      frameRate: const Rational(30, 1),
      videoBitrate: 8000000,
      smoothTransitions: smooth,
      outputDir: r'C:\out',
      outputName: 'x',
    );

Executor executor() => Executor(
      tools: const FFTools(ffmpegPath: 'ffmpeg', ffprobePath: 'ffprobe'),
      encoders: const EncoderSupport(),
      log: JobLog(File(p.join(Directory.systemTemp.path, 'unused_vj.log'))),
    );

const r = TimeRange.new;

void main() {
  group('normalizeRanges', () {
    test('정렬한다', () {
      final out = normalizeRanges([r(5, 8), r(0, 2)]);
      expect(out, [r(0, 2), r(5, 8)]);
    });

    test('겹치거나 맞닿은 구간은 합친다', () {
      expect(normalizeRanges([r(0, 3), r(2, 5)]), [r(0, 5)]);
      expect(normalizeRanges([r(0, 3), r(3, 5)]), [r(0, 5)]);
      expect(normalizeRanges([r(0, 3), r(3.0005, 5)]), [r(0, 5)],
          reason: '1ms 이내 틈은 맞닿은 것으로 본다');
      expect(normalizeRanges([r(0, 10), r(2, 3)]), [r(0, 10)],
          reason: '완전히 안에 든 구간');
    });

    test('떨어진 구간은 그대로 둔다', () {
      expect(normalizeRanges([r(0, 3), r(4, 6)]), [r(0, 3), r(4, 6)]);
    });

    test('0.5초 미만은 버리고 정확히 0.5초는 남긴다', () {
      expect(normalizeRanges([r(0, 0.49)]), isEmpty);
      expect(normalizeRanges([r(0, 0.5)]), [r(0, 0.5)]);
      expect(normalizeRanges([r(0, 3), r(5, 5.3)]), [r(0, 3)]);
    });

    test('짧은 두 조각이 합쳐져 0.5초를 넘으면 남는다', () {
      expect(normalizeRanges([r(0, 0.3), r(0.3, 0.7)]), [r(0, 0.7)]);
    });

    test('음수 시작은 0으로, 영상 길이를 넘는 끝은 길이로 자른다', () {
      expect(normalizeRanges([r(-5, 3)], duration: 10), [r(0, 3)]);
      expect(normalizeRanges([r(8, 20)], duration: 10), [r(8, 10)]);
      expect(normalizeRanges([r(11, 20)], duration: 10), isEmpty);
    });

    test('duration 이 없거나 0 이면 끝을 자르지 않는다', () {
      expect(normalizeRanges([r(0, 99)]), [r(0, 99)]);
      expect(normalizeRanges([r(0, 99)], duration: 0), [r(0, 99)]);
    });

    test('뒤집힌/빈 구간은 버린다', () {
      expect(normalizeRanges([r(5, 3), r(2, 2)]), isEmpty);
    });

    test('빈 입력', () {
      expect(normalizeRanges(const []), isEmpty);
    });
  });

  group('TimeRange / ClipEdit 직렬화', () {
    test('TimeRange JSON 왕복', () {
      final t = TimeRange.fromJson(const TimeRange(1.5, 4).toJson());
      expect(t, const TimeRange(1.5, 4));
      expect(const TimeRange(1.5, 4).toJson(), {'s': 1.5, 'e': 4.0});
    });

    test('TimeRange.fromJson 은 깨진 값에 null', () {
      expect(TimeRange.fromJson(null), isNull);
      expect(TimeRange.fromJson('x'), isNull);
      expect(TimeRange.fromJson({'s': 1}), isNull);
      expect(TimeRange.fromJson({'s': 5, 'e': 5}), isNull);
      expect(TimeRange.fromJson({'s': 5, 'e': 2}), isNull);
    });

    test('기본 편집은 빈 JSON, isDefault', () {
      expect(ClipEdit.none.isDefault, isTrue);
      expect(ClipEdit.none.isTrimmed, isFalse);
      expect(ClipEdit.none.toJson(), isEmpty);
    });

    test('왕복: 전부 지정', () {
      final e = ClipEdit(
        keep: [r(1, 3), r(5, 9.25)],
        volume: VolumeLevel.high,
        brightness: BrightnessLevel.brighter,
      );
      final back = ClipEdit.fromJson(jsonDecode(jsonEncode(e.toJson())));
      expect(back, e);
      expect(back.hashCode, e.hashCode);
      expect(back.isDefault, isFalse);
      expect(back.isTrimmed, isTrue);
    });

    test('왕복: 모든 소리·밝기 단계', () {
      for (final v in VolumeLevel.values) {
        for (final b in BrightnessLevel.values) {
          final e = ClipEdit(volume: v, brightness: b);
          expect(ClipEdit.fromJson(e.toJson()), e, reason: '$v $b');
        }
      }
    });

    test('옛 형식(edit 키 없음, null, 이상한 타입)은 편집 없음', () {
      expect(ClipEdit.fromJson(null), ClipEdit.none);
      expect(ClipEdit.fromJson('abc'), ClipEdit.none);
      expect(ClipEdit.fromJson(const {}), ClipEdit.none);
      expect(ClipEdit.fromJson(const {'volume': 'bogus', 'brightness': 7}),
          ClipEdit.none);
    });

    test('fromJson 은 구간을 정규화한다', () {
      final e = ClipEdit.fromJson({
        'keep': [
          {'s': 5, 'e': 8},
          {'s': 0, 'e': 2},
          {'s': 1, 'e': 3},
          {'s': 9, 'e': 9.1},
          {'s': 1},
        ],
      });
      expect(e.keep, [r(0, 3), r(5, 8)]);
    });

    test('== 는 구간·소리·밝기를 모두 비교', () {
      final a = ClipEdit(keep: [r(0, 2)]);
      expect(a, ClipEdit(keep: [r(0, 2)]));
      expect(a == ClipEdit(keep: [r(0, 3)]), isFalse);
      expect(a == a.copyWith(volume: VolumeLevel.low), isFalse);
      expect(a == a.copyWith(brightness: BrightnessLevel.darker), isFalse);
      expect(a == ClipEdit(keep: [r(0, 2), r(4, 6)]), isFalse);
    });

    test('signature 는 편집이 달라지면 달라진다', () {
      final base = ClipEdit(keep: [r(1, 3)]);
      final sigs = <String>{
        ClipEdit.none.signature,
        base.signature,
        ClipEdit(keep: [r(1, 3.5)]).signature,
        base.copyWith(volume: VolumeLevel.mute).signature,
        base.copyWith(brightness: BrightnessLevel.brightest).signature,
      };
      expect(sigs.length, 5);
      expect(ClipEdit(keep: [r(1, 3)]).signature, base.signature);
    });
  });

  group('ClipItem', () {
    test('effectiveDuration: 편집 없으면 전체, 있으면 구간 합', () {
      expect(clip('a', duration: 12).effectiveDuration, 12);
      final c = clip('a',
          duration: 12, edit: ClipEdit(keep: [r(0, 2), r(5, 8.5)]));
      expect(c.effectiveDuration, closeTo(5.5, 1e-9));
    });

    test('ranges: 편집 없으면 [0, duration]', () {
      expect(clip('a', duration: 12).ranges, [r(0, 12)]);
      final c = clip('a', edit: ClipEdit(keep: [r(1, 2)]));
      expect(c.ranges, [r(1, 2)]);
    });

    test('needsReencode', () {
      expect(clip('a').needsReencode, isFalse);
      expect(clip('a', rotation: 90).needsReencode, isTrue);
      expect(
          clip('a', edit: const ClipEdit(volume: VolumeLevel.low))
              .needsReencode,
          isTrue);
      expect(clip('a', edit: ClipEdit(keep: [r(0, 2)])).needsReencode, isTrue);
    });

    test('copyWith 는 edit 을 바꾸고 나머지는 유지', () {
      final c = clip('a', rotation: 180);
      final e = ClipEdit(keep: [r(0, 2)]);
      final d = c.copyWith(edit: e);
      expect(d.edit, e);
      expect(d.userRotation, 180);
      expect(d.id, 'a');
      expect(identical(d.spec, c.spec), isTrue);
      expect(c.copyWith().edit, c.edit);
    });
  });

  group('Executor.buildUnits', () {
    test('편집 없는 영상은 영상 하나당 조각 하나, 자르지 않음', () {
      final units =
          Executor.buildUnits([clip('a'), clip('b')], settings());
      expect(units.length, 2);
      expect(units.map((u) => u.trimmed), [false, false]);
      expect(units.map((u) => u.clipIndex), [0, 1]);
      expect(units.every((u) => !u.fadeIn && !u.fadeOut), isTrue);
      expect(units[0].duration, 10);
    });

    test('남긴 구간 수만큼 조각이 생긴다', () {
      final c = clip('a', edit: ClipEdit(keep: [r(0, 2), r(4, 6), r(8, 10)]));
      final units = Executor.buildUnits([c, clip('b')], settings());
      expect(units.length, 4);
      expect(units.take(3).every((u) => u.trimmed && u.clipIndex == 0), isTrue);
      expect(units[3].clipIndex, 1);
      expect(units[3].trimmed, isFalse);
      expect(units[1].duration, 2);
    });

    test('부드럽게: 처음 조각엔 fadeIn 없음, 마지막 조각엔 fadeOut 없음', () {
      final units = Executor.buildUnits(
          [clip('a'), clip('b'), clip('c')], settings(smooth: true));
      expect(units.map((u) => u.fadeIn), [false, true, true]);
      expect(units.map((u) => u.fadeOut), [true, true, false]);
    });

    test('부드럽게: 한 영상 안의 잘린 조각 사이에도 적용', () {
      final c = clip('a', edit: ClipEdit(keep: [r(0, 4), r(6, 10)]));
      final units = Executor.buildUnits([c], settings(smooth: true));
      expect(units.length, 2);
      expect(units[0].fadeIn, isFalse);
      expect(units[0].fadeOut, isTrue);
      expect(units[1].fadeIn, isTrue);
      expect(units[1].fadeOut, isFalse);
    });

    test('부드럽게: 영상이 하나뿐이면 페이드 없음', () {
      final units =
          Executor.buildUnits([clip('a')], settings(smooth: true));
      expect(units.single.fadeIn, isFalse);
      expect(units.single.fadeOut, isFalse);
    });

    test('부드럽게: 1.5초(3*kFadeSec) 미만 조각은 페이드를 건너뛴다', () {
      final c = clip('a',
          edit: ClipEdit(keep: [r(0, 4), r(5, 6.4), r(7, 9)]));
      final units = Executor.buildUnits([c], settings(smooth: true));
      expect(units.length, 3);
      expect(units[1].duration, closeTo(1.4, 1e-9));
      expect(units[1].fadeIn, isFalse);
      expect(units[1].fadeOut, isFalse);
      expect(units[0].fadeOut, isTrue);
      expect(units[2].fadeIn, isTrue);
    });

    test('부드럽게: 정확히 3*kFadeSec 길이는 페이드 적용', () {
      final c = clip('a', edit: ClipEdit(keep: [r(0, 4), r(5, 6.5), r(7, 9)]));
      final units = Executor.buildUnits([c], settings(smooth: true));
      expect(units[1].fadeIn, isTrue);
      expect(units[1].fadeOut, isTrue);
    });

    test('무손실이면 부드럽게를 켜 놓아도 페이드 없음', () {
      final units = Executor.buildUnits(
          [clip('a'), clip('b')], settings(lossless: true, smooth: true));
      expect(units.every((u) => !u.fadeIn && !u.fadeOut), isTrue);
    });
  });

  group('Executor.normalizeArgs', () {
    final ex = executor();

    List<String> args(ClipItem c, {OutputSettings? s}) {
      final st = s ?? settings();
      final u = Executor.buildUnits([c], st).single;
      return ex.normalizeArgs(u, st, 'out.ts', encoder: 'libx264');
    }

    test('자르지 않았으면 -ss/-t 없음', () {
      final a = args(clip('a'));
      expect(a.contains('-ss'), isFalse);
      expect(a.contains('-t'), isFalse);
    });

    test('자르면 -ss 가 -i 앞에, -t 는 구간 길이', () {
      final c = clip('a', edit: ClipEdit(keep: [r(2.5, 6.25)]));
      final a = args(c);
      final ss = a.indexOf('-ss');
      final i = a.indexOf('-i');
      expect(ss, greaterThanOrEqualTo(0));
      expect(ss, lessThan(i));
      expect(a[ss + 1], '2.500');
      final t = a.indexOf('-t');
      expect(t, greaterThan(i), reason: '-t 는 출력 쪽 옵션');
      expect(a[t + 1], '3.750');
    });

    test('소리 편집 없고 소리 있는 영상은 -af 없음', () {
      expect(args(clip('a')).contains('-af'), isFalse);
    });

    test('소리 크기를 바꾸면 -af 에 volume', () {
      final a = args(clip('a', edit: const ClipEdit(volume: VolumeLevel.low)));
      final af = a[a.indexOf('-af') + 1];
      expect(af, 'volume=0.50');
    });

    test('소리 없는 영상은 볼륨을 바꿔도 -af 없음 (anullsrc 사용)', () {
      final a = args(clip('a',
          hasAudio: false, edit: const ClipEdit(volume: VolumeLevel.max)));
      expect(a.contains('-af'), isFalse);
      expect(a.join(' '), contains('anullsrc'));
      expect(a.contains('-shortest'), isTrue);
    });

    test('소리 없는 영상을 잘라도 -t 가 붙는다', () {
      final a = args(
          clip('a', hasAudio: false, edit: ClipEdit(keep: [r(1, 3)])));
      expect(a[a.indexOf('-t') + 1], '2.000');
    });

    test('부드럽게 켜면 -af 에 afade, -vf 에 fade', () {
      final st = settings(smooth: true);
      final units = Executor.buildUnits([clip('a'), clip('b')], st);
      final a = ex.normalizeArgs(units[1], st, 'o.ts', encoder: 'libx264');
      expect(a[a.indexOf('-af') + 1], 'afade=t=in:st=0:d=0.5');
      expect(a[a.indexOf('-vf') + 1], contains('fade=t=in:st=0:d=0.5'));
    });
  });

  group('필터 체인', () {
    test('밝기: eq=gamma 가 format=yuv420p 뒤에 붙는다', () {
      final vf = Executor.buildFilterChain(
          clip('a', edit: const ClipEdit(brightness: BrightnessLevel.brighter)),
          settings());
      expect(vf, contains('eq=gamma=1.25'));
      expect(vf.indexOf('eq=gamma'), greaterThan(vf.indexOf('format=yuv420p')));
    });

    test('밝기 기본이면 eq 없음', () {
      expect(Executor.buildFilterChain(clip('a'), settings()),
          isNot(contains('eq=')));
    });

    test('모든 밝기 단계의 감마값', () {
      final expected = {
        BrightnessLevel.darker: '0.80',
        BrightnessLevel.brighter: '1.25',
        BrightnessLevel.brightest: '1.50',
      };
      expected.forEach((lv, g) {
        final vf = Executor.buildFilterChain(
            clip('a', edit: ClipEdit(brightness: lv)), settings());
        expect(vf, contains('eq=gamma=$g'));
      });
    });

    test('fade in/out 의 st 는 duration - 0.5', () {
      final vf = Executor.buildFilterChain(clip('a'), settings(),
          fadeIn: true, fadeOut: true, duration: 4);
      expect(vf, contains('fade=t=in:st=0:d=0.5'));
      expect(vf, contains('fade=t=out:st=3.500:d=0.5'));
      expect(vf.endsWith('fade=t=out:st=3.500:d=0.5'), isTrue,
          reason: '페이드는 체인 맨 끝');
    });

    test('밝기와 페이드가 함께면 eq 가 fade 앞', () {
      final vf = Executor.buildFilterChain(
          clip('a', edit: const ClipEdit(brightness: BrightnessLevel.darker)),
          settings(),
          fadeIn: true,
          duration: 4);
      expect(vf.indexOf('eq='), lessThan(vf.indexOf('fade=')));
    });

    test('fadeOut 인데 duration 이 0.5 이하면 fade out 생략', () {
      final vf = Executor.buildFilterChain(clip('a'), settings(),
          fadeOut: true, duration: 0.5);
      expect(vf, isNot(contains('fade=t=out')));
    });

    test('페이드 없으면 fade 없음', () {
      expect(Executor.buildFilterChain(clip('a'), settings()),
          isNot(contains('fade=')));
    });

    test('오디오 필터: 기본은 빈 문자열', () {
      expect(Executor.buildAudioFilter(clip('a')), '');
    });

    test('오디오 필터: 키우면 alimiter(latency=1) 가 붙고, 줄이면 없다', () {
      final hi = Executor.buildAudioFilter(
          clip('a', edit: const ClipEdit(volume: VolumeLevel.high)));
      expect(hi, startsWith('volume=1.60,alimiter='));
      expect(hi, contains('latency=1'));
      final mx = Executor.buildAudioFilter(
          clip('a', edit: const ClipEdit(volume: VolumeLevel.max)));
      expect(mx, startsWith('volume=2.50,alimiter='));
      final lo = Executor.buildAudioFilter(
          clip('a', edit: const ClipEdit(volume: VolumeLevel.low)));
      expect(lo, 'volume=0.50');
      final mute = Executor.buildAudioFilter(
          clip('a', edit: const ClipEdit(volume: VolumeLevel.mute)));
      expect(mute, 'volume=0.00');
    });

    test('오디오 필터: afade out 의 st', () {
      final af = Executor.buildAudioFilter(clip('a'),
          fadeIn: true, fadeOut: true, duration: 6);
      expect(af, 'afade=t=in:st=0:d=0.5,afade=t=out:st=5.500:d=0.5');
    });

    test('오디오 필터: 볼륨 뒤에 페이드', () {
      final af = Executor.buildAudioFilter(
          clip('a', edit: const ClipEdit(volume: VolumeLevel.low)),
          fadeIn: true,
          duration: 6);
      expect(af.indexOf('volume'), lessThan(af.indexOf('afade')));
    });
  });

  group('JobPlan.analyze', () {
    test('편집 없으면 무손실 가능', () {
      final plan = JobPlan.analyze([clip('a'), clip('b')]);
      expect(plan.losslessPossible, isTrue);
      expect(plan.losslessBlockedReason, isNull);
    });

    test('소리만 바꿔도 무손실 불가, 이유에 개수', () {
      final plan = JobPlan.analyze([
        clip('a', edit: const ClipEdit(volume: VolumeLevel.mute)),
        clip('b'),
        clip('c', edit: ClipEdit(keep: [r(0, 3)])),
      ]);
      expect(plan.losslessPossible, isFalse);
      expect(plan.losslessBlockedReason, contains('2개 영상을 손봤기 때문에'));
    });

    test('밝기만 바꿔도 무손실 불가', () {
      final plan = JobPlan.analyze([
        clip('a', edit: const ClipEdit(brightness: BrightnessLevel.darker)),
      ]);
      expect(plan.losslessPossible, isFalse);
    });

    test('부드럽게 넘기기만 켜도 무손실 불가', () {
      final plan =
          JobPlan.analyze([clip('a'), clip('b')], smoothTransitions: true);
      expect(plan.losslessPossible, isFalse);
      expect(plan.losslessBlockedReason, isNotNull);
    });

    test('회전 이유가 편집 이유보다 먼저', () {
      final plan = JobPlan.analyze([
        clip('a', rotation: 90),
        clip('b', edit: ClipEdit(keep: [r(0, 3)])),
      ]);
      expect(plan.losslessBlockedReason, contains('회전'));
    });

    test('totalDuration 은 effectiveDuration 합', () {
      final plan = JobPlan.analyze([
        clip('a', duration: 10, edit: ClipEdit(keep: [r(0, 2), r(5, 8)])),
        clip('b', duration: 7),
      ]);
      expect(plan.totalDuration, closeTo(12, 1e-9));
    });

    test('OutputSettings.clone 은 smoothTransitions 를 복사', () {
      expect(settings(smooth: true).clone().smoothTransitions, isTrue);
      expect(settings().clone().smoothTransitions, isFalse);
    });
  });

  group('저장 파일', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('vj_clip_edit_');
    });
    tearDown(() => forceDeleteDir(dir));

    final edit = ClipEdit(
      keep: [r(1, 3), r(5, 9)],
      volume: VolumeLevel.low,
      brightness: BrightnessLevel.brightest,
    );

    test('JobListFile 왕복 + edit 키는 손봤을 때만', () async {
      final path = p.join(dir.path, 'a.vjlist');
      await JobListFile.save(path, [
        clip('a', edit: edit, rotation: 90),
        clip('b'),
      ]);
      final raw = jsonDecode(utf8.decode(File(path).readAsBytesSync()))
          as Map<String, dynamic>;
      final cl = raw['clips'] as List;
      expect((cl[0] as Map).containsKey('edit'), isTrue);
      expect((cl[1] as Map).containsKey('edit'), isFalse);

      final back = await JobListFile.load(path);
      expect(back.length, 2);
      expect(back[0].rotation, 90);
      expect(back[0].edit, edit);
      expect(back[1].edit, ClipEdit.none);
    });

    test('JobListFile: edit 없는 옛 파일도 읽힌다', () async {
      final path = p.join(dir.path, 'old.vjlist');
      File(path).writeAsBytesSync(utf8.encode(jsonEncode({
        'version': 1,
        'clips': [
          {'path': r'C:\a\한글.mp4', 'rotation': 180},
        ],
      })));
      final back = await JobListFile.load(path);
      expect(back.single.path, r'C:\a\한글.mp4');
      expect(back.single.rotation, 180);
      expect(back.single.edit, ClipEdit.none);
    });

    QueuedJob job(List<ClipItem> clips, OutputSettings s,
            {QueuedStatus status = QueuedStatus.waiting}) =>
        QueuedJob(
          id: 'q1',
          clips: clips,
          settings: s,
          plan: JobPlan.analyze(clips, smoothTransitions: s.smoothTransitions),
          status: status,
        );

    test('QueueStore 왕복: 편집과 smooth 플래그', () {
      final store = QueueStore(p.join(dir.path, 'q.json'));
      store.save([
        job([clip('a', edit: edit), clip('b', rotation: 270)],
            settings(smooth: true)),
      ]);
      final loaded = store.load();
      expect(loaded.length, 1);
      expect(loaded.single.settings.smoothTransitions, isTrue);
      expect(loaded.single.clips[0].edit, edit);
      expect(loaded.single.clips[1].edit, ClipEdit.none);
      expect(loaded.single.clips[1].rotation, 270);
    });

    test('QueueStore: smooth 끄면 꺼진 채로 되살아난다', () {
      final store = QueueStore(p.join(dir.path, 'q.json'));
      store.save([job([clip('a')], settings())]);
      expect(store.load().single.settings.smoothTransitions, isFalse);
    });

    test('QueueStore: edit·smooth 없는 옛 파일 읽기', () {
      final path = p.join(dir.path, 'old_q.json');
      File(path).writeAsBytesSync(utf8.encode(jsonEncode({
        'version': 1,
        'jobs': [
          {
            'clips': [
              {'path': r'C:\v\a.mp4', 'rotation': 90},
            ],
            'settings': {
              'lossless': false,
              'width': 1920,
              'height': 1080,
              'fpsNum': 30,
              'fpsDen': 1,
              'videoBitrate': 8000000,
              'outputDir': r'C:\out',
              'outputName': 'old',
            },
          },
        ],
      })));
      final loaded = QueueStore(path).load();
      expect(loaded.length, 1);
      expect(loaded.single.clips.single.edit, ClipEdit.none);
      expect(loaded.single.clips.single.rotation, 90);
      expect(loaded.single.settings.smoothTransitions, isFalse);
    });

    test('QueueStore: 끝난 작업만 있으면 파일이 지워진다', () {
      final path = p.join(dir.path, 'q.json');
      final store = QueueStore(path);
      store.save([job([clip('a', edit: edit)], settings())]);
      expect(File(path).existsSync(), isTrue);
      store.save([
        job([clip('a')], settings(), status: QueuedStatus.done),
      ]);
      expect(File(path).existsSync(), isFalse);
    });
  });
}
