import 'dart:math' as math;

import 'models.dart';
import 'rational.dart';
import 'transition_style.dart';
import 'transitions.dart';

export 'transition_style.dart';

/// 화면비가 다른 영상을 목표 규격에 맞추는 방식.
enum FitMode {
  /// 전체를 보여주고 남는 곳을 검은색으로 채운다.
  pad('여백 채움', '화면 전체를 보여주고 남는 곳은 검은색'),

  /// 화면을 꽉 채우도록 확대하고 넘치는 부분을 자른다.
  crop('잘라내기', '화면을 꽉 채우고 넘치는 부분은 잘림');

  final String label;
  final String description;
  const FitMode(this.label, this.description);
}

enum CodecChoice {
  h264('H.264', '어디서나 재생됨'),
  hevc('H.265', '용량 약 40% 감소 · 구형 기기에서 재생 안 될 수 있음');

  final String label;
  final String note;
  const CodecChoice(this.label, this.note);
}

enum WarningLevel { info, caution, error }

class PlanWarning {
  final WarningLevel level;
  final String message;
  final String? detail;

  const PlanWarning(this.level, this.message, {this.detail});
}

/// 선택지 하나. `note` 에는 원본 실측에 대한 설명이 들어간다.
class ResolutionOption {
  final int width;
  final int height;
  final String nickname;
  final String note;
  final bool isOriginalMax;

  const ResolutionOption({
    required this.width,
    required this.height,
    required this.nickname,
    required this.note,
    this.isOriginalMax = false,
  });

  int get pixels => width * height;
  String get label => '$width × $height';

  @override
  bool operator ==(Object other) =>
      other is ResolutionOption && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);
}

class FpsOption {
  final Rational fps;
  final String note;
  final bool isOriginalMax;

  const FpsOption({required this.fps, required this.note, this.isOriginalMax = false});

  String get label => fps.label;
}

/// 비트레이트 선택의 성격. 선택을 절대값이 아니라 이 종류로 기억한다 —
/// 해상도를 바꾸면 "원본 유지"에 해당하는 값도 달라져야 하기 때문이다.
enum BitrateKind { original, standard, saver }

class BitrateOption {
  final int bps;
  final BitrateKind kind;
  final String title;
  final String note;

  const BitrateOption({
    required this.bps,
    required this.kind,
    required this.title,
    required this.note,
  });

  bool get isOriginal => kind == BitrateKind.original;

  String get label => formatBitrate(bps);
}

/// 사용자가 확정한 출력 설정.
class OutputSettings {
  /// 재인코딩 없이 그대로 이어붙일지. 화질 손실이 없고 가장 빠르다.
  bool lossless;

  int width;
  int height;
  Rational frameRate;
  int videoBitrate;
  int audioBitrate;
  CodecChoice codec;
  FitMode fitMode;
  bool useGpu;

  /// 영상 사이(자른 곳 포함)를 부드럽게 넘긴다. 이음매의 '틱' 소리도 없앤다.
  bool smoothTransitions;

  /// 넘기는 방식(거치기 / 겹치기).
  TransitionStyle transitionStyle;

  /// 넘기는 길이. 거치기는 한쪽 길이, 겹치기는 그 두 배를 겹친다.
  TransitionLength transitionLength;

  /// 결과물의 맨 처음과 맨 끝을 서서히 시작/종료한다. [smoothTransitions] 와 별개.
  bool fadeEnds;

  String outputDir;

  /// 확장자를 뺀 파일 이름.
  String outputName;

  OutputSettings({
    required this.lossless,
    required this.width,
    required this.height,
    required this.frameRate,
    required this.videoBitrate,
    this.audioBitrate = 192000,
    this.codec = CodecChoice.h264,
    this.fitMode = FitMode.pad,
    this.useGpu = true,
    this.smoothTransitions = false,
    this.transitionStyle = TransitionStyle.dipBlack,
    this.transitionLength = TransitionLength.normal,
    this.fadeEnds = false,
    required this.outputDir,
    required this.outputName,
  });

  String get outputPath => '$outputDir\\$outputName.mp4';

  OutputSettings clone() => OutputSettings(
        lossless: lossless,
        width: width,
        height: height,
        frameRate: frameRate,
        videoBitrate: videoBitrate,
        audioBitrate: audioBitrate,
        codec: codec,
        fitMode: fitMode,
        useGpu: useGpu,
        smoothTransitions: smoothTransitions,
        transitionStyle: transitionStyle,
        transitionLength: transitionLength,
        fadeEnds: fadeEnds,
        outputDir: outputDir,
        outputName: outputName,
      );
}

/// 입력 클립들을 분석해서 어떤 선택지를 줄지 결정한다.
///
/// ## 기본값 원칙
/// 목표는 용량 절약이 아니라 파일 하나로 합치는 것이므로 **기본값은 모두 원본 최대치**다
/// (해상도·프레임레이트·비트레이트는 입력 중 최대, 재인코딩이 필요 없으면 하지 않는다).
/// 화질을 낮추는 선택지는 제공만 한다.
class JobPlan {
  final List<ClipItem> clips;

  final bool losslessPossible;

  /// 무손실이 불가능한 이유(사용자에게 보여줄 한 줄).
  final String? losslessBlockedReason;

  final List<ResolutionOption> resolutions;
  final List<FpsOption> frameRates;
  final List<PlanWarning> warnings;

  final double totalDuration;
  final int totalInputBytes;

  /// 입력 중 가장 높은 영상 비트레이트와 그 파일 이름.
  final int originalMaxVideoBitrate;
  final String originalMaxBitrateSource;

  final int originalMaxPixels;
  final bool anyHdr;
  final bool anyMissingAudio;
  final bool mixedOrientation;
  final bool anyVfr;

  const JobPlan({
    required this.clips,
    required this.losslessPossible,
    this.losslessBlockedReason,
    required this.resolutions,
    required this.frameRates,
    required this.warnings,
    required this.totalDuration,
    required this.totalInputBytes,
    required this.originalMaxVideoBitrate,
    required this.originalMaxBitrateSource,
    required this.originalMaxPixels,
    required this.anyHdr,
    required this.anyMissingAudio,
    required this.mixedOrientation,
    required this.anyVfr,
  });

  ResolutionOption get defaultResolution =>
      resolutions.firstWhere((r) => r.isOriginalMax, orElse: () => resolutions.first);

  FpsOption get defaultFps =>
      frameRates.firstWhere((f) => f.isOriginalMax, orElse: () => frameRates.first);

  static JobPlan analyze(List<ClipItem> clips,
      {bool smoothTransitions = false, bool fadeEnds = false}) {
    final valid = clips.where((c) => c.spec.ok).toList();
    final warnings = <PlanWarning>[];

    for (final c in clips.where((c) => !c.spec.ok)) {
      warnings.add(PlanWarning(
        WarningLevel.error,
        '${c.spec.fileName} — ${c.spec.errorMessage}',
      ));
    }

    if (valid.isEmpty) {
      return JobPlan(
        clips: clips,
        losslessPossible: false,
        losslessBlockedReason: '읽을 수 있는 영상이 없습니다.',
        resolutions: const [
          ResolutionOption(width: 1920, height: 1080, nickname: 'Full HD', note: ''),
        ],
        frameRates: const [FpsOption(fps: Rational(30, 1), note: '')],
        warnings: warnings,
        totalDuration: 0,
        totalInputBytes: 0,
        originalMaxVideoBitrate: 0,
        originalMaxBitrateSource: '',
        originalMaxPixels: 0,
        anyHdr: false,
        anyMissingAudio: false,
        mixedOrientation: false,
        anyVfr: false,
      );
    }

    final totalDuration = valid.fold<double>(0, (s, c) => s + c.effectiveDuration);
    final totalBytes = valid.fold<int>(0, (s, c) => s + c.spec.fileSize);

    var maxBitrate = 0;
    var maxBitrateSource = '';
    for (final c in valid) {
      final b = c.spec.estimatedVideoBitrate;
      if (b > maxBitrate) {
        maxBitrate = b;
        maxBitrateSource = c.spec.fileName;
      }
    }

    // 가로/세로가 섞였으면 다수결, 동수면 가로.
    final portraitCount = valid.where((c) => c.finalIsPortrait).length;
    final landscapeCount = valid.length - portraitCount;
    final targetPortrait = portraitCount > landscapeCount;
    final mixedOrientation = portraitCount > 0 && landscapeCount > 0;

    final oriented = valid.where((c) => c.finalIsPortrait == targetPortrait).toList();
    final pool = oriented.isEmpty ? valid : oriented;

    var maxW = 0, maxH = 0;
    for (final c in pool) {
      if (c.finalWidth * c.finalHeight > maxW * maxH) {
        maxW = c.finalWidth;
        maxH = c.finalHeight;
      }
    }
    maxW = _even(maxW);
    maxH = _even(maxH);

    final resolutions = _buildResolutionOptions(valid, maxW, maxH, targetPortrait);
    final frameRates = _buildFpsOptions(valid);

    String? blocked;
    final rotated = valid.where((c) => c.userRotation != 0).toList();
    final edited = valid.where((c) => !c.edit.isDefault).toList();
    if (rotated.isNotEmpty) {
      blocked = '${rotated.length}개 영상을 회전했기 때문에 다시 만들어야 합니다.';
    } else if (edited.isNotEmpty) {
      // 그대로 이어붙이기는 키프레임 단위로만 자를 수 있고 소리·밝기는 바꿀 수 없다.
      blocked = '${edited.length}개 영상을 손봤기 때문에 다시 만들어야 합니다.';
    } else if (smoothTransitions) {
      blocked = '영상 사이를 부드럽게 넘기려면 다시 만들어야 합니다.';
    } else if (fadeEnds) {
      blocked = '처음과 끝을 서서히 하려면 다시 만들어야 합니다.';
    } else {
      final keys = valid.map((c) => c.spec.concatCompatKey).toSet();
      if (keys.length > 1) {
        blocked = _describeMismatch(valid);
      } else {
        final codec = valid.first.spec.videoCodec.toLowerCase();
        // MPEG-TS 중간 컨테이너를 거치므로 TS 에 담을 수 있는 코덱만 허용.
        if (!const {'h264', 'hevc', 'mpeg2video', 'mpeg4'}.contains(codec)) {
          blocked = '이 영상 형식(${codec.isEmpty ? '알 수 없음' : codec})은 '
              '그대로 이어붙일 수 없어 다시 만들어야 합니다.';
        }
      }
    }

    final anyHdr = valid.any((c) => c.spec.isHdr);
    final anyMissingAudio = valid.any((c) => !c.spec.hasAudio);
    final anyVfr = valid.any((c) => c.spec.isVfr);

    if (anyHdr) {
      final n = valid.where((c) => c.spec.isHdr).length;
      warnings.add(PlanWarning(
        WarningLevel.caution,
        'HDR 영상 $n개가 포함되어 있습니다.',
        detail: '일반(SDR) 화면에 맞게 밝기와 색을 변환합니다. 변환하지 않으면 '
            '색이 빠져 뿌옇게 보입니다.',
      ));
    }
    if (anyMissingAudio) {
      final n = valid.where((c) => !c.spec.hasAudio).length;
      warnings.add(PlanWarning(
        WarningLevel.info,
        '소리가 없는 영상 $n개가 있습니다.',
        detail: '해당 구간은 무음으로 채워 넣습니다.',
      ));
    }
    if (mixedOrientation) {
      warnings.add(PlanWarning(
        WarningLevel.info,
        '가로 영상과 세로 영상이 섞여 있습니다.',
        detail: '가로 $landscapeCount개, 세로 $portraitCount개. '
            '${targetPortrait ? '세로' : '가로'} 기준으로 맞춥니다.',
      ));
    }

    return JobPlan(
      clips: clips,
      losslessPossible: blocked == null,
      losslessBlockedReason: blocked,
      resolutions: resolutions,
      frameRates: frameRates,
      warnings: warnings,
      totalDuration: totalDuration,
      totalInputBytes: totalBytes,
      originalMaxVideoBitrate: maxBitrate,
      originalMaxBitrateSource: maxBitrateSource,
      originalMaxPixels: maxW * maxH,
      anyHdr: anyHdr,
      anyMissingAudio: anyMissingAudio,
      mixedOrientation: mixedOrientation,
      anyVfr: anyVfr,
    );
  }

  static List<ResolutionOption> _buildResolutionOptions(
    List<ClipItem> clips,
    int maxW,
    int maxH,
    bool portrait,
  ) {
    final options = <ResolutionOption>[];

    final sameCount =
        clips.where((c) => c.finalWidth == maxW && c.finalHeight == maxH).length;
    options.add(ResolutionOption(
      width: maxW,
      height: maxH,
      nickname: resolutionNickname(maxW, maxH),
      note: clips.length == 1
          ? '원본 그대로'
          : '넣은 영상 중 가장 큼 · ${clips.length}개 중 $sameCount개가 이 크기',
      isOriginalMax: true,
    ));

    // 축소 선택지. 화면비는 원본 최대 것을 유지해 추가 여백이 생기지 않게 한다.
    final aspect = maxW / maxH;
    final shortSides = portrait ? [1080, 720] : [1080, 720];

    for (final target in shortSides) {
      int w, h;
      if (portrait) {
        w = _even(target);
        h = _even((target / aspect).round());
      } else {
        h = _even(target);
        w = _even((target * aspect).round());
      }
      if (w >= maxW && h >= maxH) continue;
      if (w < 160 || h < 160) continue;
      if (options.any((o) => o.width == w && o.height == h)) continue;

      final ratio = (w * h) / (maxW * maxH);
      options.add(ResolutionOption(
        width: w,
        height: h,
        nickname: resolutionNickname(w, h),
        note: '용량 약 ${_fractionLabel(ratio)}로 감소',
      ));
    }

    return options;
  }

  static List<FpsOption> _buildFpsOptions(List<ClipItem> clips) {
    // 원본에 없는 값은 무조건 변환이 일어나 이득이 없으므로 입력에 있는 값만 후보로 한다.
    final counts = <String, int>{};
    final byKey = <String, Rational>{};
    for (final c in clips) {
      final f = c.spec.frameRate.reduced();
      final k = f.toFFmpegArg();
      counts[k] = (counts[k] ?? 0) + 1;
      byKey[k] = f;
    }

    final sorted = byKey.values.toList()..sort((a, b) => b.compareTo(a));
    if (sorted.isEmpty) {
      return const [FpsOption(fps: Rational(30, 1), note: '', isOriginalMax: true)];
    }

    final max = sorted.first;
    return sorted.map((f) {
      final n = counts[f.toFFmpegArg()]!;
      final isMax = f == max;
      final parts = <String>[];
      if (isMax) parts.add('넣은 영상 중 가장 높음');
      parts.add(clips.length == 1 ? '원본' : '${clips.length}개 중 $n개');
      return FpsOption(fps: f, note: parts.join(' · '), isOriginalMax: isMax);
    }).toList();
  }

  static String _describeMismatch(List<ClipItem> clips) {
    final reasons = <String>[];

    final sizes = clips.map((c) => '${c.finalWidth}x${c.finalHeight}').toSet();
    if (sizes.length > 1) reasons.add('화면 크기');

    final fps = clips.map((c) => c.spec.frameRate.reduced().toFFmpegArg()).toSet();
    if (fps.length > 1) reasons.add('프레임레이트');

    final codecs = clips.map((c) => c.spec.videoCodec).toSet();
    if (codecs.length > 1) reasons.add('영상 형식');

    final audio = clips
        .map((c) => c.spec.hasAudio
            ? '${c.spec.audioCodec}/${c.spec.audioSampleRate}/${c.spec.audioChannels}'
            : 'none')
        .toSet();
    if (audio.length > 1) reasons.add('소리 형식');

    final pix = clips.map((c) => c.spec.pixFmt).toSet();
    if (pix.length > 1) reasons.add('색 형식');

    if (reasons.isEmpty) reasons.add('세부 설정');
    return '영상들의 ${reasons.join(', ')}이(가) 서로 달라서 다시 만들어야 합니다.';
  }

  /// 목표 해상도/프레임레이트에 맞는 비트레이트 후보. 첫 항목이 항상 "원본 유지"(기본)다.
  List<BitrateOption> bitrateOptions(int width, int height, Rational fps, CodecChoice codec) {
    final options = <BitrateOption>[];
    final targetPixels = width * height;

    // 원본 유지. 해상도를 줄이면 픽셀 수 비율로 환산해 같은 화질 밀도를 유지한다.
    // note 에는 수치의 기준을 함께 적는다.
    var originalEquiv = originalMaxVideoBitrate;
    var originalNote = originalMaxBitrateSource.isEmpty
        ? '넣은 영상 중 가장 높은 값'
        : '넣은 영상 중 가장 높은 값 · $originalMaxBitrateSource';

    if (originalMaxPixels > 0 && targetPixels < originalMaxPixels) {
      final scaled = (originalMaxVideoBitrate * (targetPixels / originalMaxPixels)).round();
      originalEquiv = scaled;
      originalNote = '원본 ${formatBitrate(originalMaxVideoBitrate)} 를 '
          '줄어든 화면 크기에 맞춰 환산';
    }
    if (codec == CodecChoice.hevc) {
      originalEquiv = (originalEquiv * 0.65).round();
      originalNote = '$originalNote · H.265 라서 65%';
    }
    originalEquiv = _clampBitrate(originalEquiv);

    options.add(BitrateOption(
      bps: originalEquiv,
      kind: BitrateKind.original,
      title: '원본 유지',
      note: originalNote,
    ));

    // 표준 권장값. 원본보다 높으면 넣지 않는다.
    var standard = standardBitrate(width, height, fps.toDouble());
    if (codec == CodecChoice.hevc) standard = (standard * 0.65).round();
    standard = _clampBitrate(standard);

    if (standard < originalEquiv * 0.92) {
      options.add(BitrateOption(
        bps: standard,
        kind: BitrateKind.standard,
        title: '표준',
        note: '$width×$height ${fps.label} 에 흔히 쓰는 값',
      ));
    }

    final saver = _clampBitrate((standard * 0.6).round());
    if (saver < (options.last.bps) * 0.92) {
      options.add(BitrateOption(
        bps: saver,
        kind: BitrateKind.saver,
        title: '용량 절약',
        note: '표준의 60% · 화질 손해를 감수하고 줄임',
      ));
    }

    return options;
  }

  /// H.264 표준 권장 비트레이트(bps). YouTube 업로드 권장치를 구간 선형 보간한다.
  static int standardBitrate(int width, int height, double fps) {
    // (픽셀 수, 30fps 기준 Mbps)
    const table = <List<double>>[
      [640 * 480, 2.0],
      [1280 * 720, 5.0],
      [1920 * 1080, 8.0],
      [2560 * 1440, 16.0],
      [3840 * 2160, 35.0],
      [7680 * 4320, 120.0],
    ];

    final px = (width * height).toDouble();
    double mbps;

    if (px <= table.first[0]) {
      mbps = table.first[1] * (px / table.first[0]);
    } else if (px >= table.last[0]) {
      mbps = table.last[1] * (px / table.last[0]);
    } else {
      mbps = table.last[1];
      for (var i = 0; i < table.length - 1; i++) {
        final p0 = table[i][0], b0 = table[i][1];
        final p1 = table[i + 1][0], b1 = table[i + 1][1];
        if (px >= p0 && px <= p1) {
          final t = (px - p0) / (p1 - p0);
          mbps = b0 + (b1 - b0) * t;
          break;
        }
      }
    }

    // 프레임이 2배가 되어도 연속 프레임이 더 비슷해 압축이 잘 먹으므로 1.5배면 충분하다.
    final ratio = fps <= 0 ? 1.0 : fps / 30.0;
    final factor = 1 + (ratio - 1) * 0.5;
    mbps *= factor.clamp(0.5, 3.0);

    return _clampBitrate((mbps * 1000000).round());
  }

  static int _clampBitrate(int bps) => bps.clamp(300000, 400000000);

  static int _even(int v) => v.isEven ? v : v + 1;

  static String _fractionLabel(double ratio) {
    if (ratio <= 0.14) return '1/8';
    if (ratio <= 0.3) return '1/4';
    if (ratio <= 0.4) return '1/3';
    if (ratio <= 0.6) return '1/2';
    return '${(ratio * 100).round()}%';
  }

  /// 결과물 길이. 겹치기 전환을 쓰면 겹친 만큼 짧아진다. 예상치들이 모두 이 값을 쓴다.
  double outputDuration(OutputSettings s) =>
      overlapActive(s) ? outputDurationFor(clips, s) : totalDuration;

  /// 예상 출력 용량(바이트). 비트레이트 고정이라 예측이 가능하다 (CRF 는 불가).
  int estimateOutputBytes(OutputSettings s) {
    if (s.lossless) {
      // 재인코딩이 없어 원본 합계와 거의 같다.
      return (totalInputBytes * 1.005).round();
    }
    final bits = (s.videoBitrate + s.audioBitrate) * outputDuration(s);
    return (bits / 8 * 1.02).round();
  }

  /// 예상 소요 시간(초). 초기 추정치이며 진행 중에는 ffmpeg 실측 속도로 대체된다.
  double estimateSeconds(OutputSettings s, {bool gpuAvailable = true}) {
    if (s.lossless) {
      // 디스크 복사 속도가 지배한다. 보수적으로 120MB/s.
      const bytesPerSec = 120 * 1024 * 1024;
      return math.max(5, totalInputBytes / bytesPerSec * 2);
    }

    final px = s.width * s.height;
    final fpsFactor = s.frameRate.toDouble() / 30.0;

    // 실시간 대비 처리 배속 (1.0 = 영상 길이와 같은 시간)
    double speed;
    if (s.useGpu && gpuAvailable) {
      speed = 8.0 * (1920 * 1080) / px;
    } else {
      speed = 1.6 * (1920 * 1080) / px;
    }
    speed /= fpsFactor.clamp(0.5, 4.0);

    if (s.codec == CodecChoice.hevc) speed *= s.useGpu && gpuAvailable ? 0.85 : 0.5;

    // HDR 톤매핑은 CPU 필터라 GPU 인코딩이어도 병목이 된다.
    if (anyHdr) speed *= 0.4;

    speed = speed.clamp(0.05, 40.0);
    return math.max(5, outputDuration(s) / speed);
  }

  /// 필요한 디스크 여유 공간(바이트). 정규화 중간 파일과 최종 결과물이 동시에 존재한다.
  int requiredDiskBytes(OutputSettings s) {
    final out = estimateOutputBytes(s);
    return (out * 2.1).round();
  }
}
