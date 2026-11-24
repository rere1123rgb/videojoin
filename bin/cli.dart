// videojoin 엔진 검증용 CLI. UI 없이 엔진 전체 경로를 돌려본다.
//
//   dart run bin/cli.dart encoders
//   dart run bin/cli.dart maketest testdata
//   dart run bin/cli.dart probe testdata\*.mp4
//   dart run bin/cli.dart plan testdata\same_a.mp4 testdata\uhd_4k.mp4
//   dart run bin/cli.dart join testdata\a.mp4 testdata\b.mp4 --out out.mp4

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:videojoin/engine/encoder_support.dart';
import 'package:videojoin/engine/executor.dart';
import 'package:videojoin/engine/ffmpeg_tools.dart';
import 'package:videojoin/engine/job_log.dart';
import 'package:videojoin/engine/models.dart';
import 'package:videojoin/engine/planner.dart';
import 'package:videojoin/engine/prober.dart';

late FFTools tools;

Future<void> main(List<String> argv) async {
  // 한국어 Windows 콘솔에서 한글이 깨지지 않게 UTF-8 로 고정한다.
  stdout.encoding = utf8;
  stderr.encoding = utf8;

  final found = FFTools.locate();
  if (found == null) {
    print('ffmpeg 을 찾을 수 없습니다. 다음 위치를 확인했습니다:');
    for (final r in FFTools.searchedRoots()) {
      print('  - $r');
    }
    exit(1);
  }
  tools = found;

  if (argv.isEmpty) {
    print('사용법: dart run bin/cli.dart <encoders|maketest|probe|plan|join|verify> ...');
    exit(1);
  }

  final cmd = argv.first;
  final rest = argv.skip(1).toList();

  switch (cmd) {
    case 'encoders':
      await cmdEncoders();
      break;
    case 'maketest':
      await cmdMakeTest(rest.isEmpty ? 'testdata' : rest.first);
      break;
    case 'probe':
      await cmdProbe(rest);
      break;
    case 'plan':
      await cmdPlan(rest);
      break;
    case 'join':
      await cmdJoin(rest);
      break;
    case 'verify':
      await cmdVerify(rest);
      break;
    default:
      print('알 수 없는 명령: $cmd');
      exit(1);
  }
}

Future<void> cmdEncoders() async {
  print('하드웨어 인코더를 실제로 시험 인코딩해서 확인합니다...');
  final sw = Stopwatch()..start();
  final e = await EncoderSupport.detect(tools, force: true);
  sw.stop();

  print('');
  print('  h264_nvenc  ${_yn(e.h264Nvenc)}');
  print('  hevc_nvenc  ${_yn(e.hevcNvenc)}');
  print('  h264_qsv    ${_yn(e.h264Qsv)}');
  print('  hevc_qsv    ${_yn(e.hevcQsv)}');
  print('  h264_amf    ${_yn(e.h264Amf)}');
  print('  hevc_amf    ${_yn(e.hevcAmf)}');
  print('');
  print('  GPU 가속: ${e.anyGpu ? "사용 가능 (${e.gpuLabel})" : "사용 불가 — CPU 인코딩"}');
  print('  H.264 인코더: ${e.encoderFor(CodecChoice.h264, preferGpu: true)}');
  print('  H.265 인코더: ${e.encoderFor(CodecChoice.hevc, preferGpu: true)}');
  print('  (감지 소요 ${sw.elapsedMilliseconds}ms)');
}

String _yn(bool v) => v ? 'O' : '-';

/// 함정 케이스별 테스트 영상을 합성한다.
Future<void> cmdMakeTest(String dir) async {
  final d = Directory(dir);
  if (!d.existsSync()) d.createSync(recursive: true);

  Future<void> run(String label, List<String> args) async {
    stdout.write('  $label ... ');
    final r = await runCaptured(tools.ffmpegPath, ['-hide_banner', '-nostdin', '-y', ...args]);
    if (r.ok) {
      print('OK');
    } else {
      print('실패');
      final tail = r.stderr.trim().split('\n');
      for (final l in tail.skip(tail.length > 6 ? tail.length - 6 : 0)) {
        print('      $l');
      }
    }
  }

  String out(String name) => p.join(dir, name);

  // 공통: 화면에 프레임 번호가 나오는 testsrc2 + 사인파 오디오.
  List<String> basic({
    required String size,
    required String rate,
    required double dur,
    required int freq,
    String vcodec = 'libx264',
    List<String> extra = const [],
  }) =>
      [
        '-f', 'lavfi', '-i', 'testsrc2=s=$size:r=$rate:d=$dur',
        '-f', 'lavfi', '-i', 'sine=f=$freq:d=$dur',
        '-c:v', vcodec, '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
        '-c:a', 'aac', '-b:a', '128k', '-ar', '48000', '-ac', '2',
        ...extra,
      ];

  print('테스트 영상 생성: $dir');

  // 1) 동일 스펙 3개 — 무손실 이어붙이기 경로 검증용
  for (final (name, freq) in [('same_a.mp4', 440), ('same_b.mp4', 550), ('same_c.mp4', 660)]) {
    await run(name, [
      ...basic(size: '1920x1080', rate: '30', dur: 4, freq: freq),
      out(name),
    ]);
  }

  // 2) 4K — 해상도 혼재
  await run('uhd_4k.mp4', [
    ...basic(size: '3840x2160', rate: '30', dur: 4, freq: 700),
    out('uhd_4k.mp4'),
  ]);

  // 3) HDR (BT.2020 + PQ) — 톤매핑 안 하면 색이 빠지는 케이스
  //    주의: ffmpeg 의 -color_trc 만으로는 x265 비트스트림 VUI 에 기록되지
  //    않는다. -x265-params 로 직접 넣어야 ffprobe 가 읽을 수 있다.
  await run('hdr_4k.mp4', [
    '-f', 'lavfi', '-i', 'testsrc2=s=3840x2160:r=30:d=4',
    '-f', 'lavfi', '-i', 'sine=f=800:d=4',
    '-c:v', 'libx265', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p10le',
    '-x265-params', 'colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc',
    '-tag:v', 'hvc1',
    '-c:a', 'aac', '-b:a', '128k', '-ar', '48000', '-ac', '2',
    out('hdr_4k.mp4'),
  ]);

  // 4) 세로 영상 (회전 메타데이터): 1920x1080 으로 저장하고 displaymatrix 에
  //    회전을 박는다. 최신 ffmpeg 은 `-metadata:s:v rotate=90` 을 무시하므로
  //    입력 옵션 `-display_rotation` 을 쓴다(폰 영상처럼 -90 부호).
  await run('_tmp_rot_src.mp4', [
    ...basic(size: '1920x1080', rate: '30', dur: 4, freq: 900),
    out('_tmp_rot_src.mp4'),
  ]);
  await run('portrait_rot90.mp4', [
    '-display_rotation', '-90',
    '-i', out('_tmp_rot_src.mp4'),
    '-c', 'copy',
    out('portrait_rot90.mp4'),
  ]);

  // 4-b) 180도 뒤집혀 저장된 경우 — 사용자 회전 기능 검증용
  await run('bodycam_upside_down.mp4', [
    '-f', 'lavfi', '-i', 'testsrc2=s=1920x1080:r=30:d=4',
    '-f', 'lavfi', '-i', 'sine=f=850:d=4',
    '-vf', 'hflip,vflip',
    '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
    '-c:a', 'aac', '-b:a', '128k', '-ar', '48000', '-ac', '2',
    out('bodycam_upside_down.mp4'),
  ]);

  // 5) 진짜 세로 영상 (메타데이터 없이 세로 해상도)
  await run('portrait_real.mp4', [
    ...basic(size: '1080x1920', rate: '30', dur: 4, freq: 950),
    out('portrait_real.mp4'),
  ]);

  // 6) 오디오 트랙 없음 — 이어붙일 때 소리가 밀리는 고전적 함정
  await run('no_audio.mp4', [
    '-f', 'lavfi', '-i', 'testsrc2=s=1920x1080:r=30:d=4',
    '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
    '-an',
    out('no_audio.mp4'),
  ]);

  // 7) 29.97fps (NTSC) — 30 으로 반올림하면 싱크가 밀리는 케이스
  await run('ntsc_2997.mp4', [
    ...basic(size: '1920x1080', rate: '30000/1001', dur: 4, freq: 1000),
    out('ntsc_2997.mp4'),
  ]);

  // 8) 한글 파일명 + 공백
  await run('한글 영상 테스트.mp4', [
    ...basic(size: '1920x1080', rate: '30', dur: 4, freq: 1100),
    out('한글 영상 테스트.mp4'),
  ]);

  // 9) 구형 AVI (mpeg4 + mp3, 4:3)
  await run('legacy.avi', [
    '-f', 'lavfi', '-i', 'testsrc2=s=640x480:r=30:d=4',
    '-f', 'lavfi', '-i', 'sine=f=1200:d=4',
    '-c:v', 'mpeg4', '-q:v', '5',
    '-c:a', 'libmp3lame', '-b:a', '128k', '-ar', '44100', '-ac', '2',
    out('legacy.avi'),
  ]);

  // 10) 가변 프레임레이트 — 프레임을 불규칙하게 솎아내되 원래 타임스탬프는 유지한다.
  //     여기서 setpts 로 PTS 를 다시 균등하게 만들면 CFR 이 되어버려서
  //     테스트 의미가 없어진다. 반드시 -fps_mode passthrough 로 원본 PTS 를 살린다.
  await run('vfr_phone.mp4', [
    '-f', 'lavfi', '-i', 'testsrc2=s=1280x720:r=60:d=4',
    '-f', 'lavfi', '-i', 'sine=f=1300:d=4',
    '-vf', "select='lt(mod(n\\,7),4)'",
    '-fps_mode', 'passthrough',
    '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
    '-c:a', 'aac', '-b:a', '128k', '-ar', '48000', '-ac', '2',
    out('vfr_phone.mp4'),
  ]);

  // 11) 5.1 채널 오디오 + 44.1kHz — 오디오 규격 혼재
  await run('audio_51.mp4', [
    '-f', 'lavfi', '-i', 'testsrc2=s=1920x1080:r=30:d=4',
    '-f', 'lavfi', '-i', 'sine=f=1400:d=4',
    '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
    '-af', 'aformat=channel_layouts=5.1',
    '-c:a', 'aac', '-b:a', '256k', '-ar', '44100',
    out('audio_51.mp4'),
  ]);

  // 12) 아나모픽 (SAR != 1) — setsar 안 하면 특정 구간만 늘어나 보인다
  await run('anamorphic.mp4', [
    '-f', 'lavfi', '-i', 'testsrc2=s=720x480:r=30:d=4',
    '-f', 'lavfi', '-i', 'sine=f=1500:d=4',
    '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
    '-vf', 'setsar=32/27',
    '-c:a', 'aac', '-b:a', '128k', '-ar', '48000', '-ac', '2',
    out('anamorphic.mp4'),
  ]);

  try {
    File(out('_tmp_rot_src.mp4')).deleteSync();
  } on Object {
    // 무시
  }

  print('');
  print('완료.');
}

Future<void> cmdProbe(List<String> paths) async {
  final files = await _expand(paths);
  if (files.isEmpty) {
    print('파일이 없습니다.');
    return;
  }

  final prober = Prober(tools);
  final specs = await prober.probeAll(files);

  for (final s in specs) {
    print('');
    print('■ ${s.fileName}');
    if (!s.ok) {
      print('   실패: ${s.errorMessage}');
      continue;
    }
    print('   표시 크기   ${s.displayWidth}x${s.displayHeight}  '
        '(${resolutionNickname(s.displayWidth, s.displayHeight)})'
        '${s.isPortrait ? "  [세로]" : ""}');
    if (s.containerRotation != 0) {
      print('   회전        ${s.containerRotation}도  '
          '(원본 저장 크기 ${s.rawWidth}x${s.rawHeight})');
    }
    if (s.hasNonSquarePixels) {
      print('   픽셀비(SAR) ${s.sarNum}:${s.sarDen}  '
          '(저장 ${s.rawWidth}x${s.rawHeight} → 실제 표시 '
          '${s.displayWidth}x${s.displayHeight})');
    }
    print('   프레임      ${s.frameRate.detailLabel}'
        '${s.isVfr ? "  [가변 프레임레이트 — r=${s.rFrameRate.label}]" : ""}');
    print('   길이        ${formatDuration(s.durationSec)}  '
        '(${s.durationSec.toStringAsFixed(3)}초)');
    print('   코덱        ${s.videoCodec} / ${s.pixFmt}');
    print('   비트레이트  ${formatBitrate(s.estimatedVideoBitrate)} (영상)  '
        '· 파일 ${formatBytes(s.fileSize)}');
    print('   색공간      trc=${s.colorTransfer ?? "-"} '
        'pri=${s.colorPrimaries ?? "-"} spc=${s.colorSpace ?? "-"}'
        '${s.isHdr ? "   ★ ${s.hdrKind}" : ""}');
    print('   소리        ${s.hasAudio ? "${s.audioCodec} "
        "${s.audioSampleRate}Hz ${s.audioChannels}ch" : "없음"}');
    print('   만든 날짜   ${_fmtDate(s.createdDate)}'
        '${s.createdDateIsFallback ? "  (메타데이터 없음 → 파일 생성일)" : "  (촬영 메타데이터)"}');
    print('   수정한 날짜 ${_fmtDate(s.fileModified)}');
  }
}

Future<void> cmdPlan(List<String> paths) async {
  final clips = await _loadClips(paths);
  if (clips.isEmpty) return;

  final plan = JobPlan.analyze(clips);

  print('');
  print('입력 ${clips.length}개 · 총 ${formatDurationKorean(plan.totalDuration)} '
      '· 원본 합계 ${formatBytes(plan.totalInputBytes)}');
  print('');

  if (plan.losslessPossible) {
    print('◆ 그대로 이어붙이기 가능 (재인코딩 없음, 화질 손실 0)');
    print('  예상 용량 ${formatBytes(plan.totalInputBytes)}');
  } else {
    print('◆ 다시 만들어야 함');
    print('  이유: ${plan.losslessBlockedReason}');
  }

  print('');
  print('해상도(화면 크기)');
  for (final r in plan.resolutions) {
    print('  ${r == plan.defaultResolution ? "●" : "○"} '
        '${r.label.padRight(13)} ${r.nickname.padRight(9)} ${r.note}');
  }

  print('');
  print('프레임레이트(초당 화면 수)');
  for (final f in plan.frameRates) {
    print('  ${f == plan.defaultFps ? "●" : "○"} '
        '${f.label.padRight(13)} ${f.note}');
  }

  final res = plan.defaultResolution;
  final fps = plan.defaultFps;
  print('');
  print('비트레이트(화질)  — ${res.label} ${fps.label} 기준');
  final opts = plan.bitrateOptions(res.width, res.height, fps.fps, CodecChoice.h264);
  for (var i = 0; i < opts.length; i++) {
    final o = opts[i];
    final s = OutputSettings(
      lossless: false,
      width: res.width,
      height: res.height,
      frameRate: fps.fps,
      videoBitrate: o.bps,
      outputDir: '.',
      outputName: 'x',
    );
    print('  ${i == 0 ? "●" : "○"} ${o.title.padRight(9)} '
        '${o.label.padRight(11)} ${formatBytes(plan.estimateOutputBytes(s)).padRight(10)} '
        '${o.note}');
  }

  if (plan.warnings.isNotEmpty) {
    print('');
    print('알림');
    for (final w in plan.warnings) {
      final mark = switch (w.level) {
        WarningLevel.error => '✕',
        WarningLevel.caution => '!',
        WarningLevel.info => '·',
      };
      print('  $mark ${w.message}');
      if (w.detail != null) print('      ${w.detail}');
    }
  }

  // 필터 체인을 눈으로 확인할 수 있게 출력한다.
  print('');
  print('생성될 필터 체인');
  final settings = OutputSettings(
    lossless: false,
    width: res.width,
    height: res.height,
    frameRate: fps.fps,
    videoBitrate: opts.first.bps,
    outputDir: '.',
    outputName: 'x',
  );
  for (final c in clips.where((c) => c.spec.ok)) {
    print('  ${c.spec.fileName}');
    print('    ${Executor.buildFilterChain(c, settings)}');
  }
}

Future<void> cmdJoin(List<String> argv) async {
  final paths = <String>[];
  String? outPath;
  bool? forceLossless;
  int? width, height, bitrate;
  var codec = CodecChoice.h264;
  var fit = FitMode.pad;
  var gpu = true;
  int? cancelAfter;
  final rotations = <int, int>{};

  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    switch (a) {
      case '--out':
        outPath = argv[++i];
        break;
      case '--lossless':
        forceLossless = true;
        break;
      case '--reencode':
        forceLossless = false;
        break;
      case '--size':
        final parts = argv[++i].split('x');
        width = int.parse(parts[0]);
        height = int.parse(parts[1]);
        break;
      case '--bitrate':
        bitrate = (double.parse(argv[++i]) * 1000000).round();
        break;
      case '--hevc':
        codec = CodecChoice.hevc;
        break;
      case '--crop':
        fit = FitMode.crop;
        break;
      case '--nogpu':
        gpu = false;
        break;
      case '--cancel-after':
        // 취소 → 이어하기 검증용. N초 뒤에 UI 의 취소 버튼과 같은 경로를 탄다.
        cancelAfter = int.parse(argv[++i]);
        break;
      case '--rotate':
        // --rotate 2:180  → 3번째 파일(0-based 2)을 180도 회전
        final parts = argv[++i].split(':');
        rotations[int.parse(parts[0])] = int.parse(parts[1]);
        break;
      default:
        paths.add(a);
    }
  }

  if (outPath == null) {
    print('--out <경로> 가 필요합니다.');
    exit(1);
  }

  final clips = await _loadClips(paths);
  if (clips.isEmpty) return;

  rotations.forEach((i, deg) {
    if (i >= 0 && i < clips.length) clips[i].userRotation = deg;
  });

  final plan = JobPlan.analyze(clips);
  final encoders = await EncoderSupport.detect(tools);

  final lossless = forceLossless ?? plan.losslessPossible;
  if (lossless && !plan.losslessPossible) {
    print('경고: 무손실 이어붙이기가 불가능한 조합입니다 — ${plan.losslessBlockedReason}');
    exit(1);
  }

  final res = plan.defaultResolution;
  final fps = plan.defaultFps;
  final bopts = plan.bitrateOptions(
      width ?? res.width, height ?? res.height, fps.fps, codec);

  final settings = OutputSettings(
    lossless: lossless,
    width: width ?? res.width,
    height: height ?? res.height,
    frameRate: fps.fps,
    videoBitrate: bitrate ?? bopts.first.bps,
    codec: codec,
    fitMode: fit,
    useGpu: gpu && encoders.anyGpu,
    outputDir: p.dirname(p.absolute(outPath)),
    outputName: p.basenameWithoutExtension(outPath),
  );

  print('');
  print('모드      ${lossless ? "그대로 이어붙이기 (재인코딩 없음)" : "다시 만들기"}');
  if (!lossless) {
    print('규격      ${settings.width}x${settings.height} ${settings.frameRate.label} '
        '${formatBitrate(settings.videoBitrate)} ${settings.codec.label}');
    print('인코더    ${encoders.encoderFor(settings.codec, preferGpu: settings.useGpu)}');
  }
  print('예상 용량 ${formatBytes(plan.estimateOutputBytes(settings))}');
  print('출력      ${settings.outputPath}');
  print('');

  final log = JobLog.create();
  final exec = Executor(tools: tools, encoders: encoders, log: log);

  if (cancelAfter != null) {
    Future.delayed(Duration(seconds: cancelAfter), () {
      print('');
      print('>>> $cancelAfter초 경과 — 취소 요청');
      exec.cancel();
    });
  }

  final sw = Stopwatch()..start();
  var lastLine = 0;

  await for (final prog in exec.run(clips, settings)) {
    if (prog.isTerminal) {
      sw.stop();
      print('');
      switch (prog.stage) {
        case JobStage.done:
          final f = File(prog.outputPath!);
          print('완료: ${prog.outputPath}');
          print('용량: ${formatBytes(f.lengthSync())}  '
              '(예상 ${formatBytes(plan.estimateOutputBytes(settings))})');
          final err = (f.lengthSync() - plan.estimateOutputBytes(settings)) /
              plan.estimateOutputBytes(settings) * 100;
          print('예측 오차: ${err.toStringAsFixed(1)}%');
          print('소요: ${sw.elapsed.inSeconds}초');
          break;
        case JobStage.failed:
          print('실패: ${prog.message}');
          if (prog.errorMessage != null) print('       ${prog.errorMessage}');
          print('로그: ${log.file.path}');
          exitCode = 1;
          break;
        case JobStage.cancelled:
          print('취소됨');
          break;
        default:
          break;
      }
      break;
    }

    final pct = (prog.progress * 100).toStringAsFixed(1).padLeft(5);
    final line = '[$pct%] ${prog.stage.label}  ${prog.message}'
        '${prog.speed != null ? "  ${prog.speed!.toStringAsFixed(1)}x" : ""}'
        '${prog.remaining != null ? "  남은 ${prog.remaining!.inSeconds}초" : ""}'
        '${prog.estimatedBytes != null ? "  실측예상 ${formatBytes(prog.estimatedBytes!)}" : ""}';
    stdout.write('\r${' ' * lastLine}\r$line');
    lastLine = line.length;
  }
  print('');
  print('로그: ${log.file.path}');
}

/// 결과 파일이 기대대로 나왔는지 확인한다.
Future<void> cmdVerify(List<String> paths) async {
  final files = await _expand(paths);
  final prober = Prober(tools);
  for (final f in files) {
    final s = await prober.probe(f);
    if (!s.ok) {
      print('✕ ${s.fileName}: ${s.errorMessage}');
      continue;
    }
    print('${s.fileName}');
    print('   ${s.displayWidth}x${s.displayHeight} ${s.frameRate.label} '
        '${formatDuration(s.durationSec)} ${formatBytes(s.fileSize)} '
        '${s.videoCodec}/${s.hasAudio ? "${s.audioCodec} ${s.audioChannels}ch" : "무음"}');
  }
}

Future<List<ClipItem>> _loadClips(List<String> paths) async {
  final files = await _expand(paths);
  if (files.isEmpty) {
    print('파일이 없습니다.');
    return [];
  }
  final prober = Prober(tools);
  final specs = await prober.probeAll(files);
  return [
    for (var i = 0; i < specs.length; i++) ClipItem(id: '$i', spec: specs[i]),
  ];
}

/// 와일드카드와 디렉터리를 펼친다.
Future<List<String>> _expand(List<String> args) async {
  final result = <String>[];
  for (final a in args) {
    final dir = Directory(a);
    if (dir.existsSync()) {
      final files = dir
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .where(isVideoFile)
          .toList()
        ..sort(naturalCompare);
      result.addAll(files);
      continue;
    }
    if (a.contains('*')) {
      final parent = p.dirname(a);
      final pattern = p.basename(a).replaceAll('.', r'\.').replaceAll('*', '.*');
      final re = RegExp('^$pattern\$', caseSensitive: false);
      final d = Directory(parent);
      if (d.existsSync()) {
        final files = d
            .listSync()
            .whereType<File>()
            .where((f) => re.hasMatch(p.basename(f.path)))
            .map((f) => f.path)
            .toList()
          ..sort(naturalCompare);
        result.addAll(files);
      }
      continue;
    }
    if (File(a).existsSync()) result.add(a);
  }
  return result;
}

String _fmtDate(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}
