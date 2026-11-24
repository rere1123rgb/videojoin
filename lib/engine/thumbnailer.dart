import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'ffmpeg_tools.dart';
import 'models.dart';

/// 목록용 미리보기 썸네일을 만든다. 작게 줄여 뽑고 디스크에 캐시한다.
///
/// 사용자 지정 회전은 반영하지 않는다 — 화면에서 이미지를 돌려 보여주면
/// 회전할 때마다 다시 뽑을 필요가 없다.
class Thumbnailer {
  final FFTools tools;

  Thumbnailer(this.tools);

  static Directory cacheDirectory() {
    final base = Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.systemTemp.path;
    final dir = Directory(p.join(base, 'videojoin', 'thumbs'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 경로 + 크기 + 수정시각 키. 같은 이름의 다른 파일이면 옛 썸네일을 쓰지 않는다.
  static String _key(VideoSpec spec) {
    final src = '${spec.path}|${spec.fileSize}|'
        '${spec.fileModified.millisecondsSinceEpoch}';
    var hash = 0x811c9dc5;
    for (final unit in utf8.encode(src)) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  Future<String?> generate(VideoSpec spec, {int width = 320}) async {
    if (!spec.ok) return null;

    final outPath = p.join(cacheDirectory().path, '${_key(spec)}.jpg');
    final f = File(outPath);
    if (f.existsSync() && f.lengthSync() > 0) return outPath;

    // 맨 앞은 검은 화면/페이드인인 경우가 많아 살짝 뒤에서 뽑는다.
    final seek = (spec.durationSec * 0.12).clamp(0.0, 8.0);

    final res = await runCaptured(
      tools.ffmpegPath,
      [
        '-hide_banner',
        '-nostdin',
        '-y',
        // -ss 를 -i 앞에 두면 키프레임 단위로 빠르게 건너뛴다.
        '-ss', seek.toStringAsFixed(3),
        '-i', spec.path,
        '-frames:v', '1',
        // 4K 를 그대로 디코딩하지 않도록 바로 줄인다.
        '-vf', 'scale=$width:-2:flags=fast_bilinear',
        '-q:v', '5',
        outPath,
      ],
      timeout: const Duration(seconds: 30),
    );

    if (res.ok && f.existsSync() && f.lengthSync() > 0) return outPath;

    // 짧거나 깨진 영상은 첫 프레임으로 한 번 더 시도한다.
    final retry = await runCaptured(
      tools.ffmpegPath,
      [
        '-hide_banner',
        '-nostdin',
        '-y',
        '-i', spec.path,
        '-frames:v', '1',
        '-vf', 'scale=$width:-2:flags=fast_bilinear',
        '-q:v', '5',
        outPath,
      ],
      timeout: const Duration(seconds: 30),
    );

    if (retry.ok && f.existsSync() && f.lengthSync() > 0) return outPath;
    return null;
  }

  static void prune({int keep = 200}) {
    try {
      final files = cacheDirectory().listSync().whereType<File>().toList()
        ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      for (final f in files.skip(keep)) {
        try {
          f.deleteSync();
        } on Object {
          // 무시
        }
      }
    } on Object {
      // 무시
    }
  }
}
