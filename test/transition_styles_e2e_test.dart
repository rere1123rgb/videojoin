// 겹치기 전환(디졸브·밀어내기·닦아내기·다가가기·흐리기·흑백)을 실제 ffmpeg 으로
// 만들어 본다. 길이(합 − 전환 수 × d), 화면·소리 길이 차, 전환 한가운데
// 장면이 앞·뒤 몸통 장면과 실제로 다른지, ffmpeg 이 남지 않는지 확인한다.
//
//   flutter test test/transition_styles_e2e_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:videojoin/engine/encoder_support.dart';
import 'package:videojoin/engine/executor.dart';
import 'package:videojoin/engine/ffmpeg_tools.dart';
import 'package:videojoin/engine/fs_util.dart';
import 'package:videojoin/engine/job_log.dart';
import 'package:videojoin/engine/models.dart';
import 'package:videojoin/engine/planner.dart';
import 'package:videojoin/engine/prober.dart';
import 'package:videojoin/engine/rational.dart';
import 'package:videojoin/engine/transitions.dart';

final _root = Directory.current.path;
final _tools = FFTools(
  ffmpegPath: p.join(_root, 'tools', 'ffmpeg.exe'),
  ffprobePath: p.join(_root, 'tools', 'ffprobe.exe'),
);

Future<(double fmt, double v, double a)> _durations(String path) async {
  final r = await Process.run(_tools.ffprobePath, [
    '-v', 'error',
    '-show_entries', 'format=duration:stream=codec_type,duration',
    '-of', 'json',
    path,
  ], stdoutEncoding: utf8);
  final j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
  final streams = (j['streams'] as List).cast<Map>();
  double d(String type) => double.parse(
      streams.firstWhere((s) => s['codec_type'] == type)['duration'] as String);
  return (double.parse(j['format']['duration'] as String), d('video'), d('audio'));
}

/// t 초 지점 장면을 32×18 흑백으로 뽑는다.
Future<List<int>> _grab(String path, double t) async {
  final r = await Process.run(
    _tools.ffmpegPath,
    [
      '-hide_banner', '-nostdin', '-v', 'error',
      '-ss', t.toStringAsFixed(3), '-i', path,
      '-frames:v', '1',
      '-vf', 'scale=32:18,format=gray',
      '-f', 'rawvideo', '-',
    ],
    stdoutEncoding: null,
  );
  return (r.stdout as List<int>);
}

double _mean(List<int> a) => a.isEmpty ? 0 : a.reduce((x, y) => x + y) / a.length;

double _diff(List<int> a, List<int> b) {
  final n = a.length < b.length ? a.length : b.length;
  if (n == 0) return 0;
  var s = 0;
  for (var i = 0; i < n; i++) {
    s += (a[i] - b[i]).abs();
  }
  return s / n;
}

/// 이 테스트의 작업 폴더를 쓰는 ffmpeg 이 남아 있는 수.
/// (다른 테스트가 동시에 돌리는 ffmpeg 은 세지 않는다.)
Future<int> _leftover(Directory work) async {
  final r = await Process.run('powershell', [
    '-NoProfile',
    '-Command',
    "(Get-CimInstance Win32_Process -Filter \"Name='ffmpeg.exe'\" | "
        "Where-Object { \$_.CommandLine -like '*vj_trans_e2e_*' } | "
        "Measure-Object).Count",
  ]);
  return int.tryParse((r.stdout as String).trim()) ?? 0;
}

OutputSettings _settings(Directory work, String name,
    {required TransitionStyle style,
    TransitionLength length = TransitionLength.normal,
    bool gpu = false,
    bool ends = false}) =>
    OutputSettings(
      lossless: false,
      width: 640,
      height: 360,
      frameRate: const Rational(30, 1),
      videoBitrate: 1500000,
      useGpu: gpu,
      smoothTransitions: true,
      transitionStyle: style,
      transitionLength: length,
      fadeEnds: ends,
      outputDir: work.path,
      outputName: name,
    );

Future<void> _run(Directory work, List<ClipItem> clips, OutputSettings s,
    {EncoderSupport enc = const EncoderSupport()}) async {
  final logFile = File(p.join(work.path, '${s.outputName}.log'));
  final ex = Executor(tools: _tools, encoders: enc, log: JobLog(logFile));
  final ev = await ex.run(clips, s).toList();
  if (ev.last.stage != JobStage.done) {
    fail('${s.outputName}: ${ev.last.message} ${ev.last.errorMessage ?? ''}\n'
        '${logFile.existsSync() ? logFile.readAsStringSync() : ''}');
  }
}

void main() {
  late Directory work;
  late Map<String, ClipItem> clip;
  setUpAll(() async {
    work = Directory.systemTemp.createTempSync('vj_trans_e2e_');
    final prober = Prober(_tools);
    clip = {};
    for (final f in ['same_a', 'same_b', 'no_audio', 'portrait_rot90']) {
      final spec = await prober.probe(p.join(_root, 'testdata', '$f.mp4'));
      expect(spec.ok, isTrue, reason: spec.errorMessage);
      clip[f] = ClipItem(id: f, spec: spec);
    }
  });
  tearDownAll(() => forceDeleteDir(work));

  for (final style in TransitionStyle.values.where((s) => s.isOverlap)) {
    test('겹치기 전환 ${style.name}: 길이·싱크·가운데 장면', () async {
        final clips = [clip['same_a']!, clip['same_b']!];
      final s = _settings(work, 'st_${style.name}', style: style);
      final d = overlapSeconds(s);
      expect(d, closeTo(1.0, 1e-9));
      final sum = clips.fold<double>(0, (a, c) => a + c.effectiveDuration);
      final expected = sum - d;
      expect(outputDurationFor(clips, s), closeTo(expected, 1e-9));

      await _run(work, clips, s);
      final out = p.join(work.path, 'st_${style.name}.mp4');
      final (fmt, v, a) = await _durations(out);

      // A 몸통은 0 ~ (A길이 − d), 전환은 그 뒤 d 초.
      final aLen = clips[0].effectiveDuration;
      final tMid = aLen - d + d / 2;
      final lastA = await _grab(out, aLen - d - 0.05);
      final mid = await _grab(out, tMid);
      final firstB = await _grab(out, aLen + 0.05);
      final dA = _diff(mid, lastA);
      final dB = _diff(mid, firstB);
      printOnFailure('${style.name}: sum=$sum expected=$expected fmt=$fmt v=$v a=$a '
          'luma lastA=${_mean(lastA).toStringAsFixed(1)} '
          'mid=${_mean(mid).toStringAsFixed(1)} firstB=${_mean(firstB).toStringAsFixed(1)} '
          'diffA=${dA.toStringAsFixed(1)} diffB=${dB.toStringAsFixed(1)}');
      // ignore: avoid_print
      print('[RESULT] ${style.name}: expected=$expected fmt=${fmt.toStringAsFixed(3)} '
          'v=${v.toStringAsFixed(3)} a=${a.toStringAsFixed(3)} '
          '|v-a|=${(v - a).abs().toStringAsFixed(3)} '
          'luma A/mid/B=${_mean(lastA).toStringAsFixed(1)}/${_mean(mid).toStringAsFixed(1)}/${_mean(firstB).toStringAsFixed(1)} '
          'diff mid-A=${dA.toStringAsFixed(1)} mid-B=${dB.toStringAsFixed(1)}');
      expect(fmt, closeTo(expected, 0.15));
      expect((v - a).abs(), lessThan(0.12));
      expect(dA, greaterThan(1.5), reason: '가운데 장면이 앞 몸통과 같다');
      expect(dB, greaterThan(1.5), reason: '가운데 장면이 뒤 몸통과 같다');
      expect(await _leftover(work), 0, reason: 'ffmpeg 이 남았다');
    }, timeout: const Timeout(Duration(minutes: 3)));
  }

  test('디졸브: 소리 없음 + 회전 + 가운데 자르기가 섞여도 길이·싱크가 맞다', () async {
    final cut = clip['same_a']!.copyWith(
        edit: const ClipEdit(keep: [TimeRange(0.0, 2.0), TimeRange(2.1, 3.9)]));
    final clips = [
      cut,
      clip['no_audio']!,
      clip['portrait_rot90']!.copyWith(userRotation: 90),
      clip['same_b']!.copyWith(
          edit: const ClipEdit(
              keep: [TimeRange(0.5, 3.5)],
              volume: VolumeLevel.high,
              brightness: BrightnessLevel.brighter)),
    ];
    // 짧게(d=0.6): 중간을 자른 두 구간 사이도 전환이 들어갈 만큼 길다.
    final s = _settings(work, 'mixed',
        style: TransitionStyle.dissolve, length: TransitionLength.short);
    final units = Executor.buildUnits(clips, s);
    final joins = units.where((u) => u.join != null).length;
    final d = overlapSeconds(s);
    expect(joins, 4); // 5 구간 사이 이음매 4개
    final sum = clips.fold<double>(0, (a, c) => a + c.effectiveDuration);
    final expected = sum - joins * d;
    expect(outputDurationFor(clips, s), closeTo(expected, 1e-9));
    await _run(work, clips, s);
    final (fmt, v, a) = await _durations(p.join(work.path, 'mixed.mp4'));
    // ignore: avoid_print
    print('[RESULT] mixed: expected=$expected fmt=${fmt.toStringAsFixed(3)} '
        'v=${v.toStringAsFixed(3)} a=${a.toStringAsFixed(3)} '
        '|v-a|=${(v - a).abs().toStringAsFixed(3)}');
    // 조각 아홉 개가 이어져 조각마다 붙는 ~0.02초(AAC 패딩)가 쌓인다.
    expect(fmt, closeTo(expected, 0.25));
    expect((v - a).abs(), lessThan(0.15));
    expect(await _leftover(work), 0, reason: 'ffmpeg 이 남았다');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('GPU(NVENC) 로도 겹치기 전환이 된다', () async {
    final enc = await EncoderSupport.detect(_tools);
    if (!enc.anyGpu) {
      markTestSkipped('GPU 인코더 없음');
      return;
    }
    final clips = [clip['same_a']!, clip['no_audio']!, clip['same_b']!];
    final s = _settings(work, 'gpu_dissolve',
        style: TransitionStyle.wipe, gpu: true, ends: true);
    final d = overlapSeconds(s);
    final sum = clips.fold<double>(0, (a, c) => a + c.effectiveDuration);
    final expected = sum - 2 * d;
    await _run(work, clips, s, enc: enc);
    final (fmt, v, a) = await _durations(p.join(work.path, 'gpu_dissolve.mp4'));
    final log = File(p.join(work.path, 'gpu_dissolve.log')).readAsStringSync();
    // ignore: avoid_print
    print('[RESULT] gpu: expected=$expected fmt=${fmt.toStringAsFixed(3)} '
        'v=${v.toStringAsFixed(3)} a=${a.toStringAsFixed(3)}');
    expect(log.contains('CPU 로 전환'), isFalse, reason: 'GPU 실패 후 CPU 로 내려감');
    expect(fmt, closeTo(expected, 0.2));
    expect((v - a).abs(), lessThan(0.12));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
