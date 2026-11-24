import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../engine/ffmpeg_tools.dart';
import '../engine/models.dart';
import 'audio_out.dart';
import 'audio_track.dart';
import 'frame_pump.dart';

/// 편집 화면 안에서 소리와 함께 영상을 틀어 준다.
///
/// 재생 플러그인 없이(네이티브 빌드 불가) ffmpeg 이 풀어 준 그림을 받아
/// 한 장씩 바꿔 보여주고, 소리는 [AudioOut] 으로 윈도우에 맡긴다.
/// 실제 일은 [FramePump] 가 하고, 여기서는 바이트를 그림으로 바꾸고 화면에
/// 알릴 값(현재 그림, 위치, 재생 중인지)을 관리한다.
///
/// 소리와 화면은 같은 순간에 출발시킨다: 첫 그림과 소리 조각이 둘 다 준비된
/// 순간 소리를 틀고, 소리가 장치에서 들리기 시작하는 시간([kAudioLeadMs])만큼
/// 뒤에 시계를 돌린다. 그 뒤로는 시계를 기준으로 그림을 고르므로
/// 그림 변환이 밀려도 소리와 점점 어긋나지 않는다(늦은 그림은 버린다).
///
/// 디코딩 자체가 실시간보다 느린 영상(느린 PC 의 4K HEVC·HDR)은 시계를 따라가지
/// 못하고 화면만 점점 늦어진다. 그러면 소리는 그대로 두고 화면만 지금 시각부터,
/// 더 작은 크기로 다시 띄운다([lagging]).
class ClipPlayer {
  final FFTools tools;
  final VideoSpec spec;

  /// 소리. 준비가 늦게 끝나면 나중에 넣어도 된다 — 다음 [play] 부터 쓴다.
  AudioTrack? audio;

  /// 지금 보여줄 그림. 그림은 이 객체가 갖고 있다가 버린다(dispose).
  /// 화면 쪽에서 dispose 하지 말 것.
  final ValueNotifier<ui.Image?> frame = ValueNotifier<ui.Image?>(null);

  /// 원본 기준 현재 위치(초). 시계를 따라가므로 화면이 늦어도 소리와 같이 간다.
  final ValueNotifier<double> position = ValueNotifier<double>(0);

  final ValueNotifier<bool> playing = ValueNotifier<bool>(false);

  /// 영상이 느려서 화면을 줄여 보여주는 중이다. 화면에서 "느린 영상이라 화면을 줄여서
  /// 보여 줍니다" 같은 안내를 띄우는 데 쓴다. 재생이 끝나거나 새로 시작하면 꺼진다.
  final ValueNotifier<bool> lagging = ValueNotifier<bool>(false);

  /// [play] 에 준 끝(untilSec) 또는 파일 끝에 닿았을 때. [stop] 으로 멈추면 안 부른다.
  VoidCallback? onEnded;

  ClipPlayer({required this.tools, required this.spec})
      : geometry = PlayGeometry.of(spec);

  /// 재생 화면 크기와 초당 장수. 화면 쪽에서 비율을 잡을 때 쓴다.
  /// (느려서 줄여 다시 띄운 뒤에는 그림이 이보다 작아지지만 비율은 같다.)
  final PlayGeometry geometry;

  /// 테스트 전용: 처음 띄우는 ffmpeg 에만 끼울 입력 인자(`-readrate` 로 느린 디코더
  /// 흉내). 다시 띄운 것에는 안 끼운다 — 줄인 크기에서는 따라간다는 상황을 만든다.
  @visibleForTesting
  List<String> debugFirstPumpInputArgs = const [];

  /// 테스트 전용: 지금 재생기가 보여준 마지막 그림이 시계보다 얼마나 늦었나(초).
  @visibleForTesting
  double get debugLagSec => _pump?.lastLagSec ?? 0;

  /// 느려서 다시 띄울 때 쓰는 긴 변. 4K 를 960 으로 줄여 풀어도 못 따라가는
  /// PC 라면 그림 변환·복사 비용이 1/4 인 480 쯤은 되어야 한다.
  static const int lagLongSide = 480;

  /// 그림 변환 콜백이 이 시간 안에 안 오면 포기하고 다음 그림으로 간다.
  static const Duration decodeWatchdog = Duration(seconds: 2);

  FramePump? _pump;

  /// 재생할 때마다 1씩 오른다. 앞 재생에서 늦게 도착한 그림·알림을 걸러낸다.
  int _gen = 0;

  /// play/stop 명령 번호. 가장 마지막 명령만 효력이 있다.
  int _cmd = 0;
  bool _disposed = false;
  bool _audioOn = false;

  // 그림 변환은 한 번에 하나만. 밀리면 가장 최근 것만 남긴다.
  bool _decoding = false;

  /// 변환 요청마다 붙이는 번호. 콜백은 자기 번호가 최신일 때만 효력이 있다 —
  /// 워치독이 포기한 요청의 늦은 결과를 버리기 위해서다.
  int _decodeSeq = 0;
  Timer? _decodeTimer;
  Uint8List? _pendingBytes;
  PlayGeometry? _pendingGeo;
  int _pendingGen = 0;
  double _pendingPos = 0;

  /// 한 장 늦게 버릴 그림. 화면이 아직 이전 그림을 그리는 중일 수 있어서
  /// 바꾸자마자 버리지 않는다.
  ui.Image? _retired;

  // 오래 이어 틀 때 다음 소리 조각.
  AudioChunk? _chunk;
  Future<AudioChunk?>? _nextChunk;
  double? _audioUntil;
  double _gain = 1.0;

  /// 지금 재생의 소리 준비를 그만두게 하는 표식. 멈추거나 새로 틀면 취소한다.
  AudioCancel? _audioCancel;

  /// [fromSec] 부터 튼다. [untilSec] 를 주면 거기서 멈추고 [onEnded] 를 부른다.
  /// 이미 틀고 있으면 멈추고 새로 시작한다.
  ///
  /// [gain] 은 소리 크기 배율(편집 창의 소리 설정). 이 재생의 소리 조각에만 쓴다.
  Future<void> play(double fromSec,
      {double? untilSec, bool muted = false, double gain = 1.0}) async {
    if (_disposed) return;
    // 화면은 play/stop 을 기다리지 않고 연달아 부른다(버튼 연타, 막대 끌기).
    // 앞 재생이 끝나기를 기다리는 사이에 더 새로운 명령이 왔으면 이 명령은
    // 버린다. 안 그러면 두 재생이 함께 돌거나, 멈춤을 눌렀는데 다시 재생된다.
    final cmd = ++_cmd;
    await _halt();
    if (_disposed || cmd != _cmd) return;
    final gen = ++_gen;
    final from = fromSec < 0 ? 0.0 : fromSec;
    playing.value = true;
    position.value = from;

    // 시작과 거의 같은(또는 앞선) 끝이면 틀 것이 없다. ffmpeg 을 띄워 봐야 한 장
    // 받고 곧바로 끝나므로, 띄우지 않고 바로 끝난 것으로 한다.
    if (untilSec != null && untilSec <= from + 0.05) {
      _ended(gen, untilSec);
      return;
    }

    final a = muted ? null : audio;
    final audioEnd = a == null
        ? null
        : (untilSec == null || untilSec > a.durationSec
            ? a.durationSec
            : untilSec);
    _audioUntil = audioEnd;
    _gain = gain;
    final cancel = _audioCancel = AudioCancel();
    // 소리 조각은 ffmpeg 이 뜨는 동안 함께 써 둔다. 첫 조각은 짧게 써서(재생이 바로
    // 시작되도록) 큰 파일을 읽고 쓰느라 늦어지지 않게 하고, 뒤는
    // _maybeContinueAudio 가 이어서 쓴다.
    final chunkF = a == null || from >= audioEnd!
        ? null
        : AudioOut.prepare(a, from,
            untilSec: audioEnd, gain: gain, first: true, cancel: cancel);

    _startPump(gen,
        from: from,
        untilSec: untilSec,
        geo: geometry,
        audioTrack: a,
        chunkF: chunkF,
        restart: false);
    await _pump?.start();
  }

  void _startPump(
    int gen, {
    required double from,
    required double? untilSec,
    required PlayGeometry geo,
    required AudioTrack? audioTrack,
    required Future<AudioChunk?>? chunkF,
    required bool restart,
  }) {
    final pump = FramePump(
      tools: tools,
      spec: spec,
      fromSec: from,
      untilSec: untilSec,
      geometry: geo,
      // 다시 띄울 때는 소리가 계속 나는 중이라 시계가 띄운 순간부터 가야 한다.
      anchorToSpawn: restart,
      extraInputArgs: restart ? const [] : debugFirstPumpInputArgs,
    );
    _pump = pump;
    if (!restart) {
      if (chunkF != null) {
        pump.startGate = chunkF;
        // 소리는 튼 뒤 kAudioLeadMs 가 지나야 들린다. 화면도 그만큼 늦게 출발.
        pump.clockLeadSec = kAudioLeadMs / 1000;
      }
      pump.onStarted = () {
        if (gen != _gen || chunkF == null) return;
        // 게이트가 끝났으므로 이 then 은 바로 다음 마이크로태스크에서 돈다.
        chunkF.then((c) {
          if (gen != _gen || c == null) return;
          _chunk = c;
          _audioOn = AudioOut.start(c);
        });
      };
    } else {
      // 첫 그림이 나오기까지 ffmpeg 을 다시 띄우는 시간이 든다. 그동안의 지연을
      // 늦음으로 오해해 또 다시 띄우지 않도록 더 길게 본다.
      pump.lagWindow = kLagWindow * 2;
    }
    pump.onFrame = (bytes, index) {
      if (gen != _gen) return;
      // 위치는 시계를 따른다. 프레임 시각(index)을 쓰면 디코딩이 느릴 때 위치가
      // 소리보다 뒤처진다.
      var pos = from + (pump.clockSec > 0 ? pump.clockSec : 0);
      if (untilSec != null && pos > untilSec) pos = untilSec;
      _maybeContinueAudio(gen, audioTrack, pos);
      _show(gen, bytes, geo, pos);
    };
    pump.onLag = (clock) =>
        _recoverFromLag(gen, pump, from, untilSec, audioTrack);
    pump.onEnded = () => _ended(gen, untilSec);
  }

  /// 디코딩이 실시간을 못 따라가 화면이 소리보다 계속 늦다. 소리는 그대로 두고
  /// 화면만 지금 시각부터 더 작은 크기로 다시 띄운다.
  void _recoverFromLag(int gen, FramePump old, double from, double? untilSec,
      AudioTrack? audioTrack) {
    if (gen != _gen || _pump != old || _disposed) return;
    final base = from + old.clockSec;
    // 거의 끝났으면 다시 띄우느라 끊기는 것보다 그대로 끝내는 게 낫다.
    if (untilSec != null && untilSec - base < 0.5) return;
    if (base >= spec.durationSec - 0.3) return;
    lagging.value = true;
    // 늦게 도착할 옛 프레임이 새 그림에 섞이지 않게 먼저 끊는다(stop 의 앞부분은
    // 동기로 끝난다). 프로세스가 사라지길 기다리지는 않는다.
    unawaited(old.stop());
    _pendingBytes = null;
    _startPump(gen,
        from: base,
        untilSec: untilSec,
        geo: PlayGeometry.of(spec, longSide: lagLongSide),
        audioTrack: audioTrack,
        chunkF: null,
        restart: true);
    unawaited(_pump?.start());
  }

  /// [untilSec] 또는 파일 끝까지 다 틀었다(멈춤으로 끝난 것이 아님).
  void _ended(int gen, double? untilSec) {
    if (gen != _gen) return;
    // 아직 변환 중인 마지막 그림이 끝난 뒤에 위치를 되돌려 놓지 않도록
    // 세대를 넘긴다.
    _gen++;
    _finish(natural: true);
    // 마지막 그림의 시각은 끝보다 한 장(약 33ms) 앞이다. 재생 막대가 끝에
    // 딱 맞게 멈추도록 끝 시각으로 맞춘다.
    if (!_disposed && untilSec != null) position.value = untilSec;
    onEnded?.call();
  }

  /// 소리 조각이 끝나 가면 다음 조각을 미리 쓰고, 끝나면 이어 튼다.
  /// 첫 조각은 짧고(45초) 그 뒤는 최대 10분이다.
  ///
  /// 이어지는 순간 소리가 [kAudioLeadMs] 안팎(수십 ms) 끊길 수 있다 — 새 조각도
  /// 틀고 나서 그만큼 지나야 들리는데, 앞 조각은 새로 틀 때 바로 끊긴다. 틈을 없애려고
  /// 일찍 틀면 앞 조각의 끝이 잘려 같은 길이의 틈이 생기므로 그대로 둔다.
  void _maybeContinueAudio(int gen, AudioTrack? a, double pos) {
    final c = _chunk;
    final until = _audioUntil;
    if (a == null || c == null || until == null || !_audioOn) return;
    if (c.endSec >= until - 0.01) return;
    if (_nextChunk == null && pos >= c.endSec - 20) {
      _nextChunk = AudioOut.prepare(a, c.endSec,
          untilSec: until, gain: _gain, cancel: _audioCancel);
    }
    final next = _nextChunk;
    if (next != null && pos >= c.endSec) {
      _nextChunk = null;
      _chunk = null; // 준비가 끝날 때까지 중복 진입 방지
      next.then((n) {
        if (gen != _gen || n == null) return;
        _chunk = n;
        _audioOn = AudioOut.start(n);
      });
    }
  }

  void _show(int gen, Uint8List bytes, PlayGeometry geo, double pos) {
    _pendingBytes = bytes;
    _pendingGeo = geo;
    _pendingGen = gen;
    _pendingPos = pos;
    if (!_decoding) _decodeNext();
  }

  /// 가장 최근에 맡겨진 그림 하나를 변환한다. [_decoding] 이 꺼져 있을 때만 부른다.
  void _decodeNext() {
    final bytes = _pendingBytes;
    final geo = _pendingGeo;
    if (bytes == null || geo == null || _pendingGen != _gen || _disposed) {
      _pendingBytes = null;
      return;
    }
    _pendingBytes = null;
    final pos = _pendingPos;
    final gen = _pendingGen;
    final seq = ++_decodeSeq;
    _decoding = true;
    // 콜백이 영영 안 오면 _decoding 이 켜진 채로 남아 그림이 더는 안 바뀐다.
    // 일정 시간 안 오면 이 요청은 버리고 다음으로 간다(늦게 오면 번호가 달라 버려진다).
    _decodeTimer?.cancel();
    _decodeTimer = Timer(decodeWatchdog, () {
      if (seq != _decodeSeq || !_decoding) return;
      _decodeSeq++;
      _decoding = false;
      if (_pendingBytes != null && !_disposed) _decodeNext();
    });
    try {
      ui.decodeImageFromPixels(
        bytes,
        geo.width,
        geo.height,
        ui.PixelFormat.rgba8888,
        (img) {
          if (seq != _decodeSeq) {
            // 워치독이 포기한 요청의 늦은 결과.
            img.dispose();
            return;
          }
          _decodeTimer?.cancel();
          _decoding = false;
          if (gen != _gen || _disposed) {
            // 멈춘 뒤에 도착했다. 그 사이 새 재생이 맡긴 그림이 있으면 그것을 변환.
            img.dispose();
            if (_pendingBytes != null && !_disposed) _decodeNext();
            return;
          }
          final old = frame.value;
          frame.value = img;
          position.value = pos;
          _retired?.dispose();
          _retired = old;
          if (_pendingBytes != null) _decodeNext();
        },
      );
    } on Object {
      _decodeTimer?.cancel();
      _decoding = false;
    }
  }

  /// 재생이 끝났을 때 정리. [natural] 은 끝까지 다 튼 경우(소리를 잠깐 더 둔다),
  /// 아니면 사용자가 멈췄거나 새로 틀려는 경우(소리를 바로 끈다).
  void _finish({bool natural = false}) {
    _pump = null;
    _audioCancel?.cancel();
    _audioCancel = null;
    if (_audioOn) {
      // 화면 시계가 끝에 닿은 순간 소리는 장치 안에 kAudioLeadMs 만큼 남아 있다.
      // 바로 끄면 마지막이 잘린다. 사용자가 멈춘 경우에는 바로 꺼야 한다.
      if (natural) {
        AudioOut.stopAfter(const Duration(milliseconds: kAudioLeadMs));
      } else {
        AudioOut.stop();
      }
      _audioOn = false;
    } else if (!natural && AudioOut.stopPending) {
      // 직전 재생의 미뤄 둔 정지가 남았으면 지금 끝낸다.
      AudioOut.stop();
    }
    _chunk = null;
    _nextChunk = null;
    _pendingBytes = null;
    if (!_disposed) {
      playing.value = false;
      lagging.value = false;
    }
  }

  /// 멈춘다. ffmpeg 이 끝날 때까지 기다린다. 마지막 그림은 그대로 둔다.
  Future<void> stop() {
    _cmd++;
    return _halt();
  }

  Future<void> _halt() async {
    _gen++;
    final pump = _pump;
    _finish();
    // _decoding 은 건드리지 않는다. 변환 중인 그림의 콜백이 곧 와서 직접 끈다.
    // 여기서 꺼 버리면 옛 변환이 끝나기 전에 새 변환이 시작되어 둘이 겹치고,
    // 옛 결과가 늦게 도착해 그림·위치가 뒤로 튄다. 옛 콜백은 세대가 달라 버려진다.
    if (pump != null) await pump.stop();
  }

  void dispose() {
    if (_disposed) return;
    unawaited(stop());
    _disposed = true;
    _decodeTimer?.cancel();
    final img = frame.value;
    frame.value = null;
    img?.dispose();
    _retired?.dispose();
    _retired = null;
    frame.dispose();
    position.dispose();
    playing.dispose();
    lagging.dispose();
  }
}
