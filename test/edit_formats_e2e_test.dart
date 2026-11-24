// 여러 실제 형식(가변 프레임, 회전 메타, HDR, 옛 AVI, 5.1 채널, 소리 없음)에서
// 가운데를 잘라낸 결과가 정확한 길이로, 소리와 화면이 맞게 나오는지 본다.
// GPU 인코더(NVENC)가 있으면 한 번은 그걸로도 만든다.
//
//   flutter test test/edit_formats_e2e_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:videojoin/engine/encoder_support.dart';
import 'package:videojoin/engine/executor.dart';
import 'package:videojoin/engine/ffmpeg_tools.dart';
import 'package:videojoin/engine/frame_grabber.dart';
import 'package:videojoin/engine/fs_util.dart';
import 'package:videojoin/engine/job_log.dart';
import 'package:videojoin/engine/models.dart';
import 'package:videojoin/engine/planner.dart';
import 'package:videojoin/engine/prober.dart';
import 'package:videojoin/engine/rational.dart';

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

Future<double> _meanVolume(String path) async {
  final r = await Process.run(_tools.ffmpegPath, [
    '-hide_banner', '-nostdin', '-i', path,
    '-af', 'volumedetect', '-f', 'null', '-',
  ], stderrEncoding: utf8);
  final m = RegExp(r'mean_volume: (-?[\d.]+) dB').firstMatch(r.stderr as String);
  return m == null ? -999 : double.parse(m.group(1)!);
}

Future<JobProgress> _render(
  Directory work,
  List<ClipItem> clips,
  String name, {
  EncoderSupport enc = const EncoderSupport(),
  bool gpu = false,
  bool smooth = false,
}) async {
  final s = OutputSettings(
    lossless: false,
    width: 1280,
    height: 720,
    frameRate: const Rational(30, 1),
    videoBitrate: 4000000,
    useGpu: gpu,
    smoothTransitions: smooth,
    outputDir: work.path,
    outputName: name,
  );
  final logFile = File(p.join(work.path, '$name.log'));
  final ex = Executor(tools: _tools, encoders: enc, log: JobLog(logFile));
  final ev = await ex.run(clips, s).toList();
  if (ev.last.stage != JobStage.done) {
    fail('$name: ${ev.last.message} ${ev.last.errorMessage ?? ''}\n'
        '${logFile.existsSync() ? logFile.readAsStringSync() : ''}');
  }
  return ev.last;
}

/// 앞 15%~35% 와 55%~90% 만 남긴다(가운데·앞·끝을 모두 잘라냄).
ClipEdit _middleCut(double d) => ClipEdit(keep: [
      TimeRange(d * 0.15, d * 0.35),
      TimeRange(d * 0.55, d * 0.90),
    ]);

void main() {
  late Directory work;
  setUpAll(() => work = Directory.systemTemp.createTempSync('vj_fmt_e2e_'));
  tearDownAll(() => forceDeleteDir(work));

  const files = [
    'vfr_phone.mp4',
    'portrait_rot90.mp4',
    'hdr_4k.mp4',
    'legacy.avi',
    'audio_51.mp4',
    'no_audio.mp4',
    'anamorphic.mp4',
  ];

  for (final f in files) {
    test('가운데 잘라내기: $f', () async {
      final spec = await Prober(_tools).probe(p.join(_root, 'testdata', f));
      expect(spec.ok, isTrue, reason: spec.errorMessage);
      final edit = _middleCut(spec.durationSec);
      final clip = ClipItem(id: f, spec: spec, edit: edit);
      final expected = clip.effectiveDuration;
      await _render(work, [clip], 'cut_${p.basenameWithoutExtension(f)}',
          smooth: true);
      final out = p.join(work.path, 'cut_${p.basenameWithoutExtension(f)}.mp4');
      final (fmt, v, a) = await _durations(out);
      printOnFailure('$f expected=$expected fmt=$fmt v=$v a=$a');
      expect(fmt, closeTo(expected, 0.2));
      expect((v - a).abs(), lessThan(0.12));
    }, timeout: const Timeout(Duration(minutes: 5)));
  }

  test('소리 크게(리미터) 는 실패 없이 커지고, 화면·소리 길이가 맞다', () async {
    final spec =
        await Prober(_tools).probe(p.join(_root, 'testdata', 'same_a.mp4'));
    Future<double> vol(VolumeLevel lv) async {
      final clip = ClipItem(
          id: lv.name,
          spec: spec,
          edit: ClipEdit(keep: const [TimeRange(0.5, 3.5)], volume: lv));
      await _render(work, [clip], 'vol_${lv.name}');
      final out = p.join(work.path, 'vol_${lv.name}.mp4');
      final (_, v, a) = await _durations(out);
      expect((v - a).abs(), lessThan(0.12), reason: '${lv.name} v=$v a=$a');
      return _meanVolume(out);
    }

    final normal = await vol(VolumeLevel.normal);
    final high = await vol(VolumeLevel.high);
    final max = await vol(VolumeLevel.max);
    final low = await vol(VolumeLevel.low);
    printOnFailure('low=$low normal=$normal high=$high max=$max');
    expect(normal, greaterThan(-200));
    expect(high, greaterThan(normal + 1));
    expect(max, greaterThan(high));
    expect(low, lessThan(normal - 3));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('GPU(NVENC) 로도 자르기·전환이 된다', () async {
    final enc = await EncoderSupport.detect(_tools);
    if (!enc.anyGpu) {
      markTestSkipped('GPU 인코더 없음');
      return;
    }
    final prober = Prober(_tools);
    final a = await prober.probe(p.join(_root, 'testdata', 'same_a.mp4'));
    final b = await prober.probe(p.join(_root, 'testdata', 'vfr_phone.mp4'));
    final clips = [
      ClipItem(id: 'a', spec: a, edit: const ClipEdit(keep: [TimeRange(1, 3)])),
      ClipItem(id: 'b', spec: b, edit: _middleCut(b.durationSec)),
    ];
    final expected = clips.fold<double>(0, (s, c) => s + c.effectiveDuration);
    await _render(work, clips, 'gpu', enc: enc, gpu: true, smooth: true);
    final (fmt, v, au) = await _durations(p.join(work.path, 'gpu.mp4'));
    final log = File(p.join(work.path, 'gpu.log')).readAsStringSync();
    printOnFailure('expected=$expected fmt=$fmt v=$v a=$au\n$log');
    expect(log.contains('CPU 로 전환'), isFalse, reason: 'GPU 실패 후 CPU 로 내려감');
    expect(fmt, closeTo(expected, 0.2));
    expect((v - au).abs(), lessThan(0.12));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('큰 4K 영상 끝부분 장면 뽑기 시간', () async {
    final spec =
        await Prober(_tools).probe(p.join(_root, 'testdata', 'uhd_4k.mp4'));
    final g = FrameGrabber(_tools);
    final sw = Stopwatch()..start();
    final f = await g.frameAt(spec, spec.durationSec * 0.93 + 0.0123);
    sw.stop();
    expect(f, isNotNull);
    // 기록용. 너무 느리면(>1.5초) 미리보기가 답답하다.
    printOnFailure('4K frameAt: ${sw.elapsedMilliseconds}ms');
    expect(sw.elapsedMilliseconds, lessThan(1500));
  }, timeout: const Timeout(Duration(minutes: 1)));

}
