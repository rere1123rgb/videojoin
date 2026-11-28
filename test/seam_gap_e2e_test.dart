// 화면·소리 길이가 서로 다른 영상(소리가 더 김 / 늦게 시작 / 일찍 끝남)을
// 이어도 이음매에 구멍이 나지 않는지 잰다.
//
//   flutter test test/seam_gap_e2e_test.dart

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
import 'package:videojoin/engine/transition_style.dart';

final _root = Directory.current.path;
final _tools = FFTools(
  ffmpegPath: p.join(_root, 'tools', 'ffmpeg.exe'),
  ffprobePath: p.join(_root, 'tools', 'ffprobe.exe'),
);

Future<void> _make(String out, String video, String audio,
    {double audioDelay = 0}) async {
  final r = await Process.run(_tools.ffmpegPath, [
    '-v', 'error', '-y',
    '-f', 'lavfi', '-i', video,
    if (audioDelay > 0) ...['-itsoffset', '$audioDelay'],
    '-f', 'lavfi', '-i', audio,
    '-map', '0', '-map', '1',
    '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
    '-c:a', 'aac', out,
  ]);
  expect(r.exitCode, 0, reason: r.stderr as String);
}

Future<List<double>> _pts(String path, String sel) async {
  final r = await Process.run(_tools.ffprobePath, [
    '-v', 'error', '-select_streams', sel,
    '-show_entries', 'packet=pts_time', '-of', 'csv=p=0', path,
  ], stdoutEncoding: utf8);
  final v = <double>[
    for (final l in (r.stdout as String).split('\n'))
      if (l.trim().isNotEmpty && l.trim() != 'N/A') double.parse(l.trim()),
  ]..sort();
  return v;
}

/// 이웃한 패킷 사이 간격 중 가장 큰 것(초).
double _maxStep(List<double> t) {
  var m = 0.0;
  for (var i = 1; i < t.length; i++) {
    if (t[i] - t[i - 1] > m) m = t[i] - t[i - 1];
  }
  return m;
}

void main() {
  late Directory work;
  late List<VideoSpec> specs;

  setUpAll(() async {
    work = Directory.systemTemp.createTempSync('vj_seam_e2e_');
    final a = p.join(work.path, 'long_audio.mp4');
    final b = p.join(work.path, 'late_audio.mp4');
    final c = p.join(work.path, 'short_audio.mp4');
    await _make(a, 'testsrc2=size=640x360:rate=30000/1001:d=3.0',
        'sine=f=1000:r=44100:d=3.15');
    await _make(b, 'testsrc2=size=640x360:rate=30:d=2.5',
        'sine=f=500:r=48000:d=2.2', audioDelay: 0.2);
    await _make(c, 'testsrc2=size=640x360:rate=60:d=2.0',
        'sine=f=700:r=48000:d=1.9');
    specs = await Prober(_tools).probeAll([a, b, c, a, b, c]);
    expect(specs.every((s) => s.ok), isTrue);
  });
  tearDownAll(() => forceDeleteDir(work));

  test('재생시간은 화면 길이를 쓴다(소리가 길어도)', () {
    expect(specs[0].durationSec, closeTo(3.0, 0.02));
  });

  for (final style in [null, TransitionStyle.dissolve]) {
    test('이음매에 화면 멈춤·소리 빈틈이 없다 (${style?.name ?? '효과 없음'})',
        () async {
      final clips = [
        for (var i = 0; i < specs.length; i++) ClipItem(id: '$i', spec: specs[i]),
      ];
      final s = OutputSettings(
        lossless: false,
        width: 640,
        height: 360,
        frameRate: const Rational(30, 1),
        videoBitrate: 1000000,
        useGpu: false,
        smoothTransitions: style != null,
        transitionStyle: style ?? TransitionStyle.dipBlack,
        outputDir: work.path,
        outputName: 'seam_${style?.name ?? 'plain'}',
      );
      final ex = Executor(
        tools: _tools,
        encoders: const EncoderSupport(),
        log: JobLog(File(p.join(work.path, 'seam.log'))),
      );
      final ev = await ex.run(clips, s).toList();
      expect(ev.last.stage, JobStage.done, reason: ev.last.message);
      final v = await _pts(s.outputPath, 'v:0');
      final a = await _pts(s.outputPath, 'a:0');
      final vStep = _maxStep(v), aStep = _maxStep(a);
      printOnFailure('max video step ${vStep * 1000}ms, audio ${aStep * 1000}ms');
      // 한 프레임(33ms) + AAC 한 덩어리(21ms) 정도까지는 남는다.
      expect(vStep, lessThan(0.07));
      // 겹치기에서 소리가 늦게 시작하는 영상은 52ms 가 남는다.
      expect(aStep, lessThan(style == null ? 0.03 : 0.07));
      expect((v.last - a.last).abs(), lessThan(0.06), reason: '끝에서 화면·소리 어긋남');
    }, timeout: const Timeout(Duration(minutes: 3)));
  }
}
