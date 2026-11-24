import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'audio_track.dart';

// 이 파일은 dart:ui / flutter 를 쓰지 않는다(tool/play_audio_check.dart 가 씀).

/// [AudioOut.start] 를 부른 뒤 실제로 스피커에서 소리가 나기까지 걸리는 시간(ms).
///
/// 소리 장치 지연 보정값. PlaySoundW 는 파일을 열고 장치를 깨우느라 호출 순간보다
/// 늦게 소리가 나므로, 화면 시계는 소리를 튼 뒤 이만큼 늦게 출발시키고 끝에서
/// 소리를 끄는 것도 이만큼 미룬다(마지막 소리가 잘리지 않게). 장치마다 다르다
/// (블루투스는 훨씬 크다).
const int kAudioLeadMs = 60;

/// 진행 중인 [AudioOut.prepare] 를 중간에 그만두게 하는 표식. 재생을 멈추거나 새로
/// 시작하면 앞 재생의 준비 작업이 큰 파일을 끝까지 읽고 쓰지 않도록 쓴다.
class AudioCancel {
  bool cancelled = false;
  void cancel() => cancelled = true;
}

/// 소리를 낼 준비가 끝난 조각 파일 하나.
class AudioChunk {
  final String path;

  /// 이 조각이 원본의 몇 초부터 몇 초까지인가.
  final double startSec;
  final double endSec;

  const AudioChunk(this.path, this.startSec, this.endSec);
}

/// 윈도우 기본 소리 장치로 WAV 를 내보낸다.
///
/// 네이티브 플러그인 없이 윈도우 winmm 의 `PlaySoundW` 를 FFI 로 부른다.
/// PlaySound 는 "파일 처음부터 끝까지" 밖에 못 틀기 때문에, 원하는 시각부터 시작하려면 그 지점부터의
/// PCM 을 잘라 작은 WAV(조각)로 따로 써서 튼다.
///
/// 조각은 최대 10분(22050 Hz 모노면 26MB)이고, 더 길면 ClipPlayer 가 다음 조각을 이어 튼다.
///
/// 어떤 경우에도 호출한 쪽으로 예외를 던지지 않는다. 소리가 안 나도 화면은
/// 계속 재생되어야 한다.
class AudioOut {
  /// 조각 최대 길이. 테스트에서 줄여 "다음 조각 이어 틀기" 를 확인한다.
  static double maxChunkSec = 600;

  /// 재생을 시작할 때 쓰는 첫 조각의 길이. 큰 조각은 읽고 쓰는 동안 시작이 늦어지므로
  /// 짧게 써서 바로 틀고, 뒤는 ClipPlayer 가 미리 쓴다(끝나기 20초 전부터).
  /// 조각이 바뀌는 순간 소리가 끊기므로 너무 짧게 잡지 않는다.
  static double firstChunkSec = 180;

  /// 이 크기(바이트) 이상인 조각은 읽기·크기 조절·쓰기를 다른 isolate 에서 한다.
  /// 작은 것은 isolate 를 띄우는 비용이 더 크다.
  static const int _isolateBytes = 1 << 20;

  /// [start] 가 소리를 튼 횟수(테스트용).
  static int startCount = 0;

  // mmsystem.h 의 값.
  static const int _sndAsync = 0x0001;
  static const int _sndNoDefault = 0x0002;
  static const int _sndFilename = 0x00020000;

  static bool _looked = false;
  static int Function(int, int, int)? _playSound;
  static int Function(int, int)? _localAlloc;
  static int Function(int)? _localFree;

  /// 마지막으로 넘긴 경로 문자열 메모리. winmm 이 비동기로 파일을 여는 동안
  /// 사라지면 안 되므로 다음 호출 때까지 들고 있는다.
  static int _pathBuf = 0;

  /// 지금 소리를 내고 있는(또는 마지막으로 낸) 조각 파일. 잠겨 있을 수 있어서
  /// 다음 조각은 다른 이름으로 쓴다.
  static String? _playingPath;
  static int _seq = 0;

  /// 마지막으로 튼 조각이 아직 멈추지 않았는가(소리가 끝까지 나서 저절로
  /// 멈춘 경우는 알 수 없다 — PlaySound 가 알려주지 않는다).
  static bool get started => _playingPath != null;

  static void _lookup() {
    if (_looked) return;
    _looked = true;
    if (!Platform.isWindows) return;
    try {
      final winmm = DynamicLibrary.open('winmm.dll');
      final k32 = DynamicLibrary.open('kernel32.dll');
      _playSound = winmm.lookupFunction<Int32 Function(IntPtr, IntPtr, Uint32),
          int Function(int, int, int)>('PlaySoundW');
      _localAlloc = k32.lookupFunction<IntPtr Function(Uint32, IntPtr),
          int Function(int, int)>('LocalAlloc');
      _localFree = k32.lookupFunction<IntPtr Function(IntPtr),
          int Function(int)>('LocalFree');
    } on Object {
      _playSound = null;
    }
  }

  static Directory _dir(AudioTrack t) => Directory(p.dirname(t.wavPath));

  static (int, int) _range(
      AudioTrack t, double fromSec, double? untilSec, double maxSec) {
    final from = fromSec < 0 ? 0.0 : fromSec;
    var end = from + maxSec;
    if (untilSec != null && untilSec < end) end = untilSec;
    // 샘플 경계(짝수 바이트)에 맞춘다. 홀수면 소리가 지직거리는 잡음이 된다.
    var startByte = (from * t.sampleRate).floor() * 2;
    var endByte = (end * t.sampleRate).ceil() * 2;
    if (endByte > t.dataBytes) endByte = t.dataBytes;
    if (startByte > endByte) startByte = endByte;
    return (startByte, endByte);
  }

  static Uint8List _header(int dataBytes, int sampleRate) {
    final h = ByteData(44);
    void tag(int at, String s) {
      for (var i = 0; i < 4; i++) {
        h.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    h.setUint32(4, 36 + dataBytes, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    h.setUint32(16, 16, Endian.little);
    h.setUint16(20, 1, Endian.little); // PCM
    h.setUint16(22, 1, Endian.little); // 모노
    h.setUint32(24, sampleRate, Endian.little);
    h.setUint32(28, sampleRate * 2, Endian.little);
    h.setUint16(32, 2, Endian.little);
    h.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    h.setUint32(40, dataBytes, Endian.little);
    return h.buffer.asUint8List();
  }

  /// [fromSec] 부터의 조각을 미리 써 둔다. 틀지는 않는다. 실패하면 null.
  ///
  /// 첫 화면이 준비되는 순간에는 [start] 만 부르면 되도록, ffmpeg 이 뜨는 동안
  /// 미리 불러 둔다. 그래야 소리가 화면보다 늦게 시작하지 않는다.
  ///
  /// [gain] 은 편집 창에서 고른 소리 크기(작게·크게)를 미리 들려주기 위한 배율.
  ///
  /// [first] 가 true 면 조각을 [firstChunkSec] 로 짧게 자른다(재생 시작용).
  /// [cancel] 이 취소되면 가능한 빨리 null 로 끝낸다.
  static Future<AudioChunk?> prepare(AudioTrack t, double fromSec,
      {double? untilSec,
      double gain = 1.0,
      bool first = false,
      AudioCancel? cancel}) async {
    try {
      final maxSec = first && firstChunkSec < maxChunkSec
          ? firstChunkSec
          : maxChunkSec;
      final (startByte, endByte) = _range(t, fromSec, untilSec, maxSec);
      final n = endByte - startByte;
      if (n <= 0 || (cancel?.cancelled ?? false)) return null;
      final sr = t.sampleRate * 2;
      // 틀고 있는 파일은 winmm 이 잡고 있을 수 있다. 다른 이름으로 돌아가며 쓴다.
      final dir = _dir(t);
      for (var attempt = 0; attempt < 6; attempt++) {
        final path = p.join(dir.path, 'play_${_seq++ % 6}.wav');
        if (path == _playingPath) continue;
        if (cancel?.cancelled ?? false) return null;
        final src = t.wavPath;
        final off = t.dataOffset + startByte;
        final rate = t.sampleRate;
        // 읽기·배율 곱하기·쓰기는 큰 조각이면 UI 가 있는 isolate 를 몇십~몇백 ms
        // 붙잡는다. 큰 조각은 따로 돌린다.
        final ok = n >= _isolateBytes
            ? await _buildInIsolate(src, off, n, rate, gain, path)
            : _buildChunk(src, off, n, rate, gain, path);
        if (cancel?.cancelled ?? false) return null;
        if (ok) return AudioChunk(path, startByte / sr, endByte / sr);
        // 읽기 실패와 잠겨서 못 쓴 경우를 구분하지 못한다. 다음 이름으로 한 번 더
        // 해 보고, 그래도 안 되면 null.
      }
      return null;
    } on Object {
      return null;
    }
  }

  /// 클로저를 인자만 있는 정적 함수 안에서 만든다. async 메서드 안에서 만들면 그
  /// 메서드의 다른 지역 변수(Directory 등)까지 붙잡혀 isolate 로 못 보낸다.
  static Future<bool> _buildInIsolate(String srcPath, int srcOffset, int n,
          int sampleRate, double gain, String outPath) =>
      Isolate.run(
          () => _buildChunk(srcPath, srcOffset, n, sampleRate, gain, outPath));

  /// 원본 WAV 의 [n] 바이트를 읽어 배율을 곱하고 머리말을 붙여 [outPath] 에 쓴다.
  /// 다른 isolate 에서도 돌 수 있도록 인자만 쓰는 정적 함수다.
  static bool _buildChunk(String srcPath, int srcOffset, int n, int sampleRate,
      double gain, String outPath) {
    RandomAccessFile? raf;
    try {
      final buf = Uint8List(44 + n);
      buf.setRange(0, 44, _header(n, sampleRate));
      raf = File(srcPath).openSync();
      raf.setPositionSync(srcOffset);
      var got = 0;
      while (got < n) {
        final r = raf.readIntoSync(buf, 44 + got, 44 + n);
        if (r <= 0) break;
        got += r;
      }
      if (got < n) return false;
      _applyGain(buf, 44, n, gain);
      File(outPath).writeAsBytesSync(buf, flush: false);
      return true;
    } on Object {
      return false;
    } finally {
      try {
        raf?.closeSync();
      } on Object {
        // 무시
      }
    }
  }

  /// 결과물은 ffmpeg 의 volume+alimiter 로 만들므로, 여기서는 넘치는 값만
  /// 잘라 내는 단순한 방식으로 비슷하게 들려준다. 배율은 전역 값이 아니라
  /// 호출마다 받는다(한 번의 재생 안에서는 이어지는 조각도 같은 크기여야 한다).
  static void _applyGain(Uint8List buf, int offset, int length, double g) {
    if ((g - 1.0).abs() < 1e-6) return;
    final bd = ByteData.sublistView(buf, offset, offset + length);
    for (var i = 0; i + 1 < length; i += 2) {
      final v = (bd.getInt16(i, Endian.little) * g).round();
      bd.setInt16(i, v > 32767 ? 32767 : (v < -32768 ? -32768 : v),
          Endian.little);
    }
  }

  /// 미리 써 둔 조각을 튼다. 앞서 나던 소리는 끊긴다.
  static bool start(AudioChunk c) {
    // 끝에서 미뤄 둔 정지가 새 소리를 끄지 않게 한다.
    _pendingStop?.cancel();
    _pendingStop = null;
    try {
      _lookup();
      final play = _playSound;
      final alloc = _localAlloc;
      final free = _localFree;
      if (play == null || alloc == null || free == null) return false;
      final units = c.path.codeUnits;
      // LPTR(0x40): 0 으로 채운 메모리. 끝의 널 문자 자리까지 잡는다.
      final mem = alloc(0x40, (units.length + 1) * 2);
      if (mem == 0) return false;
      final view = Pointer<Uint16>.fromAddress(mem).asTypedList(units.length + 1);
      view.setRange(0, units.length, units);
      view[units.length] = 0;
      final ok = play(mem, 0, _sndFilename | _sndAsync | _sndNoDefault) != 0;
      final old = _pathBuf;
      _pathBuf = mem;
      if (old != 0) free(old);
      if (ok) {
        _playingPath = c.path;
        startCount++;
      }
      return ok;
    } on Object {
      return false;
    }
  }

  /// 조각을 바로 써서 바로 튼다. 간단히 쓸 때용(쓰는 시간만큼 늦게 시작한다).
  ///
  /// 화면과 맞춰야 하는 재생은 [prepare] 를 먼저 하고 [start] 를 쓴다.
  static Future<bool> playFrom(AudioTrack t, double fromSec,
      {double? untilSec, double gain = 1.0}) async {
    final c = await prepare(t, fromSec, untilSec: untilSec, gain: gain);
    if (c == null) return false;
    return start(c);
  }

  static Timer? _pendingStop;

  /// [stopAfter] 로 미뤄 둔 정지가 아직 안 불렸는가.
  static bool get stopPending => _pendingStop != null;

  /// 끝까지 다 튼 경우의 정지. 화면 시계가 끝에 닿은 순간에는 소리가 아직 장치
  /// 안에서 [kAudioLeadMs] 만큼 남아 있어서 바로 끄면 마지막이 잘린다. 그만큼
  /// 기다렸다 끈다. 그 사이에 [start] 나 [stop] 이 불리면 취소된다.
  /// 사용자가 멈춘 경우에는 [stop] 을 쓴다(바로 꺼야 한다).
  static void stopAfter(Duration d) {
    _pendingStop?.cancel();
    _pendingStop = Timer(d, () {
      _pendingStop = null;
      stop();
    });
  }

  /// 소리를 멈춘다. 나는 소리가 없어도 괜찮다.
  static void stop() {
    _pendingStop?.cancel();
    _pendingStop = null;
    try {
      _lookup();
      final play = _playSound;
      if (play == null) return;
      play(0, 0, 0);
      _playingPath = null;
    } on Object {
      // 무시
    }
  }
}
