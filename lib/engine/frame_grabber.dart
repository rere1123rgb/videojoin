import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'ffmpeg_tools.dart';
import 'models.dart';

/// 편집 화면용 "이 시각의 한 장면" 뽑기. 재생기 대신 ffmpeg 으로 프레임을 한 장씩 뽑는다.
///
/// **자를 때와 같은 방식으로 찾아간다.** `-ss` 를 `-i` 앞에 두면 앞의 키프레임부터
/// 풀어 정확한 시각의 프레임을 주며, 실제 자르기도 같은 구조라 본 장면에서 정확히 시작한다.
///
/// 편집 화면에서 수백 장이 생기므로, 목록 썸네일이 정리되지 않게 캐시 폴더를 나눈다.
class FrameGrabber {
  final FFTools tools;

  FrameGrabber(this.tools);

  /// 동시에 돌리는 ffmpeg 수. 더 띄우면 디스크 읽기가 겹쳐 오히려 느려진다.
  static const int _maxParallel = 6;
  static int _running = 0;
  static final List<Completer<void>> _waiters = [];

  static Directory cacheDirectory() {
    final base = Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.systemTemp.path;
    final dir = Directory(p.join(base, 'videojoin', 'frames'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static String _fileKey(VideoSpec spec) {
    final src = '${spec.path}|${spec.fileSize}|'
        '${spec.fileModified.millisecondsSinceEpoch}';
    var hash = 0x811c9dc5;
    for (final unit in utf8.encode(src)) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  static Future<void> _acquire() async {
    if (_running < _maxParallel) {
      _running++;
      return;
    }
    final c = Completer<void>();
    _waiters.add(c);
    await c.future;
    _running++;
  }

  static void _release() {
    _running--;
    if (_waiters.isNotEmpty) _waiters.removeAt(0).complete();
  }

  /// [sec] 초 지점의 장면 한 장. 실패하면 null.
  ///
  /// [waitTurn] 이 false 면 줄을 서지 않는다 (지금 보려는 큰 장면이 장면 띠를 기다리면 안 된다).
  Future<String?> frameAt(VideoSpec spec, double sec,
      {int width = 960, bool waitTurn = true}) async {
    if (!spec.ok) return null;
    final ms = (sec * 1000).round().clamp(0, 1 << 40);
    final outPath =
        p.join(cacheDirectory().path, '${_fileKey(spec)}_${ms}_$width.jpg');
    final f = File(outPath);
    if (f.existsSync() && f.lengthSync() > 0) return outPath;

    if (waitTurn) await _acquire();
    try {
      // 맨 끝 시각은 프레임이 없을 수 있어 조금씩 앞으로 당겨 재시도한다.
      for (final back in const [0.0, 0.3, 1.0]) {
        final t = (sec - back) < 0 ? 0.0 : sec - back;
        final res = await runCaptured(
          tools.ffmpegPath,
          [
            '-hide_banner',
            '-nostdin',
            '-y',
            '-ss', t.toStringAsFixed(3),
            '-i', spec.path,
            '-frames:v', '1',
            '-an',
            '-vf', 'scale=$width:-2:flags=bilinear',
            '-q:v', '4',
            outPath,
          ],
          timeout: const Duration(seconds: 30),
        );
        if (res.ok && f.existsSync() && f.lengthSync() > 0) return outPath;
      }
      return null;
    } on Object {
      return null;
    } finally {
      if (waitTurn) _release();
    }
  }

  /// 영상을 [count] 칸으로 나눠 각 칸 가운데 장면을 뽑는다.
  Future<List<String?>> filmstrip(VideoSpec spec, int count,
      {int width = 200}) {
    final d = spec.durationSec;
    return Future.wait([
      for (var i = 0; i < count; i++)
        frameAt(spec, d <= 0 ? 0 : d * (i + 0.5) / count, width: width),
    ]);
  }

  static void prune({int keep = 1500}) {
    try {
      final files = cacheDirectory().listSync().whereType<File>().toList()
        ..sort(
            (a, b) => b.statSync().modified.compareTo(a.statSync().modified));
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
