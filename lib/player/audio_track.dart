import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../engine/ffmpeg_tools.dart';
import '../engine/models.dart';
import '../engine/suspend.dart';

// 이 파일은 dart:ui / flutter 를 쓰지 않는다. `dart run` 으로 도는 소리 확인
// 스크립트(tool/play_audio_check.dart)가 그대로 가져다 쓰기 때문이다.

/// 편집 화면에서 들려줄 소리 한 줄과 그 파형.
class AudioTrack {
  /// 22050 Hz 모노 16비트 WAV.
  final String wavPath;

  /// 소리 길이(초). WAV 의 실제 샘플 수로 잰 값이다.
  final double durationSec;

  /// 칸마다 가장 큰 소리(0..1). 가장 큰 칸이 1.0 이다. 완전히 조용하면 전부 0.
  final List<double> peaks;

  /// PCM 이 시작하는 바이트 위치. ffmpeg 이 data 앞에 LIST 를 끼워 넣을 수
  /// 있어서 44 로 못 박지 않는다.
  final int dataOffset;

  /// PCM 바이트 수.
  final int dataBytes;

  final int sampleRate;

  const AudioTrack({
    required this.wavPath,
    required this.durationSec,
    required this.peaks,
    required this.dataOffset,
    required this.dataBytes,
    this.sampleRate = AudioPrep.sampleRate,
  });
}

/// WAV 머리말을 읽은 결과.
class WavInfo {
  final int dataOffset;
  final int dataBytes;
  final int sampleRate;
  final int channels;
  final int bitsPerSample;

  const WavInfo(this.dataOffset, this.dataBytes, this.sampleRate, this.channels,
      this.bitsPerSample);
}

/// 원본 영상에서 소리를 뽑아 WAV 로 두고, 파형을 계산한다.
///
/// 소리를 22050 Hz 모노로 줄이는 이유: 편집 화면에서 "여기서 말이 끝나는구나"
/// 를 듣는 용도라 음질은 필요 없고, 1시간짜리도 160MB 정도라 캐시에 둘 만하다.
/// 결과는 캐시에 남겨 같은 파일을 다시 열면 바로 쓴다.
class AudioPrep {
  static const int sampleRate = 22050;

  final FFTools tools;

  /// 테스트에서 사용자의 실제 캐시를 건드리지 않으려고 바꿔 끼운다.
  final Directory? cacheDirOverride;

  AudioPrep(this.tools, {this.cacheDirOverride});

  /// 같은 파일을 동시에 두 번 준비하면 반쯤 쓴 파일을 캐시로 착각할 수 있다.
  /// 진행 중인 작업은 하나만 두고 나머지는 그 결과를 기다린다.
  ///
  /// 키는 wav 경로만이다. 칸 수(buckets)까지 키에 넣으면 칸 수가 다른 두 호출이
  /// 같은 `.wav.part` 에 동시에 ffmpeg 두 개를 쓰게 된다. 칸 수는 파형 계산에만
  /// 쓰이므로 [_prepare] 안에서 따로 받는다.
  static final Map<String, Future<void>> _extracting = {};
  static final Map<String, Future<AudioTrack?>> _inFlight = {};

  /// ffmpeg 으로 실제로 뽑은 횟수(캐시를 썼는지 테스트에서 확인하는 용도).
  static int extractCount = 0;

  static Directory cacheDirectory() {
    final base = Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.systemTemp.path;
    final dir = Directory(p.join(base, 'videojoin', 'audio'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Directory _dir() {
    final o = cacheDirOverride;
    if (o == null) return cacheDirectory();
    if (!o.existsSync()) o.createSync(recursive: true);
    return o;
  }

  /// frame_grabber.dart 와 같은 방식의 키. 파일이 바뀌면(크기·수정 시각) 새로 뽑는다.
  static String fileKey(VideoSpec spec) {
    final src = '${spec.path}|${spec.fileSize}|'
        '${spec.fileModified.millisecondsSinceEpoch}';
    var hash = 0x811c9dc5;
    for (final unit in utf8.encode(src)) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  /// 소리를 준비한다. 소리가 없거나 실패하면 null. 예외는 던지지 않는다.
  Future<AudioTrack?> prepare(VideoSpec spec, {int buckets = 1200}) {
    if (!spec.ok || !spec.hasAudio) return Future.value(null);
    final String wavPath;
    try {
      wavPath = p.join(_dir().path, '${fileKey(spec)}.wav');
    } on Object {
      return Future.value(null);
    }
    // 칸 수가 같은 호출은 결과까지 공유하고, 다르면 뽑기만 공유한다.
    final flightKey = '$wavPath|$buckets';
    final existing = _inFlight[flightKey];
    if (existing != null) return existing;
    final f = _prepare(spec, wavPath, buckets).catchError((Object _) => null);
    _inFlight[flightKey] = f;
    f.whenComplete(() => _inFlight.remove(flightKey));
    return f;
  }

  Future<AudioTrack?> _prepare(
      VideoSpec spec, String wavPath, int buckets) async {
    final wav = File(wavPath);
    // 다른 호출이 이 wav 를 뽑는 중이면 끝나기를 기다린 뒤 캐시를 쓴다.
    final running = _extracting[wavPath];
    if (running != null) {
      try {
        await running;
      } on Object {
        // 무시: 아래에서 캐시가 없으면 직접 뽑는다.
      }
    }
    if (!(wav.existsSync() && wav.lengthSync() > 44)) {
      final done = Completer<void>();
      _extracting[wavPath] = done.future;
      try {
        if (!await _extract(spec, wavPath, wav)) return null;
      } finally {
        _extracting.remove(wavPath);
        done.complete();
      }
    } else {
      // 최근에 쓴 것을 남기도록 정리 순서를 갱신한다.
      try {
        wav.setLastModifiedSync(DateTime.now());
      } on Object {
        // 무시
      }
    }
    return _analyzeTrack(wavPath, buckets);
  }

  /// ffmpeg 으로 소리를 뽑아 [wav] 로 둔다. 실패하면 false.
  Future<bool> _extract(VideoSpec spec, String wavPath, File wav) async {
    // 다 쓴 다음에만 제 이름을 붙인다. 중간에 앱이 꺼져도 반쪽 파일이
    // 캐시로 남지 않는다.
    final part = File('$wavPath.part');
    try {
      if (part.existsSync()) part.deleteSync();
    } on Object {
      // 다른 곳에서 쓰는 중이면 아래 ffmpeg 이 실패하고 false 로 끝난다.
    }
    extractCount++;
    final res = await runCaptured(
      tools.ffmpegPath,
      [
        '-hide_banner', '-nostdin', '-v', 'error', '-y',
        '-i', spec.path,
        '-map', '0:a:0',
        '-vn', '-sn', '-dn',
        '-map_metadata', '-1',
        // 소리가 영상보다 조금 늦게 시작하는 파일이 있다. 앞을 무음으로
        // 채워 WAV 의 0초가 원본의 0초와 같게 맞춘다. 그래야 화면과 맞는다.
        '-af', 'aresample=async=1:first_pts=0',
        '-ac', '1',
        '-ar', '$sampleRate',
        '-c:a', 'pcm_s16le',
        '-f', 'wav',
        part.path,
      ],
      timeout: const Duration(minutes: 30),
      // 몇 분 걸릴 수 있는 일이다. 그동안 창을 닫아도 ffmpeg 이 남아 .part 를
      // 붙잡고 있지 않게 앱 수명에 묶는다.
      onStarted: ProcessGuard.attach,
    );
    if (!res.ok || !part.existsSync() || part.lengthSync() <= 44) {
      try {
        if (part.existsSync()) part.deleteSync();
      } on Object {
        // 무시
      }
      return false;
    }
    try {
      if (wav.existsSync()) wav.deleteSync();
      part.renameSync(wavPath);
    } on Object {
      return false;
    }
    return true;
  }

  Future<AudioTrack?> _analyzeTrack(String wavPath, int buckets) async {
    // 파형 계산은 1시간짜리면 1억 샘플이 넘는다. 화면이 멈추지 않게 따로 돌린다.
    final result = await _analyzeInIsolate(wavPath, buckets);
    if (result == null) return null;
    final info = result.$1;
    final dur = info.dataBytes / (info.sampleRate * info.channels * 2);
    return AudioTrack(
      wavPath: wavPath,
      durationSec: dur,
      peaks: result.$2,
      dataOffset: info.dataOffset,
      dataBytes: info.dataBytes,
      sampleRate: info.sampleRate,
    );
  }

  /// WAV 머리말을 읽는다. 16비트 PCM 이 아니면 null.
  ///
  /// RIFF 조각을 순서대로 건너뛰며 'fmt ' 와 'data' 를 찾는다. 조각 크기가
  /// 홀수면 1바이트 채움이 붙는다. data 크기가 0 이나 0xFFFFFFFF(스트리밍으로
  /// 써서 크기를 못 채운 경우)거나 파일보다 크면 파일 끝까지로 본다.
  static WavInfo? parseHeader(RandomAccessFile raf) {
    final len = raf.lengthSync();
    if (len < 12) return null;
    raf.setPositionSync(0);
    final head = raf.readSync(12);
    if (head.length < 12 ||
        ascii.decode(head.sublist(0, 4), allowInvalid: true) != 'RIFF' ||
        ascii.decode(head.sublist(8, 12), allowInvalid: true) != 'WAVE') {
      return null;
    }
    var pos = 12;
    int? rate, channels, bits, fmtTag;
    while (pos + 8 <= len) {
      raf.setPositionSync(pos);
      final ch = raf.readSync(8);
      if (ch.length < 8) return null;
      final id = ascii.decode(ch.sublist(0, 4), allowInvalid: true);
      final size = ByteData.sublistView(ch).getUint32(4, Endian.little);
      final body = pos + 8;
      if (id == 'fmt ') {
        final f = raf.readSync(size < 16 ? 16 : (size > 64 ? 64 : size));
        if (f.length < 16) return null;
        final bd = ByteData.sublistView(f);
        fmtTag = bd.getUint16(0, Endian.little);
        channels = bd.getUint16(2, Endian.little);
        rate = bd.getUint32(4, Endian.little);
        bits = bd.getUint16(14, Endian.little);
      } else if (id == 'data') {
        // 1 = PCM, 0xFFFE = WAVE_FORMAT_EXTENSIBLE(안은 PCM 이라고 믿는다).
        if (rate == null || channels == null || bits != 16) return null;
        if (fmtTag != 1 && fmtTag != 0xFFFE) return null;
        var bytes = size;
        if (bytes == 0 || bytes == 0xFFFFFFFF || body + bytes > len) {
          bytes = len - body;
        }
        final frame = channels * 2;
        bytes -= bytes % frame;
        return WavInfo(body, bytes, rate, channels, bits!);
      }
      pos = body + size + (size.isOdd ? 1 : 0);
    }
    return null;
  }

  /// 클로저를 정적 함수 안에서 만든다. async 메서드 안에서 만들면 그 메서드의
  /// 다른 지역 변수까지 붙잡혀 isolate 로 못 보내는 일이 생긴다.
  static Future<(WavInfo, List<double>)?> _analyzeInIsolate(
          String path, int buckets) =>
      Isolate.run(() => _analyze(path, buckets));

  /// 파일 전체를 훑어 칸마다 가장 큰 |샘플| 을 구한다. 별도 isolate 에서 돈다.
  static (WavInfo, List<double>)? _analyze(String path, int buckets) {
    RandomAccessFile? raf;
    try {
      raf = File(path).openSync();
      final info = parseHeader(raf);
      if (info == null || buckets <= 0) return null;
      final frameBytes = info.channels * 2;
      final total = info.dataBytes ~/ frameBytes;
      final maxes = Int32List(buckets);
      if (total > 0) {
        raf.setPositionSync(info.dataOffset);
        // 4MB 씩 읽는다. 정렬 문제를 피하려고 Int16List 뷰 대신 ByteData 로 읽는다.
        const chunk = 4 << 20;
        var idx = 0; // 지금까지 읽은 샘플 프레임 수
        var remaining = total * frameBytes;
        while (remaining > 0) {
          final want = remaining < chunk ? remaining : chunk;
          final buf = raf.readSync(want - want % frameBytes);
          if (buf.isEmpty) break;
          final bd = ByteData.sublistView(buf);
          final n = buf.length ~/ frameBytes;
          for (var i = 0; i < n; i++) {
            var v = bd.getInt16(i * frameBytes, Endian.little);
            if (v < 0) v = -v;
            final b = (idx * buckets) ~/ total;
            if (v > maxes[b]) maxes[b] = v;
            idx++;
          }
          remaining -= buf.length;
        }
      }
      var top = 0;
      for (final m in maxes) {
        if (m > top) top = m;
      }
      final peaks = List<double>.filled(buckets, 0);
      if (top > 0) {
        for (var i = 0; i < buckets; i++) {
          peaks[i] = maxes[i] / top;
        }
      }
      return (info, peaks);
    } on Object {
      return null;
    } finally {
      try {
        raf?.closeSync();
      } on Object {
        // 무시
      }
    }
  }

  /// 오래된 소리 파일 정리. 최근에 쓴 것부터 [keepBytes] 까지만 남긴다.
  ///
  /// 앱을 막 켰을 때 부른다(그때는 재생도 소리 뽑기도 없다). 그래서 재생용 조각
  /// 파일(`play_*.wav`)과 중간에 끊긴 `.part` 는 나이와 상관없이 지운다 — 안 그러면
  /// 조각이 영영 쌓이고(10분이면 26MB), 앱이 죽으며 남은 `.part` 는 용량 계산에도
  /// 안 잡힌다. 다른 창이 쓰는 중이라 잠겨 있으면 지워지지 않고 넘어간다.
  static void prune({int keepBytes = 2 << 30, Directory? dir}) {
    try {
      final d = dir ?? cacheDirectory();
      final files = <File>[];
      for (final e in d.listSync()) {
        if (e is! File) continue;
        final name = p.basename(e.path);
        if ((name.startsWith('play_') && name.endsWith('.wav')) ||
            name.endsWith('.part')) {
          try {
            e.deleteSync();
          } on Object {
            // 잠겨 있다(다른 창이 쓰는 중). 다음 번에.
          }
          continue;
        }
        files.add(e);
      }
      files.sort(
          (a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      var used = 0;
      for (final f in files) {
        int size;
        try {
          size = f.lengthSync();
        } on Object {
          continue;
        }
        used += size;
        if (used > keepBytes) {
          try {
            f.deleteSync();
          } on Object {
            // 재생 중이라 잠겨 있으면 다음 번에 지운다.
          }
        }
      }
    } on Object {
      // 무시
    }
  }
}
