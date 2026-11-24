// 편집이 실제 결과물에 그대로 반영되는지, 진짜 ffmpeg 으로 만들어 보고
// ffprobe 로 잰다. 단위 테스트는 명령줄 모양만 확인할 뿐이라
// "자른 길이만큼 정확히 나오는가", "소리와 화면이 어긋나지 않는가"는
// 직접 만들어 봐야 안다.
//
//   flutter test test/edit_render_e2e_test.dart

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

Future<Map<String, dynamic>> _probe(String path) async {
  final r = await Process.run(_tools.ffprobePath, [
    '-v', 'error',
    '-show_entries', 'format=duration:stream=codec_type,duration',
    '-of', 'json',
    path,
  ], stdoutEncoding: utf8);
  return jsonDecode(r.stdout as String) as Map<String, dynamic>;
}

/// 구간 [start, start+len) 의 평균 음량(dB). 무음이면 -91 근처.
Future<double> _meanVolume(String path, double start, double len) async {
  final r = await Process.run(_tools.ffmpegPath, [
    '-hide_banner', '-nostdin',
    '-ss', '$start', '-t', '$len',
    '-i', path,
    '-af', 'volumedetect',
    '-f', 'null', '-',
  ], stderrEncoding: utf8);
  final m = RegExp(r'mean_volume: (-?[\d.]+) dB')
      .firstMatch(r.stderr as String);
  return m == null ? -999 : double.parse(m.group(1)!);
}

/// 시각 t 의 평균 밝기(Y, 0~255).
Future<double> _meanLuma(String path, double t) async {
  final r = await Process.run(_tools.ffmpegPath, [
    '-hide_banner', '-nostdin',
    '-ss', '$t', '-i', path,
    '-frames:v', '1',
    '-vf', 'signalstats,metadata=print:key=lavfi.signalstats.YAVG',
    '-f', 'null', '-',
  ], stderrEncoding: utf8);
  final m = RegExp(r'YAVG=([\d.]+)').firstMatch(r.stderr as String);
  return m == null ? -1 : double.parse(m.group(1)!);
}

void main() {
  late Directory work;

  setUpAll(() {
    work = Directory.systemTemp.createTempSync('vj_edit_e2e_');
  });
  tearDownAll(() => forceDeleteDir(work));

  test('자르기·중간 빼기·소리·밝기·부드럽게 넘기기가 결과물에 맞게 나온다', () async {
    final prober = Prober(_tools);
    final specs = await prober.probeAll([
      p.join(_root, 'testdata', 'same_a.mp4'),
      p.join(_root, 'testdata', 'same_b.mp4'),
      p.join(_root, 'testdata', 'no_audio.mp4'),
    ]);
    expect(specs.every((s) => s.ok), isTrue);

    final clips = [
      ClipItem(
        id: 'a',
        spec: specs[0],
        edit: const ClipEdit(
          keep: [TimeRange(0.5, 3.5)],
          brightness: BrightnessLevel.brightest,
        ),
      ),
      ClipItem(
        id: 'b',
        spec: specs[1],
        edit: const ClipEdit(
          keep: [TimeRange(0, 1.2), TimeRange(2.4, 4)],
          volume: VolumeLevel.mute,
        ),
      ),
      ClipItem(id: 'c', spec: specs[2]),
    ];
    final expected = 3.0 + 1.2 + 1.6 + specs[2].durationSec;

    final plan = JobPlan.analyze(clips, smoothTransitions: true);
    expect(plan.losslessPossible, isFalse);

    final settings = OutputSettings(
      lossless: false,
      width: 1280,
      height: 720,
      frameRate: const Rational(30, 1),
      videoBitrate: 4000000,
      useGpu: false,
      smoothTransitions: true,
      outputDir: work.path,
      outputName: 'edited',
    );

    final ex = Executor(
      tools: _tools,
      encoders: const EncoderSupport(),
      log: JobLog(File(p.join(work.path, 'job.log'))),
    );
    final events = await ex.run(clips, settings).toList();
    final last = events.last;
    expect(last.stage, JobStage.done,
        reason: '${last.message} ${last.errorMessage ?? ''}\n'
            '${File(p.join(work.path, 'job.log')).readAsStringSync()}');

    final out = settings.outputPath;
    final info = await _probe(out);
    final dur = double.parse(info['format']['duration'] as String);
    // 프레임 단위 반올림과 AAC 프레임(약 21ms)만큼은 어긋날 수 있다.
    expect(dur, closeTo(expected, 0.25), reason: 'total duration');

    final streams = (info['streams'] as List).cast<Map>();
    final v = streams.firstWhere((s) => s['codec_type'] == 'video');
    final a = streams.firstWhere((s) => s['codec_type'] == 'audio',
        orElse: () => {});
    expect(a, isNotEmpty, reason: '소리를 끈 영상이 있어도 오디오 트랙은 있어야 한다');
    final vd = double.parse(v['duration'] as String);
    final ad = double.parse(a['duration'] as String);
    expect((vd - ad).abs(), lessThan(0.15), reason: '화면 $vd, 소리 $ad');

    // 진행률은 자른 길이 기준이라 끝에서 1 에 닿아야 한다.
    final maxNormProgress = events
        .where((e) => e.stage == JobStage.normalizing)
        .fold<double>(0, (m, e) => e.progress > m ? e.progress : m);
    expect(maxNormProgress, closeTo(0.88, 0.02));

    // 소리를 끈 b 구간(결과물 3.0~5.8초)은 조용해야 하고, a 구간은 소리가 있어야 한다.
    final muted = await _meanVolume(out, 3.6, 1.5);
    final loud = await _meanVolume(out, 0.5, 1.5);
    printOnFailure('mean volume: a=$loud b(muted)=$muted');
    expect(muted, greaterThan(-200), reason: '측정 실패');
    expect(muted, lessThan(-60), reason: 'muted=$muted');
    expect(loud, greaterThan(-50), reason: 'loud=$loud');

    // 이음매(a 끝 = 3.0초)는 검게 어두워진다.
    final dip = await _meanLuma(out, 2.97);
    final mid = await _meanLuma(out, 1.5);
    printOnFailure('luma: seam=$dip mid=$mid');
    expect(mid, greaterThan(10), reason: '측정 실패');
    expect(dip, greaterThanOrEqualTo(0), reason: '측정 실패');
    expect(dip, lessThan(mid * 0.35), reason: 'dip=$dip mid=$mid');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('흰 화면 전환 + 처음·끝 서서히: 이음매와 양 끝이 하얗고 길이는 그대로', () async {
    final specs = await Prober(_tools).probeAll([
      p.join(_root, 'testdata', 'same_a.mp4'),
      p.join(_root, 'testdata', 'same_b.mp4'),
    ]);
    expect(specs.every((s) => s.ok), isTrue);
    final clips = [
      ClipItem(id: 'a', spec: specs[0]),
      ClipItem(id: 'b', spec: specs[1]),
    ];
    final expected = specs[0].durationSec + specs[1].durationSec;
    final s = OutputSettings(
      lossless: false,
      width: 640,
      height: 360,
      frameRate: const Rational(30, 1),
      videoBitrate: 2000000,
      useGpu: false,
      smoothTransitions: true,
      transitionStyle: TransitionStyle.dipWhite,
      fadeEnds: true,
      outputDir: work.path,
      outputName: 'white_ends',
    );
    final ex = Executor(
      tools: _tools,
      encoders: const EncoderSupport(),
      log: JobLog(File(p.join(work.path, 'white_ends.log'))),
    );
    final ev = await ex.run(clips, s).toList();
    expect(ev.last.stage, JobStage.done,
        reason: '${ev.last.message} ${ev.last.errorMessage ?? ''}');

    final out = s.outputPath;
    final info = await _probe(out);
    final dur = double.parse(info['format']['duration'] as String);
    final streams = (info['streams'] as List).cast<Map>();
    final vd = double.parse(
        streams.firstWhere((x) => x['codec_type'] == 'video')['duration']
            as String);
    final ad = double.parse(
        streams.firstWhere((x) => x['codec_type'] == 'audio')['duration']
            as String);

    final seam = specs[0].durationSec;
    final start = await _meanLuma(out, 0.03);
    final atSeam = await _meanLuma(out, seam - 0.02);
    final afterSeam = await _meanLuma(out, seam + 0.02);
    final end = await _meanLuma(out, dur - 0.08);
    final mid = await _meanLuma(out, 2.0);
    final mid2 = await _meanLuma(out, seam + 2.0);
    // 실측 값을 로그로 남긴다.
    // ignore: avoid_print
    print('white e2e: dur=$dur expected=$expected v=$vd a=$ad '
        'start=$start seam-=$atSeam seam+=$afterSeam end=$end mid=$mid mid2=$mid2');

    expect(dur, closeTo(expected, 0.25), reason: 'total duration');
    expect((vd - ad).abs(), lessThan(0.12), reason: '화면 $vd, 소리 $ad');
    expect(start, greaterThan(200), reason: 'start=$start');
    expect(atSeam, greaterThan(200), reason: 'atSeam=$atSeam');
    expect(afterSeam, greaterThan(200), reason: 'afterSeam=$afterSeam');
    expect(end, greaterThan(200), reason: 'end=$end');
    expect(mid, lessThan(190), reason: 'mid=$mid');
    expect(mid2, lessThan(190), reason: 'mid2=$mid2');
    expect(mid, greaterThan(10), reason: '측정 실패');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('밝기 단계를 올리면 실제로 밝아진다', () async {
    final spec = await Prober(_tools).probe(p.join(_root, 'testdata', 'same_a.mp4'));
    Future<double> render(BrightnessLevel b) async {
      final clip = ClipItem(id: b.name, spec: spec, edit: ClipEdit(brightness: b));
      final s = OutputSettings(
        lossless: false,
        width: 640,
        height: 360,
        frameRate: const Rational(30, 1),
        videoBitrate: 2000000,
        useGpu: false,
        outputDir: work.path,
        outputName: 'b_${b.name}',
      );
      final ex = Executor(
        tools: _tools,
        encoders: const EncoderSupport(),
        log: JobLog(File(p.join(work.path, 'b_${b.name}.log'))),
      );
      final ev = await ex.run([clip], s).toList();
      expect(ev.last.stage, JobStage.done);
      return _meanLuma(s.outputPath, 2.0);
    }

    final dark = await render(BrightnessLevel.darker);
    final normal = await render(BrightnessLevel.normal);
    final bright = await render(BrightnessLevel.brightest);
    printOnFailure('luma: dark=$dark normal=$normal bright=$bright');
    expect(normal, greaterThan(0), reason: '측정 실패');
    expect(dark, lessThan(normal), reason: 'dark=$dark normal=$normal');
    expect(bright, greaterThan(normal), reason: 'bright=$bright normal=$normal');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('편집 화면 장면 뽑기: 같은 시각은 캐시, 끝 시각도 실패하지 않는다', () async {
    final spec = await Prober(_tools).probe(p.join(_root, 'testdata', 'same_a.mp4'));
    final g = FrameGrabber(_tools);
    final f1 = await g.frameAt(spec, 1.0, width: 320);
    expect(f1, isNotNull);
    final f2 = await g.frameAt(spec, spec.durationSec, width: 320);
    expect(f2, isNotNull);
    final strip = await g.filmstrip(spec, 6, width: 120);
    expect(strip.where((s) => s != null).length, 6);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
