import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../engine/ffmpeg_tools.dart';
import '../engine/models.dart';
import '../engine/rational.dart';
import '../engine/suspend.dart';

// 재생의 실제 일(ffmpeg 띄우기, 프레임 조립, 속도 맞추기, 끝 판정)은 전부 여기서
// 한다. dart:ui 를 쓰지 않으므로 실제 시간·실제 프로세스로 테스트할 수 있다
// (testWidgets 는 가짜 시간이라 진짜 프로세스를 기다리면 멈춘다).
// ClipPlayer 는 이 위에 "바이트 → 그림" 변환만 얹는다.

/// 재생 화면 크기와 초당 장수.
class PlayGeometry {
  final int width;
  final int height;
  final Rational fps;

  const PlayGeometry(this.width, this.height, this.fps);

  int get frameBytes => width * height * 4;

  /// [index] 번째 프레임이 화면에 나올 시각(재생 시작 기준 초).
  /// 29.97 같은 값을 소수로 뭉개면 길게 틀 때 밀리므로 분수로 계산한다.
  double ptsOf(int index) => index * fps.den / fps.num;

  /// 화면에 보이는 크기(회전·픽셀 비율 반영)를 긴 변 [longSide] 안에 맞춘다.
  /// 원본보다 키우지는 않는다. 짝수로 맞춘다(rgba 라 꼭 필요하진 않지만
  /// 스케일러가 홀수 크기에서 가장자리를 한 줄 흐리게 만드는 일이 있다).
  ///
  /// 초당 장수는 원본과 30 중 작은 쪽. 60fps 를 그대로 받으면 960 폭에서도
  /// 초당 120MB 를 파이프로 옮겨야 하고, 편집 확인용으로는 30 이면 충분하다.
  static PlayGeometry of(VideoSpec spec, {int longSide = 960, int maxFps = 30}) {
    var w = spec.displayWidth;
    var h = spec.displayHeight;
    if (w <= 0 || h <= 0) {
      w = 16;
      h = 9;
    }
    final long = w > h ? w : h;
    final target = long < longSide ? long : longSide;
    int even(double v) {
      var r = v.round();
      if (r.isOdd) r -= 1;
      return r < 2 ? 2 : r;
    }

    final int ow, oh;
    if (w >= h) {
      ow = even(target.toDouble());
      oh = even(target * h / w);
    } else {
      oh = even(target.toDouble());
      ow = even(target * w / h);
    }
    var fps = spec.frameRate;
    if (fps.num <= 0 || fps.den <= 0 || fps.toDouble() > maxFps) {
      fps = Rational(maxFps, 1);
    }
    return PlayGeometry(ow, oh, fps.reduced());
  }
}

/// ffmpeg 인자. 테스트와 진단에서 같은 것을 보려고 밖으로 뺐다.
List<String> framePumpArgs(
  VideoSpec spec,
  PlayGeometry g, {
  required double fromSec,
  double? untilSec,
  bool hwaccel = false,
  List<String> extraInputArgs = const [],
}) {
  final from = fromSec < 0 ? 0.0 : fromSec;
  final len = untilSec == null ? null : untilSec - from;
  final vf = <String>[
    // 장수를 먼저 줄여야 버릴 프레임까지 크기를 바꾸는 헛일을 안 한다.
    'fps=${g.fps.toFFmpegArg()}',
    'scale=${g.width}:${g.height}:flags=bilinear',
    'setsar=1',
    // HDR 을 그대로 RGB 로 바꾸면 색 빠진 회색빛이 된다. 내보낼 때와 같은
    // 톤매핑을 쓰되, 크기를 줄인 뒤에 해서 4K 에서도 실시간으로 돈다.
    if (spec.isHdr) ...[
      'zscale=t=linear:npl=100',
      'format=gbrpf32le',
      'zscale=p=bt709',
      'tonemap=tonemap=hable:desat=0',
      'zscale=t=bt709:m=bt709:r=tv',
      'format=yuv420p',
    ],
    'format=rgba',
  ];
  return [
    '-hide_banner', '-nostdin', '-nostats', '-v', 'error',
    if (hwaccel) ...['-hwaccel', 'auto'],
    '-ss', from.toStringAsFixed(3),
    if (len != null && len > 0) ...['-t', len.toStringAsFixed(3)],
    ...extraInputArgs,
    '-i', spec.path,
    '-an', '-sn', '-dn',
    '-vf', vf.join(','),
    '-pix_fmt', 'rgba',
    '-f', 'rawvideo',
    'pipe:1',
  ];
}

/// 화면이 시계보다 이 이상(초) 늦은 채로 [kLagWindow] 이상 이어지면 "디코딩이
/// 실시간을 못 따라간다" 고 본다. 4K HEVC·HDR 톤매핑을 느린 PC 에서 풀 때 생긴다.
/// 한두 프레임 밀리는 정도(0.1~0.3초)는 흔해서 일부러 넉넉히 잡았다.
const double kLagThresholdSec = 0.7;

/// [kLagThresholdSec] 넘게 늦은 상태가 이만큼 이어져야 [FramePump.onLag] 을 부른다.
const Duration kLagWindow = Duration(seconds: 1);

/// ffmpeg 이 풀어 준 그림을 제때 하나씩 내보내는 한 번짜리 재생기.
///
/// 한 번 [start] 하고 끝나거나 [stop] 하면 다시 쓰지 않는다. 다시 틀 때는 새로
/// 만든다. 그래야 앞 재생의 늦게 도착한 프레임이 새 재생에 섞이지 않는다.
class FramePump {
  final FFTools tools;
  final VideoSpec spec;
  final double fromSec;
  final double? untilSec;
  final PlayGeometry geometry;

  /// 미리 받아 둘 최대 장수. 이 이상 쌓이면 파이프 읽기를 멈춰 ffmpeg 을
  /// 기다리게 한다. 960×540 한 장이 2MB 라 몇 장이면 충분하다.
  final int maxBuffered;
  final bool hwaccel;

  /// true 면 시계를 첫 프레임이 아니라 ffmpeg 을 띄우는 순간부터 돌린다.
  ///
  /// 소리가 계속 나는 중에 화면만 다시 띄울 때(느린 디코딩 복구) 쓴다. 소리는
  /// 멈추지 않고 흘러가므로, 새 ffmpeg 이 첫 그림을 내는 데 걸린 시간만큼 화면이
  /// 뒤처지면 안 된다. 시계가 띄운 순간부터 가고 늦은 프레임은 버려지므로
  /// 첫 그림이 늦게 나와도 소리 위치로 따라붙는다.
  final bool anchorToSpawn;

  /// 입력 앞에 끼울 ffmpeg 인자. 테스트에서 `-readrate` 로 느린 디코더를 흉내
  /// 내는 데만 쓴다.
  final List<String> extraInputArgs;

  /// 시계가 출발한 뒤 이만큼(초) 지나서야 0 초로 친다. 소리 장치가 소리를 내기
  /// 시작하는 데 드는 시간([kAudioLeadMs])만큼 화면을 늦춰 소리와 맞춘다.
  double clockLeadSec = 0;

  /// 화면이 시계보다 계속 늦다. 호출한 쪽이 이 재생기를 버리고 지금 시각부터
  /// 다시 띄운다. 한 번 불렀으면 이 재생기에서는 다시 부르지 않는다.
  /// 인자는 지금 시계 값(초). null 이면 늦음 감시를 하지 않는다.
  void Function(double clockSec)? onLag;

  /// 늦음을 확정하기까지 이어져야 하는 시간. 다시 띄운 직후에는 첫 그림이
  /// 늦게 나오니 더 길게 준다.
  Duration lagWindow = kLagWindow;

  /// 화면에 낼 차례가 된 프레임. [index] 는 이번 재생에서 몇 번째인지.
  void Function(Uint8List rgba, int index)? onFrame;

  /// 첫 프레임이 준비되어 시계가 막 출발한 순간. 소리를 여기서 튼다.
  void Function()? onStarted;

  /// 끝까지(또는 [untilSec] 까지) 다 틀었다. [stop] 으로 멈춘 경우엔 안 부른다.
  void Function()? onEnded;

  /// 시계가 출발하기 전에 기다릴 일(소리 조각 쓰기 등). 첫 프레임과 이것이
  /// 둘 다 준비되어야 출발한다. 그래야 소리와 화면이 같이 시작한다.
  Future<void>? startGate;

  FramePump({
    required this.tools,
    required this.spec,
    required this.fromSec,
    this.untilSec,
    PlayGeometry? geometry,
    this.maxBuffered = 4,
    this.hwaccel = false,
    this.anchorToSpawn = false,
    this.extraInputArgs = const [],
  }) : geometry = geometry ?? PlayGeometry.of(spec);

  Process? _proc;
  StreamSubscription<List<int>>? _sub;
  StreamSubscription<List<int>>? _errSub;
  Timer? _timer;
  Duration? _lagSince;
  bool _lagFired = false;
  final Stopwatch _clock = Stopwatch();
  final List<Uint8List> _queue = [];
  Uint8List? _cur;
  int _fill = 0;
  bool _paused = false;
  bool _eof = false;
  bool _started = false;
  bool _gateDone = false;
  bool _dead = false;
  int _nextIndex = 0;
  final Stopwatch _sinceSpawn = Stopwatch();
  final List<int> _errTail = [];

  // --- 진단·테스트용 ---
  int framesShown = 0;
  int framesDropped = 0;
  int framesReceived = 0;

  /// 가장 최근 틱에서 잰 늦음(초): 시계 - 보여준 프레임의 시각. 테스트·진단용.
  double lastLagSec = 0;

  /// ffmpeg 을 띄운 뒤 첫 프레임이 나오기까지 걸린 시간.
  Duration? firstFrameLatency;

  /// 시계 출발부터 마지막 프레임을 낸 순간까지.
  Duration? lastFrameAt;

  int? get pid => _proc?.pid;

  /// ffmpeg 프로세스가 끝나면 완료된다(종료 코드). 띄우지 못했으면 -1.
  Future<int> get exitCode => _proc?.exitCode ?? Future.value(-1);

  /// 시계(재생 시작 후 흐른 초). 아직 출발 전이면 0. [clockLeadSec] 동안은
  /// 음수다(소리는 나기 시작했지만 화면은 아직 출발 전).
  double get clockSec => (_started || anchorToSpawn)
      ? _clock.elapsedMicroseconds / 1e6 - clockLeadSec
      : 0;

  /// 8ms 타이머가 돌고 있는가(테스트용: 끝난 재생기에 남아 있으면 누수다).
  bool get timerActive => _timer?.isActive ?? false;

  /// ffmpeg 이 남긴 오류 메시지 끝부분(진단용).
  String get errorTail => String.fromCharCodes(_errTail);

  bool get isRunning => !_dead;

  double? get _untilLen => untilSec == null ? null : untilSec! - fromSec;

  /// ffmpeg 을 띄운다. 띄우지 못하면 곧바로 끝난 것으로 친다(onEnded).
  Future<void> start() {
    if (_dead || _starting != null) return _starting ?? Future.value();
    return _starting = _start();
  }

  /// 띄우는 중인 작업. 그 사이에 [stop] 이 불리면 이걸 기다렸다가 죽인다.
  Future<void>? _starting;

  Future<void> _start() async {
    final gate = startGate;
    if (gate == null) {
      _gateDone = true;
    } else {
      gate.then((_) => _onGate(), onError: (Object _) => _onGate());
    }
    _sinceSpawn.start();
    if (anchorToSpawn) _clock.start();
    try {
      final proc = await Process.start(
        tools.ffmpegPath,
        framePumpArgs(spec, geometry,
            fromSec: fromSec,
            untilSec: untilSec,
            hwaccel: hwaccel,
            extraInputArgs: extraInputArgs),
        runInShell: false,
      );
      _proc = proc;
      // 창을 그냥 닫아도 ffmpeg 이 남아 돌지 않게 묶는다.
      ProcessGuard.attach(proc.pid);
      if (_dead) {
        // 띄우는 사이에 멈춤을 눌렀다.
        proc.kill(ProcessSignal.sigkill);
        return;
      }
      // stderr 를 비워 주지 않으면 버퍼가 차서 ffmpeg 이 멈춘다.
      _errSub = proc.stderr.listen((d) {
        _errTail.addAll(d);
        if (_errTail.length > 4096) {
          _errTail.removeRange(0, _errTail.length - 4096);
        }
      }, onError: (Object _) {});
      _sub = proc.stdout.listen(_onData, onDone: _onEof, onError: (Object _) {
        _onEof();
      }, cancelOnError: true);
    } on Object {
      _eof = true;
      _end();
    }
  }

  void _onGate() {
    _gateDone = true;
    _maybeBegin();
  }

  void _onData(List<int> data) {
    if (_dead) return;
    final fb = geometry.frameBytes;
    var off = 0;
    while (off < data.length) {
      final cur = _cur ??= Uint8List(fb);
      var take = fb - _fill;
      if (take > data.length - off) take = data.length - off;
      cur.setRange(_fill, _fill + take, data, off);
      _fill += take;
      off += take;
      if (_fill == fb) {
        _queue.add(cur);
        _cur = null;
        _fill = 0;
        framesReceived++;
        if (framesReceived == 1) {
          firstFrameLatency = _sinceSpawn.elapsed;
          _maybeBegin();
        }
      }
    }
    // 이미 충분히 받아 두었으면 읽기를 멈춘다. ffmpeg 은 파이프가 차서
    // 기다리게 되고, 메모리를 먹으며 앞서 달리지 않는다.
    if (_queue.length >= maxBuffered && !_paused) {
      _paused = true;
      _sub?.pause();
    }
  }

  void _onEof() {
    if (_dead) return;
    _eof = true;
    // 끝에 남은 반쪽 프레임은 버린다.
    _cur = null;
    _fill = 0;
    if (framesReceived == 0) {
      // 한 장도 못 받았다(끝을 넘어선 시각, 읽을 수 없는 파일 등).
      _end();
    }
  }

  void _maybeBegin() {
    if (_started || _dead || !_gateDone || framesReceived == 0) return;
    _started = true;
    if (!_clock.isRunning) _clock.start();
    try {
      onStarted?.call();
    } on Object {
      // 소리를 못 틀어도 화면은 계속 간다.
    }
    if (_dead) return;
    _tick();
    // 첫 _tick 에서 이미 끝났으면(untilSec 이 시작 이하 등) 타이머를 만들면 안
    // 된다. _end → _shutdown 이 아직 null 인 _timer 를 취소하고 지나가 버려서,
    // 그 뒤에 만든 주기 타이머는 아무도 멈추지 않고 영원히 돈다.
    if (_dead) return;
    // 윈도우의 타이머는 약 15ms 단위로 깨어날 수 있다. 그래도 30fps(33ms)는
    // 맞출 수 있도록 더 짧게 건다.
    _timer = Timer.periodic(const Duration(milliseconds: 8), (_) => _tick());
  }

  void _tick() {
    if (_dead) {
      // 혹시 끝난 뒤에도 타이머가 남았다면 스스로 거둔다.
      _timer?.cancel();
      _timer = null;
      return;
    }
    final t = clockSec;
    final limit = _untilLen;
    if (limit != null && t >= limit) {
      _end();
      return;
    }

    // 시각이 지난 프레임들 중 가장 최근 것 하나만 보여준다. 나머지는 늦었으니
    // 버린다(그림 변환이 밀려 화면이 소리보다 점점 늦어지는 것보다 낫다).
    Uint8List? show;
    var showIndex = -1;
    while (_queue.isNotEmpty && geometry.ptsOf(_nextIndex) <= t) {
      if (show != null) framesDropped++;
      show = _queue.removeAt(0);
      showIndex = _nextIndex;
      _nextIndex++;
    }
    if (show != null) {
      framesShown++;
      lastFrameAt = _clock.elapsed;
      try {
        onFrame?.call(show, showIndex);
      } on Object {
        // 그리는 쪽 문제로 재생 전체가 멈추면 안 된다.
      }
      if (_dead) return;
    }

    // 늦음 재기: 보여준 프레임이 시계보다 얼마나 늦었나. 보여줄 게 없고 ffmpeg
    // 도 못 낸 상태면 "다음에 나왔어야 할 프레임" 이 얼마나 늦었나. 디코더가
    // 실시간보다 느리면 후자가 계속 커진다(프레임은 오는 대로 하나씩 보여서 버려지지도
    // 않는다).
    final double lag;
    if (show != null) {
      lag = t - geometry.ptsOf(showIndex);
    } else if (_queue.isEmpty && !_eof) {
      lag = t - geometry.ptsOf(_nextIndex);
    } else {
      lag = 0;
    }
    lastLagSec = lag;
    _trackLag(lag);
    if (_dead) return;

    if (_paused && _queue.length < maxBuffered) {
      _paused = false;
      _sub?.resume();
    }

    // ffmpeg 이 다 내보냈고, 받은 것을 다 보여줬고, 마지막 프레임의 시간도
    // 다 흘렀으면 끝.
    if (_eof && _queue.isEmpty && t >= geometry.ptsOf(_nextIndex)) {
      _end();
    }
  }

  void _trackLag(double lag) {
    final cb = onLag;
    if (cb == null || _lagFired || !_started) return;
    if (lag <= kLagThresholdSec) {
      _lagSince = null;
      return;
    }
    final now = _clock.elapsed;
    final since = _lagSince ??= now;
    if (now - since < lagWindow) return;
    _lagFired = true;
    try {
      cb(clockSec);
    } on Object {
      // 복구 실패가 재생 전체를 멈추면 안 된다.
    }
  }

  void _shutdown() {
    _dead = true;
    _timer?.cancel();
    _timer = null;
    _clock.stop();
    _queue.clear();
    _cur = null;
    // 멈춘(pause) 구독은 done 을 영영 안 주므로 직접 끊는다.
    _sub?.cancel();
    _sub = null;
    _errSub?.cancel();
    _errSub = null;
    try {
      _proc?.kill(ProcessSignal.sigkill);
    } on Object {
      // 이미 끝났다.
    }
  }

  void _end() {
    if (_dead) return;
    _shutdown();
    try {
      onEnded?.call();
    } on Object {
      // 무시
    }
  }

  /// 멈춘다. ffmpeg 이 정말 끝날 때까지(최대 3초) 기다린다. onEnded 는 안 부른다.
  Future<void> stop() async {
    if (!_dead) _shutdown();
    final starting = _starting;
    if (starting != null) {
      try {
        await starting;
      } on Object {
        // 무시
      }
    }
    final proc = _proc;
    if (proc == null) return;
    try {
      await proc.exitCode.timeout(const Duration(seconds: 3));
    } on Object {
      // 못 기다렸다. ProcessGuard 가 앱 종료 때 정리한다.
    }
  }
}
