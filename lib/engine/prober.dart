import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'ffmpeg_tools.dart';
import 'models.dart';
import 'rational.dart';

/// ffprobe 로 영상 파일의 실제 스펙을 읽어낸다.
class Prober {
  final FFTools tools;

  const Prober(this.tools);

  /// 동시에 돌릴 ffprobe 개수. 늘리면 디스크가 병목이 된다.
  static const int concurrency = 6;

  Future<VideoSpec> probe(String rawPath) async {
    // Executor 가 ffmpeg 을 임시 작업 폴더에서 실행하므로 상대 경로가 남으면 안 된다.
    final path = p.normalize(p.absolute(rawPath));

    final file = File(path);
    if (!file.existsSync()) {
      return VideoSpec.failed(path, '파일을 찾을 수 없습니다.');
    }

    final res = await runCaptured(
      tools.ffprobePath,
      [
        '-v', 'error',
        '-print_format', 'json',
        '-show_format',
        '-show_streams',
        path,
      ],
      timeout: const Duration(seconds: 60),
    );

    if (!res.ok || res.stdout.trim().isEmpty) {
      final msg = res.stderr.trim().isEmpty
          ? '영상 정보를 읽을 수 없습니다.'
          : _friendlyProbeError(res.stderr);
      return VideoSpec.failed(path, msg);
    }

    Map<String, dynamic> json;
    try {
      json = jsonDecode(res.stdout) as Map<String, dynamic>;
    } on Object {
      return VideoSpec.failed(path, '영상 정보를 해석할 수 없습니다.');
    }

    return _build(path, json);
  }

  Future<List<VideoSpec>> probeAll(
    List<String> paths, {
    void Function(int done, int total)? onProgress,
  }) async {
    final results = List<VideoSpec?>.filled(paths.length, null);
    var done = 0;
    var next = 0;

    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= paths.length) return;
        results[i] = await probe(paths[i]);
        done++;
        onProgress?.call(done, paths.length);
      }
    }

    final workers = List.generate(
      paths.length < concurrency ? paths.length : concurrency,
      (_) => worker(),
    );
    await Future.wait(workers);

    return results.map((e) => e!).toList();
  }

  VideoSpec _build(String path, Map<String, dynamic> json) {
    final streams = (json['streams'] as List?) ?? const [];
    final format = (json['format'] as Map?)?.cast<String, dynamic>() ?? const {};

    Map<String, dynamic>? video;
    Map<String, dynamic>? audio;
    for (final s in streams) {
      final m = (s as Map).cast<String, dynamic>();
      final type = m['codec_type'] as String?;
      // 앨범아트/썸네일이 video 스트림으로 잡히는 경우를 거른다.
      final disp = (m['disposition'] as Map?)?.cast<String, dynamic>();
      final isCover = (disp?['attached_pic'] ?? 0) == 1;
      if (type == 'video' && !isCover && video == null) video = m;
      if (type == 'audio' && audio == null) audio = m;
    }

    if (video == null) {
      return VideoSpec.failed(path, '영상 트랙이 없는 파일입니다.');
    }

    final st = File(path).statSync();

    final rawWidth = _toInt(video['width']) ?? 0;
    final rawHeight = _toInt(video['height']) ?? 0;
    if (rawWidth <= 0 || rawHeight <= 0) {
      return VideoSpec.failed(path, '영상 크기를 읽을 수 없습니다.');
    }

    // avg_frame_rate: 전체 프레임 수 / 재생시간
    // r_frame_rate  : 가장 짧은 프레임 간격의 역수 (VFR 이면 크게 튄다)
    final avg = Rational.tryParse(video['avg_frame_rate'] as String?);
    final rFr = Rational.tryParse(video['r_frame_rate'] as String?);

    // avg 대비 r 이 15% 이상 높으면 가변 프레임레이트. 폰 영상이 대부분 해당하며,
    // CFR 로 강제하지 않으면 이어붙인 뒤 뒤로 갈수록 소리가 어긋난다.
    final isVfr = avg != null &&
        rFr != null &&
        avg.toDouble() > 0 &&
        rFr.toDouble() > avg.toDouble() * 1.15;

    // CFR 은 r_frame_rate 가 더 정확하다. avg 는 이음매에 미세한 갭이 있으면
    // 30p 가 29.89p 로 계산된다. VFR 에서는 r 이 튀므로 avg 를 쓴다.
    final frameRate =
        (isVfr ? avg : (rFr ?? avg)) ?? const Rational(30, 1);
    final rFrameRate = rFr ?? frameRate;

    final rotation = _extractRotation(video);
    final sar = _extractSar(video);

    var duration = _toDouble(format['duration']) ?? 0;
    if (duration <= 0) duration = _toDouble(video['duration']) ?? 0;
    if (duration <= 0) {
      // 일부 avi/mkv 는 duration 이 비어 있어 프레임 수로 역산한다.
      final nb = _toInt(video['nb_frames']);
      if (nb != null && nb > 0 && frameRate.toDouble() > 0) {
        duration = nb / frameRate.toDouble();
      }
    }

    return VideoSpec(
      path: path,
      fileSize: st.size,
      fileModified: st.modified,
      // Windows 에서 FileStat.changed 는 파일 생성 시각이다.
      fileCreated: st.changed,
      metaCreationTime: _extractCreationTime(format, video),
      rawWidth: rawWidth,
      rawHeight: rawHeight,
      containerRotation: rotation,
      frameRate: frameRate,
      rFrameRate: rFrameRate,
      isVfr: isVfr,
      durationSec: duration,
      videoCodec: (video['codec_name'] as String?) ?? '',
      pixFmt: (video['pix_fmt'] as String?) ?? '',
      videoStreamBitrate: _toInt(video['bit_rate']),
      formatBitrate: _toInt(format['bit_rate']),
      sarNum: sar.$1,
      sarDen: sar.$2,
      colorTransfer: video['color_transfer'] as String?,
      colorPrimaries: video['color_primaries'] as String?,
      colorSpace: video['color_space'] as String?,
      hasAudio: audio != null,
      audioCodec: audio?['codec_name'] as String?,
      audioSampleRate: _toInt(audio?['sample_rate']),
      audioChannels: _toInt(audio?['channels']),
      audioBitrate: _toInt(audio?['bit_rate']),
    );
  }

  /// 회전 메타데이터를 시계방향 0/90/180/270 으로 정규화한다.
  ///
  /// 두 가지 표기가 공존한다:
  ///  - `tags.rotate` : 구형 mov/mp4. 이미 시계방향 각도다.
  ///  - `side_data_list[].rotation` : displaymatrix. ffprobe 가 **반시계** 각도로
  ///    내보내므로(세로 촬영 폰 영상은 보통 -90) 부호를 뒤집는다.
  static int _extractRotation(Map<String, dynamic> video) {
    final sideList = video['side_data_list'] as List?;
    if (sideList != null) {
      for (final sd in sideList) {
        final m = (sd as Map).cast<String, dynamic>();
        final r = _toDouble(m['rotation']);
        if (r != null) {
          return _normalizeAngle(-r.round());
        }
      }
    }

    final tags = (video['tags'] as Map?)?.cast<String, dynamic>();
    final rotate = tags?['rotate'] ?? tags?['Rotate'];
    if (rotate != null) {
      final r = _toDouble(rotate);
      if (r != null) return _normalizeAngle(r.round());
    }

    return 0;
  }

  /// 픽셀 종횡비 (분자, 분모). 알 수 없으면("0:1", "N/A") 정사각 픽셀(1:1)로 본다.
  static (int, int) _extractSar(Map<String, dynamic> video) {
    final raw = video['sample_aspect_ratio'] as String?;
    if (raw == null || raw.trim().isEmpty || raw == 'N/A') return (1, 1);
    final parts = raw.split(':');
    if (parts.length != 2) return (1, 1);
    final n = int.tryParse(parts[0].trim());
    final d = int.tryParse(parts[1].trim());
    if (n == null || d == null || n <= 0 || d <= 0) return (1, 1);
    return (n, d);
  }

  static int _normalizeAngle(int deg) {
    var a = deg % 360;
    if (a < 0) a += 360;
    final snapped = ((a + 45) ~/ 90 * 90) % 360;
    return snapped;
  }

  /// 촬영 시각. 아이폰의 로컬 오프셋 포함 전용 태그를 먼저 보고, 일반 creation_time 은 UTC 라 로컬로 변환한다.
  static DateTime? _extractCreationTime(
    Map<String, dynamic> format,
    Map<String, dynamic> video,
  ) {
    final fTags = (format['tags'] as Map?)?.cast<String, dynamic>() ?? const {};
    final vTags = (video['tags'] as Map?)?.cast<String, dynamic>() ?? const {};

    final candidates = <String?>[
      fTags['com.apple.quicktime.creationdate'] as String?,
      fTags['creation_time'] as String?,
      vTags['creation_time'] as String?,
      fTags['date'] as String?,
    ];

    for (final c in candidates) {
      if (c == null || c.trim().isEmpty) continue;
      try {
        final dt = DateTime.parse(c.trim());
        // 1970 근처나 미래 값은 무효.
        if (dt.year < 1990 || dt.isAfter(DateTime.now().add(const Duration(days: 2)))) {
          continue;
        }
        return dt.toLocal();
      } on Object {
        continue;
      }
    }
    return null;
  }

  static String _friendlyProbeError(String stderr) {
    final s = stderr.toLowerCase();
    if (s.contains('permission denied')) {
      return '파일을 열 권한이 없습니다.';
    }
    if (s.contains('invalid data found') || s.contains('moov atom not found')) {
      return '파일이 손상되었거나 지원하지 않는 형식입니다.';
    }
    if (s.contains('no such file')) {
      return '파일을 찾을 수 없습니다.';
    }
    return '영상 정보를 읽을 수 없습니다.';
  }

  static int? _toInt(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.round();
    if (v is String) {
      if (v == 'N/A' || v.trim().isEmpty) return null;
      return int.tryParse(v) ?? double.tryParse(v)?.round();
    }
    return null;
  }

  static double? _toDouble(Object? v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) {
      if (v == 'N/A' || v.trim().isEmpty) return null;
      return double.tryParse(v);
    }
    return null;
  }
}
