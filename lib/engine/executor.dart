import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'encoder_support.dart';
import 'ffmpeg_tools.dart';
import 'fs_util.dart';
import 'job_log.dart';
import 'models.dart';
import 'planner.dart';
import 'suspend.dart';
import 'transitions.dart';

enum JobStage {
  preparing('준비 중'),
  normalizing('영상 변환 중'),
  remuxing('영상 준비 중'),
  joining('이어붙이는 중'),
  finalizing('마무리 중'),
  done('완료'),
  cancelled('취소됨'),
  failed('실패');

  final String label;
  const JobStage(this.label);
}

class JobProgress {
  final JobStage stage;

  /// 0.0 ~ 1.0
  final double progress;

  /// 현재 처리 중인 파일 순번 (1부터).
  final int fileIndex;
  final int fileCount;
  final String currentFile;

  /// ffmpeg 이 보고하는 실시간 대비 배속.
  final double? speed;

  final Duration? remaining;
  final String message;
  final String? errorMessage;
  final String? outputPath;

  /// 지금까지 쓰인 바이트로 역산한 최종 용량 예상치. VBR 은 목표 비트레이트를 다 쓰지
  /// 않아 사전 예측(비트레이트 × 시간)이 크게 나오므로 이 값으로 대체한다.
  final int? estimatedBytes;

  const JobProgress({
    required this.stage,
    required this.progress,
    this.fileIndex = 0,
    this.fileCount = 0,
    this.currentFile = '',
    this.speed,
    this.remaining,
    this.message = '',
    this.errorMessage,
    this.outputPath,
    this.estimatedBytes,
  });

  bool get isTerminal =>
      stage == JobStage.done || stage == JobStage.cancelled || stage == JobStage.failed;
}

class JobCancelledException implements Exception {}

class JobFailure implements Exception {
  final String message;
  final String? detail;
  JobFailure(this.message, {this.detail});
  @override
  String toString() => message;
}

/// 실제 인코딩을 수행한다.
///
/// ## 왜 concat 필터를 안 쓰는가
/// `-filter_complex concat` 한 방 대신 **파일별 정규화 → 스트림 복사로 이어붙이기** 2단계로 간다.
///  1. Windows 명령줄은 약 32KB 제한이라 영상이 많으면 한 명령에 담을 수 없다.
///  2. 파일별 진행률을 뽑을 수 없다.
///  3. 오디오 없는 파일이 섞이면 필터 그래프 전체가 실패한다.
///  4. 중간에 끊기면 처음부터 다시 해야 한다.
/// 중간 파일명을 000.ts 처럼 직접 지으므로 한글·공백·따옴표 파일명 문제도 없다.
class Executor {
  final FFTools tools;
  final EncoderSupport encoders;
  final JobLog log;

  Process? _current;
  bool _cancelled = false;

  bool _paused = false;
  DateTime? _pausedAt;
  Duration _pausedTotal = Duration.zero;

  Executor({required this.tools, required this.encoders, required this.log});

  Future<void> cancel() async {
    _cancelled = true;
    // 얼어 있으면 종료 처리가 진행되지 않으므로 먼저 녹인다.
    resume();
    final proc = _current;
    if (proc != null) {
      proc.kill(ProcessSignal.sigkill);
    }
  }

  bool get isCancelled => _cancelled;

  bool get isPaused => _paused;

  /// 돌고 있는 ffmpeg 을 그 자리에서 멈춘다. [resume] 하면 이어서 계속된다.
  void pause() {
    if (_paused || _cancelled) return;
    _paused = true;
    _pausedAt = DateTime.now();
    final proc = _current;
    if (proc != null) {
      log.line('일시정지 (pid ${proc.pid})');
      ProcessFreezer.freeze(proc.pid);
    }
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    final at = _pausedAt;
    if (at != null) _pausedTotal += DateTime.now().difference(at);
    _pausedAt = null;
    final proc = _current;
    if (proc != null) {
      log.line('다시 시작 (pid ${proc.pid})');
      ProcessFreezer.thaw(proc.pid);
    }
  }

  /// 지금까지 멈춰 있던 시간의 합. 남은 시간 계산에서 빼야 일시정지 후 값이 부풀지 않는다.
  Duration get pausedElapsed {
    final at = _pausedAt;
    if (at == null) return _pausedTotal;
    return _pausedTotal + DateTime.now().difference(at);
  }

  Stream<JobProgress> run(List<ClipItem> clips, OutputSettings settings) {
    final controller = StreamController<JobProgress>();
    _runInternal(clips, settings, controller).whenComplete(() {
      controller.close();
    });
    return controller.stream;
  }

  Future<void> _runInternal(
    List<ClipItem> clips,
    OutputSettings settings,
    StreamController<JobProgress> out,
  ) async {
    final valid = clips.where((c) => c.spec.ok).toList();
    Directory? jobDir;

    try {
      if (valid.isEmpty) {
        throw JobFailure('이어붙일 영상이 없습니다.');
      }

      out.add(const JobProgress(
        stage: JobStage.preparing,
        progress: 0,
        message: '준비하고 있습니다',
      ));

      final outDir = Directory(settings.outputDir);
      if (!outDir.existsSync()) {
        try {
          outDir.createSync(recursive: true);
        } on Object {
          throw JobFailure('저장할 폴더를 만들 수 없습니다.',
              detail: settings.outputDir);
        }
      }

      // 입력 파일을 덮어쓰지 않게 막는다.
      final outPath = p.normalize(settings.outputPath);
      for (final c in valid) {
        if (p.equals(p.normalize(c.spec.path), outPath)) {
          throw JobFailure('저장할 파일 이름이 원본 영상과 같습니다.',
              detail: '다른 이름을 지정해 주세요.');
        }
      }

      // 출력 폴더와 같은 드라이브에 둬야 미리 계산한 여유 공간이 맞는다.
      jobDir = Directory(p.join(
        settings.outputDir,
        '.videojoin_temp',
        _jobId(valid, settings),
      ));
      if (!jobDir.existsSync()) jobDir.createSync(recursive: true);

      log.section('작업 시작');
      log.line('입력 ${valid.length}개, 총 ${formatDuration(outputDurationFor(valid, settings))}');
      for (final c in valid.where((c) => !c.edit.isDefault)) {
        log.line('  손질: ${c.spec.fileName} '
            '[${c.ranges.map((r) => '${r.start.toStringAsFixed(2)}~${r.end.toStringAsFixed(2)}').join(', ')}] '
            '소리 ${c.edit.volume.label}, 밝기 ${c.edit.brightness.label}');
      }
      if (settings.smoothTransitions) {
        log.line('영상 사이 부드럽게 넘기기: 켬 '
            '(${settings.transitionStyle.label}, ${settings.transitionLength.label})');
      }
      if (settings.fadeEnds) log.line('맨 처음과 맨 끝 서서히: 켬');
      log.line('모드: ${settings.lossless ? "무손실 이어붙이기" : "다시 만들기"}');
      if (!settings.lossless) {
        log.line('규격: ${settings.width}x${settings.height} '
            '${settings.frameRate.toFFmpegArg()} '
            '${formatBitrate(settings.videoBitrate)} ${settings.codec.label}');
      }
      log.line('출력: $outPath');
      log.line('작업 폴더: ${jobDir.path}');

      // 1단계: 조각별 정규화. 조각마다 완료 표시를 남겨 끊긴 조각부터 이어진다.
      final units = buildUnits(valid, settings);
      // 겹치기 전환이면 전환 조각이 끼므로 조각 길이를 합해 전체를 낸다.
      final totalDuration = units.fold<double>(0, (a, u) => a + u.duration);
      final segments = <String>[];
      var doneDuration = 0.0;
      var doneBytes = 0;
      final started = DateTime.now();

      // GPU 인코딩이 런타임에 실패하면 CPU 로 내려간다.
      var useGpu = settings.useGpu;

      for (var u = 0; u < units.length; u++) {
        if (_cancelled) throw JobCancelledException();

        final unit = units[u];
        final clip = unit.clip;
        final i = unit.clipIndex;
        final unitDur = unit.duration;
        final segName = '${u.toString().padLeft(3, '0')}.ts';
        final segPath = p.join(jobDir.path, segName);
        final markPath = '$segPath.done';

        segments.add(segName);

        // 이어하기: 완료 표시가 있는 조각은 건너뛴다. 중간에 죽은 .ts 는 존재해도
        // 잘려 있으므로 파일 존재 여부만으로 판단하면 안 된다.
        if (File(markPath).existsSync() && File(segPath).existsSync()) {
          doneDuration += unitDur;
          doneBytes += File(segPath).lengthSync();
          log.line('[$u] 이미 완료됨, 건너뜀: ${clip.spec.fileName}');
          continue;
        }

        final stage = settings.lossless ? JobStage.remuxing : JobStage.normalizing;

        void emit(double innerProgress, double? speed, int currentBytes) {
          final processed = doneDuration + unitDur * innerProgress;
          final ratio = totalDuration <= 0 ? 0.0 : processed / totalDuration;

          // 쓴 바이트 / 처리한 시간으로 최종 용량을 역산한다. 최소 2초는 처리해야 의미가 있다.
          int? estimate;
          final writtenSoFar = doneBytes + currentBytes;
          if (processed > 2 && writtenSoFar > 0 && totalDuration > 0) {
            estimate = (writtenSoFar / processed * totalDuration).round();
          }

          out.add(JobProgress(
            stage: stage,
            progress: (ratio * 0.88).clamp(0.0, 0.88),
            fileIndex: i + 1,
            fileCount: valid.length,
            currentFile: clip.spec.fileName,
            speed: speed,
            // 멈춰 있던 시간만큼 시작 시각을 미룬다.
            remaining: _estimateRemaining(
                started.add(pausedElapsed), processed, totalDuration),
            message: '${i + 1} / ${valid.length}  ${clip.spec.fileName}',
            estimatedBytes: estimate,
          ));
        }

        emit(0, null, 0);

        var attemptGpu = useGpu;
        while (true) {
          final args = settings.lossless
              ? _remuxArgs(clip, segPath)
              : normalizeArgs(unit, settings, segPath,
                  encoder: encoders.encoderFor(settings.codec,
                      preferGpu: attemptGpu));

          final result = await _runFFmpeg(
            args,
            workingDirectory: jobDir.path,
            onProgress: (us, speed, totalSize) {
              final sec = us / 1000000.0;
              final inner = unitDur <= 0 ? 0.0 : (sec / unitDur);
              emit(inner.clamp(0.0, 1.0), speed, totalSize);
            },
          );

          if (_cancelled) throw JobCancelledException();

          if (result.ok) break;

          // 드라이버 문제나 동시 세션 제한으로 GPU 인코딩이 실패하면 CPU 로 재시도한다.
          if (attemptGpu && _looksLikeGpuFailure(result.stderr)) {
            log.line('[$u] GPU 인코딩 실패 → CPU 로 전환하여 재시도');
            log.ffmpegOutput(result.stderr);
            attemptGpu = false;
            useGpu = false;
            continue;
          }

          log.line('[$u] 실패: ${clip.spec.fileName}');
          log.command(tools.ffmpegPath, args, cwd: jobDir.path);
          log.ffmpegOutput(result.stderr);
          throw JobFailure(
            _friendlyError(result.stderr, clip.spec.fileName),
            detail: clip.spec.fileName,
          );
        }

        File(markPath).writeAsStringSync('ok', encoding: utf8, flush: true);
        doneDuration += unitDur;
        doneBytes += File(segPath).existsSync() ? File(segPath).lengthSync() : 0;
        emit(1, null, 0);
      }

      if (_cancelled) throw JobCancelledException();

      // 2단계: 이어붙이기. concat 목록에는 ASCII 상대 경로만 쓴다 (목록 파일 기준으로 해석된다).
      final listFile = File(p.join(jobDir.path, 'list.txt'));
      final sb = StringBuffer();
      for (final s in segments) {
        sb.writeln("file '$s'");
      }
      listFile.writeAsStringSync(sb.toString(), encoding: utf8, flush: true);

      out.add(JobProgress(
        stage: JobStage.joining,
        progress: 0.9,
        fileCount: valid.length,
        message: '영상을 하나로 이어붙이고 있습니다',
      ));

      final joinArgs = _joinArgs(settings, outPath);
      final joinResult = await _runFFmpeg(
        joinArgs,
        workingDirectory: jobDir.path,
        onProgress: (us, speed, totalSize) {
          final sec = us / 1000000.0;
          final r = totalDuration <= 0 ? 0.0 : (sec / totalDuration);
          out.add(JobProgress(
            stage: JobStage.joining,
            progress: (0.9 + r.clamp(0.0, 1.0) * 0.08).clamp(0.0, 0.98),
            fileCount: valid.length,
            speed: speed,
            message: '영상을 하나로 이어붙이고 있습니다',
            estimatedBytes: doneBytes > 0 ? doneBytes : null,
          ));
        },
      );

      if (_cancelled) throw JobCancelledException();

      if (!joinResult.ok) {
        log.line('이어붙이기 실패');
        log.command(tools.ffmpegPath, joinArgs, cwd: jobDir.path);
        log.ffmpegOutput(joinResult.stderr);
        throw JobFailure(_friendlyError(joinResult.stderr, ''));
      }

      out.add(JobProgress(
        stage: JobStage.finalizing,
        progress: 0.99,
        message: '마무리하고 있습니다',
      ));

      final outFile = File(outPath);
      if (!outFile.existsSync() || outFile.lengthSync() < 1024) {
        throw JobFailure('결과 파일이 만들어지지 않았습니다.');
      }

      log.line('완료: $outPath (${formatBytes(outFile.lengthSync())})');

      out.add(JobProgress(
        stage: JobStage.done,
        progress: 1,
        fileCount: valid.length,
        message: '완료되었습니다',
        outputPath: outPath,
      ));

      _cleanup(jobDir);
      jobDir = null;
    } on JobCancelledException {
      log.line('사용자가 취소함');
      // 작업 폴더는 남겨 다시 시작하면 이어서 진행되게 한다.
      out.add(const JobProgress(
        stage: JobStage.cancelled,
        progress: 0,
        message: '취소되었습니다',
      ));
    } on JobFailure catch (e) {
      log.line('실패: ${e.message} ${e.detail ?? ''}');
      out.add(JobProgress(
        stage: JobStage.failed,
        progress: 0,
        message: e.message,
        errorMessage: e.detail,
      ));
    } catch (e, st) {
      log.line('예기치 못한 오류: $e');
      log.line(st.toString());
      out.add(JobProgress(
        stage: JobStage.failed,
        progress: 0,
        message: '예기치 못한 오류가 발생했습니다.',
        errorMessage: e.toString(),
      ));
    } finally {
      await log.close();
      _current = null;
    }
  }

  /// 무손실 경로: 재인코딩 없이 컨테이너만 MPEG-TS 로 바꾼다.
  /// mp4 를 그대로 concat 하면 편집 리스트/오디오 프라이밍 때문에 이음매에서 소리가 튀는 경우가 있고,
  /// TS 는 타임스탬프가 연속적이라 이 문제가 없다.
  List<String> _remuxArgs(ClipItem clip, String outPath) {
    return [
      '-hide_banner',
      '-nostdin',
      '-y',
      '-progress', 'pipe:1',
      '-i', clip.spec.path,
      '-map', '0:v:0',
      if (clip.spec.hasAudio) ...['-map', '0:a:0'],
      '-c', 'copy',
      '-f', 'mpegts',
      outPath,
    ];
  }

  /// 재인코딩 경로: 모든 영상을 하나의 규격으로 맞춘다.
  ///
  /// 자른 구간은 `-ss` 를 `-i` 앞에(accurate seek 로 정확한 시각에서 시작), 길이는
  /// 출력 쪽 `-t` 로 준다. 출력 쪽에 거는 이유는 무음 트랙(anullsrc)까지 같이 끊기 위해서다.
  List<String> normalizeArgs(
    SegmentUnit unit,
    OutputSettings s,
    String outPath, {
    required String encoder,
  }) {
    if (unit.join != null) {
      return transitionArgs(unit, s, outPath, encoder: encoder);
    }
    final clip = unit.clip;
    final filter = buildFilterChain(clip, s,
        fadeIn: unit.fadeIn,
        fadeOut: unit.fadeOut,
        duration: unit.duration,
        fadeSec: unit.fadeSec,
        fadeColor: unit.fadeColor);

    final args = <String>[
      '-hide_banner',
      '-nostdin',
      '-y',
      '-progress', 'pipe:1',
      if (unit.trimmed) ...['-ss', unit.range.start.toStringAsFixed(3)],
      '-i', clip.spec.path,
    ];

    // 소리 없는 영상에는 무음 트랙을 붙인다. 없으면 이어붙인 뒤 그 구간부터 오디오가 밀린다.
    if (!clip.spec.hasAudio) {
      args.addAll([
        '-f', 'lavfi',
        '-i', 'anullsrc=channel_layout=stereo:sample_rate=48000',
      ]);
    }

    args.addAll(['-map', '0:v:0']);
    args.addAll(clip.spec.hasAudio ? ['-map', '0:a:0'] : ['-map', '1:a:0']);
    if (!clip.spec.hasAudio) args.add('-shortest');
    if (unit.trimmed) args.addAll(['-t', unit.duration.toStringAsFixed(3)]);

    args.addAll(['-vf', filter]);
    if (clip.spec.hasAudio) {
      final af = buildAudioFilter(clip,
          fadeIn: unit.fadeIn,
          fadeOut: unit.fadeOut,
          duration: unit.duration,
          fadeSec: unit.fadeSec);
      if (af.isNotEmpty) args.addAll(['-af', af]);
    }
    args.addAll(videoEncodeArgs(encoder, s));

    // 오디오 규격을 통일한다. 샘플레이트/채널 수가 다르면 이어붙일 때 깨진다.
    args.addAll([
      '-c:a', 'aac',
      '-b:a', '${(s.audioBitrate / 1000).round()}k',
      '-ar', '48000',
      '-ac', '2',
    ]);

    // 프레임레이트는 분수 그대로 (29.97 을 30 으로 반올림하면 오디오가 서서히 밀린다).
    args.addAll(['-r', s.frameRate.toFFmpegArg()]);
    args.addAll(['-video_track_timescale', '90000']);

    args.addAll(['-f', 'mpegts', outPath]);
    return args;
  }

  /// 조각 목록. 영상마다 남긴 구간 수만큼 생긴다.
  ///
  /// 부드럽게 넘기기를 켜면 조각이 맞닿는 곳마다 앞 조각 끝은 어두워지고 뒤 조각 시작은
  /// 밝아진다. 너무 짧은 조각은 대부분 검은 화면이 되므로 페이드하지 않는다.
  static List<SegmentUnit> buildUnits(
      List<ClipItem> clips, OutputSettings s) {
    final raw = <SegmentUnit>[];
    for (var i = 0; i < clips.length; i++) {
      final c = clips[i];
      for (final r in c.ranges) {
        raw.add(SegmentUnit(
          clip: c,
          clipIndex: i,
          range: r,
          trimmed: c.edit.isTrimmed,
        ));
      }
    }
    if ((!s.smoothTransitions && !s.fadeEnds) || s.lossless) return raw;
    if (overlapActive(s)) return buildOverlapUnits(clips, s);

    final fadeSec = s.transitionLength.seconds;
    final out = <SegmentUnit>[];
    for (var k = 0; k < raw.length; k++) {
      final u = raw[k];
      final canFade = u.duration >= fadeSec * 3;
      final first = k == 0;
      final last = k == raw.length - 1;
      out.add(SegmentUnit(
        clip: u.clip,
        clipIndex: u.clipIndex,
        range: u.range,
        trimmed: u.trimmed,
        fadeIn: canFade && (first ? s.fadeEnds : s.smoothTransitions),
        fadeOut: canFade && (last ? s.fadeEnds : s.smoothTransitions),
        fadeSec: fadeSec,
        fadeColor: s.transitionStyle.endsDip,
      ));
    }
    return out;
  }

  static String buildAudioFilter(
    ClipItem clip, {
    bool fadeIn = false,
    bool fadeOut = false,
    double duration = 0,
    double fadeSec = kFadeSec,
  }) {
    final parts = <String>[];
    final v = clip.edit.volume;
    if (v != VolumeLevel.normal) {
      parts.add('volume=${v.gain.toStringAsFixed(2)}');
      // 키우면 소리가 찢어지므로 리미터를 둔다. latency=1 로 리미터 지연을 보정해야 싱크가 맞는다.
      if (v.gain > 1) parts.add('alimiter=limit=0.95:level=0:latency=1');
    }
    if (fadeIn) parts.add('afade=t=in:st=0:d=$fadeSec');
    if (fadeOut && duration > fadeSec) {
      parts.add('afade=t=out:st=${(duration - fadeSec).toStringAsFixed(3)}'
          ':d=$fadeSec');
    }
    return parts.join(',');
  }

  static List<String> videoEncodeArgs(String encoder, OutputSettings s) {
    final b = s.videoBitrate;
    final maxrate = (b * 1.45).round();
    final bufsize = (b * 2.5).round();

    switch (encoder) {
      case 'h264_nvenc':
      case 'hevc_nvenc':
        return [
          '-c:v', encoder,
          '-preset', 'p5',
          '-rc', 'vbr',
          '-b:v', '$b',
          '-maxrate', '$maxrate',
          '-bufsize', '$bufsize',
          '-pix_fmt', 'yuv420p',
        ];
      case 'h264_qsv':
      case 'hevc_qsv':
        return [
          '-c:v', encoder,
          '-preset', 'medium',
          '-b:v', '$b',
          '-maxrate', '$maxrate',
          '-pix_fmt', 'nv12',
        ];
      case 'h264_amf':
      case 'hevc_amf':
        return [
          '-c:v', encoder,
          '-quality', 'balanced',
          '-rc', 'vbr_latency',
          '-b:v', '$b',
          '-maxrate', '$maxrate',
          '-pix_fmt', 'yuv420p',
        ];
      case 'libx265':
        return [
          '-c:v', 'libx265',
          '-preset', 'medium',
          '-b:v', '$b',
          '-maxrate', '$maxrate',
          '-bufsize', '$bufsize',
          '-pix_fmt', 'yuv420p',
        ];
      default:
        return [
          '-c:v', 'libx264',
          '-preset', 'medium',
          '-b:v', '$b',
          '-maxrate', '$maxrate',
          '-bufsize', '$bufsize',
          '-pix_fmt', 'yuv420p',
        ];
    }
  }

  List<String> _joinArgs(OutputSettings s, String outPath) {
    return [
      '-hide_banner',
      '-nostdin',
      '-y',
      '-progress', 'pipe:1',
      '-f', 'concat',
      '-safe', '0',
      '-i', 'list.txt',
      '-c', 'copy',
      // H.265 는 hvc1 태그여야 Windows 기본 재생기/애플 기기에서 열린다 (기본 hev1 은 안 열리기도 한다).
      if (s.codec == CodecChoice.hevc && !s.lossless) ...['-tag:v', 'hvc1'],
      // 인덱스를 앞쪽에 배치한다. 파일을 다시 쓰므로 큰 파일에서는 시간이 걸린다.
      '-movflags', '+faststart',
      outPath,
    ];
  }

  /// 영상 한 개에 적용할 필터 체인. 순서가 중요하다:
  ///   SAR 펴기 → 회전 → HDR 톤매핑 → 크기 맞춤 → SAR 고정 → 프레임레이트 고정
  ///
  /// ffmpeg 이 컨테이너 회전을 먼저 자동 적용(autorotate)하므로, 여기서 다루는 회전은
  /// 화면에 보이는 상태에서 추가로 돌릴 각도(사용자 회전)다.
  static String buildFilterChain(
    ClipItem clip,
    OutputSettings s, {
    bool fadeIn = false,
    bool fadeOut = false,
    double duration = 0,
    double fadeSec = kFadeSec,
    TransitionStyle fadeColor = TransitionStyle.dipBlack,
  }) {
    final parts = <String>[];

    // 아나모픽(비정사각 픽셀) 영상은 정사각 픽셀로 먼저 펴야 뒤의 scale 이 맞는다.
    // 회전보다 먼저 해야 축이 꼬이지 않는다.
    if (clip.spec.hasNonSquarePixels) {
      parts.add('scale=iw*sar:ih');
      parts.add('setsar=1');
    }

    switch (clip.userRotation) {
      case 90:
        parts.add('transpose=1'); // 시계방향 90도
        break;
      case 180:
        parts.add('hflip');
        parts.add('vflip');
        break;
      case 270:
        parts.add('transpose=2'); // 반시계방향 90도
        break;
    }

    // HDR → SDR 톤매핑. 건너뛰면 색이 빠져 회색빛이 된다.
    if (clip.spec.isHdr) {
      parts.addAll([
        'zscale=t=linear:npl=100',
        'format=gbrpf32le',
        'zscale=p=bt709',
        'tonemap=tonemap=hable:desat=0',
        'zscale=t=bt709:m=bt709:r=tv',
        'format=yuv420p',
      ]);
    }

    final w = s.width;
    final h = s.height;
    if (s.fitMode == FitMode.crop) {
      parts.add('scale=$w:$h:force_original_aspect_ratio=increase');
      parts.add('crop=$w:$h');
    } else {
      parts.add('scale=$w:$h:force_original_aspect_ratio=decrease');
      parts.add('pad=$w:$h:(ow-iw)/2:(oh-ih)/2:color=black');
    }

    // 출력 SAR 을 1:1 로 고정해 특정 구간만 늘어나 보이지 않게 한다.
    parts.add('setsar=1');

    // VFR → CFR. 고정하지 않으면 뒤로 갈수록 소리와 화면이 어긋난다.
    parts.add('fps=${s.frameRate.toFFmpegArg()}');

    parts.add('format=yuv420p');

    // 밝기는 톤매핑 뒤, 8비트로 내린 다음에 건다.
    final b = clip.edit.brightness;
    if (b != BrightnessLevel.normal) {
      parts.add('eq=gamma=${b.gamma.toStringAsFixed(2)}');
    }

    // 이음매 페이드. fps 로 시간축을 고정한 뒤라야 시각이 정확하다. 검은색은 기본값이라 색 인자를 생략한다.
    final colorArg =
        fadeColor.ffmpegName == 'black' ? '' : ':color=${fadeColor.ffmpegName}';
    if (fadeIn) parts.add('fade=t=in:st=0:d=$fadeSec$colorArg');
    if (fadeOut && duration > fadeSec) {
      parts.add('fade=t=out:st=${(duration - fadeSec).toStringAsFixed(3)}'
          ':d=$fadeSec$colorArg');
    }

    return parts.join(',');
  }

  Future<RunResult> _runFFmpeg(
    List<String> args, {
    required String workingDirectory,
    void Function(int outTimeUs, double? speed, int totalSize)? onProgress,
  }) async {
    final proc = await Process.start(
      tools.ffmpegPath,
      args,
      workingDirectory: workingDirectory,
      runInShell: false,
    );
    _current = proc;

    ProcessGuard.attach(proc.pid);

    // 조각 사이 틈에 일시정지했다면 새 프로세스는 얼지 않은 채 시작하므로 여기서 얼린다.
    if (_paused) ProcessFreezer.freeze(proc.pid);

    final errBytes = <int>[];

    // -progress pipe:1: stdout 으로 key=value 줄이 오고 progress=continue|end 로 블록이 끝난다.
    var pendingUs = 0;
    var pendingSize = 0;
    double? pendingSpeed;

    final stdoutDone = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      final idx = line.indexOf('=');
      if (idx <= 0) return;
      final key = line.substring(0, idx).trim();
      final value = line.substring(idx + 1).trim();

      switch (key) {
        case 'out_time_us':
        case 'out_time_ms':
          // out_time_ms 는 이름과 달리 마이크로초 단위이며 out_time_us 와 같은 값이다.
          final v = int.tryParse(value);
          if (v != null && v >= 0) pendingUs = v;
          break;
        case 'total_size':
          final v = int.tryParse(value);
          if (v != null && v >= 0) pendingSize = v;
          break;
        case 'speed':
          final v = double.tryParse(value.replaceAll('x', '').trim());
          if (v != null && v > 0) pendingSpeed = v;
          break;
        case 'progress':
          onProgress?.call(pendingUs, pendingSpeed, pendingSize);
          break;
      }
    }).asFuture<void>();

    final stderrDone = proc.stderr.forEach(errBytes.addAll);

    final code = await proc.exitCode;
    await Future.wait([stdoutDone, stderrDone]).catchError((_) => <void>[]);
    _current = null;

    return RunResult(
      code,
      '',
      utf8.decode(errBytes, allowMalformed: true),
    );
  }

  static Duration? _estimateRemaining(
    DateTime started,
    double processedDuration,
    double totalDuration,
  ) {
    if (processedDuration < 1 || totalDuration <= 0) return null;
    final elapsed = DateTime.now().difference(started).inMilliseconds / 1000.0;
    if (elapsed < 2) return null;
    final rate = processedDuration / elapsed;
    if (rate <= 0) return null;
    final remainSec = (totalDuration - processedDuration) / rate;
    if (remainSec.isNaN || remainSec.isInfinite || remainSec < 0) return null;
    return Duration(seconds: remainSec.round().clamp(0, 60 * 60 * 24));
  }

  /// 테스트용 [_jobId] 접근자.
  static String jobIdFor(List<ClipItem> clips, OutputSettings s) =>
      _jobId(clips, s);

  /// 입력 목록과 설정이 같으면 같은 작업 폴더를 써서 이어하기가 된다.
  static String _jobId(List<ClipItem> clips, OutputSettings s) {
    final sb = StringBuffer();
    for (final c in clips) {
      sb.write(c.spec.path);
      sb.write('|${c.spec.fileSize}|${c.userRotation}|${c.edit.signature}|');
    }
    sb.write('${s.lossless}|${s.width}x${s.height}|${s.frameRate.toFFmpegArg()}');
    if (!s.lossless) {
      if (s.smoothTransitions) {
        sb.write('|smooth|${s.transitionStyle.name}|${s.transitionLength.name}');
      }
      if (s.fadeEnds) {
        sb.write('|ends|${s.transitionStyle.endsDip.name}|${s.transitionLength.name}');
      }
    }
    sb.write('|${s.videoBitrate}|${s.audioBitrate}|${s.codec.name}|${s.fitMode.name}');

    // FNV-1a 32bit. 같은 폴더 안에서만 구분되면 된다.
    var hash = 0x811c9dc5;
    for (final unit in utf8.encode(sb.toString())) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  void _cleanup(Directory? dir) {
    if (dir == null) return;
    try {
      forceDeleteDir(dir);
      // 비어 있으면 부모(.videojoin_temp)도 치운다.
      final parent = dir.parent;
      if (parent.existsSync() &&
          p.basename(parent.path) == '.videojoin_temp' &&
          parent.listSync().isEmpty) {
        forceDeleteDir(parent, recursive: false);
      }
    } on Object {
      // 결과물은 이미 만들어졌으므로 정리 실패는 무시한다.
    }
  }

  static bool _looksLikeGpuFailure(String stderr) {
    final s = stderr.toLowerCase();
    return s.contains('nvenc') ||
        s.contains('cuda') ||
        s.contains('qsv') ||
        s.contains('amf') ||
        s.contains('no capable devices') ||
        s.contains('driver does not support');
  }

  static String _friendlyError(String stderr, String fileName) {
    final s = stderr.toLowerCase();
    if (s.contains('no space left')) {
      return '저장 공간이 부족합니다.';
    }
    if (s.contains('permission denied') || s.contains('access is denied')) {
      return '파일에 접근할 권한이 없습니다.';
    }
    if (s.contains('invalid data found') || s.contains('moov atom not found')) {
      return fileName.isEmpty
          ? '영상 파일이 손상되었습니다.'
          : '$fileName 파일이 손상되어 읽을 수 없습니다.';
    }
    if (s.contains('no such file')) {
      return '영상 파일을 찾을 수 없습니다. 이동하거나 지워졌을 수 있습니다.';
    }
    if (s.contains('height not divisible') || s.contains('width not divisible')) {
      return '영상 크기를 맞추는 데 실패했습니다.';
    }
    return fileName.isEmpty
        ? '영상을 만드는 중 문제가 발생했습니다.'
        : '$fileName 처리 중 문제가 발생했습니다.';
  }
}

/// 이음매 페이드 길이(초). 어두워지는 쪽, 밝아지는 쪽 각각이다.
const double kFadeSec = 0.5;

/// 1단계에서 만드는 조각 하나 = 영상 한 개의 한 구간.
class SegmentUnit {
  final ClipItem clip;

  /// 목록에서의 영상 순번(로그·진행 표시용).
  final int clipIndex;
  final TimeRange range;

  /// 자르지 않았으면 -ss/-t 없이 통째로 쓴다 (길이를 못 읽은 영상도 처리되도록).
  final bool trimmed;
  final bool fadeIn;
  final bool fadeOut;
  final double fadeSec;
  final TransitionStyle fadeColor;

  /// 겹치기 전환 조각이면 두 입력 정보. 이때 [clip]·[range] 는 앞 영상 쪽.
  final TransitionJoin? join;

  const SegmentUnit({
    required this.clip,
    required this.clipIndex,
    required this.range,
    required this.trimmed,
    this.fadeIn = false,
    this.fadeOut = false,
    this.fadeSec = kFadeSec,
    this.fadeColor = TransitionStyle.dipBlack,
    this.join,
  });

  double get duration =>
      join != null ? join!.d : (trimmed ? range.length : clip.spec.durationSec);
}
