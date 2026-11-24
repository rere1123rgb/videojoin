import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../engine/encoder_support.dart';
import '../engine/executor.dart';
import '../engine/ffmpeg_tools.dart';
import '../engine/frame_grabber.dart';
import '../player/audio_track.dart';
import '../engine/job_log.dart';
import '../engine/job_queue.dart';
import '../engine/joblist_file.dart';
import '../engine/models.dart';
import '../engine/notify.dart';
import '../engine/planner.dart';
import '../engine/power.dart';
import '../engine/prober.dart';
import '../engine/queue_store.dart';
import '../engine/rational.dart';
import '../engine/shortcuts.dart';
import '../engine/thumbnailer.dart';

part 'app_state_init.dart';
part 'app_state_clips.dart';
part 'app_state_plan.dart';
part 'app_state_options.dart';
part 'app_state_worker.dart';
part 'app_state_queue_store.dart';

/// 화면 단계.
///
/// 인코딩이 시작되어도 화면을 전환하지 않는다. 사용자는 영상이 만들어지는
/// 동안에도 다음 묶음을 목록에 올리고 설정을 잡고 대기열에 넣을 수 있어야
/// 한다. 진행 상황은 화면 위쪽 대기열 패널에 계속 보인다.
enum AppPhase { setup }

class AppState extends ChangeNotifier {
  FFTools? tools;
  EncoderSupport encoders = const EncoderSupport();

  /// ffmpeg 을 찾지 못했을 때의 안내 메시지.
  String? fatalError;

  bool initialized = false;

  final List<ClipItem> clips = [];
  JobPlan? plan;

  AppPhase phase = AppPhase.setup;

  // --- 사용자 선택 ---
  bool useLossless = true;
  ResolutionOption? resolution;
  FpsOption? fps;
  BitrateKind bitrateKind = BitrateKind.original;
  CodecChoice codec = CodecChoice.h264;
  FitMode fitMode = FitMode.pad;
  bool useGpu = true;
  bool shutdownWhenDone = false;

  /// 대기열을 다 만든 뒤 결과 폴더를 열지.
  /// 되돌릴 수 있는 동작이라 확인 없이 켜고 끌 수 있고, 설정도 기억한다.
  /// (컴퓨터 끄기는 위험해서 일부러 기억하지 않는다)
  bool openFolderWhenDone = false;

  /// 만드는 동안 컴퓨터가 절전으로 빠지지 않게 막을지.
  /// 화면 끄기는 막지 않는다. 기본 꺼짐이고 설정은 기억한다.
  bool preventSleep = false;

  /// 영상 사이를 검은 화면으로 잠깐 어두워졌다 밝아지게 넘길지.
  bool smoothTransitions = false;

  /// 넘길 때 거치는 화면 색과 길이.
  TransitionStyle transitionStyle = TransitionStyle.dipBlack;
  TransitionLength transitionLength = TransitionLength.normal;

  /// 결과물의 맨 처음과 맨 끝도 서서히 시작하고 끝낼지.
  bool fadeEnds = false;

  // --- 직접 입력 (고급) ---
  //
  // 프리셋으로 안 되는 값이 필요할 때를 위한 탈출구다. 평소에는 접혀 있고,
  // 켜야만 프리셋 대신 이 값이 쓰인다. 끄면 원래 동작 그대로다.
  bool advancedOpen = false;

  bool useCustomResolution = false;
  int customWidth = 1920;
  int customHeight = 1080;

  /// 가로·세로를 원본 비율에 묶어 둘지.
  ///
  /// 한쪽을 고치면 다른 쪽이 따라온다. 기본 꺼짐이고 **저장하지 않는다** —
  /// 묶인 줄 모르고 값을 넣으면 엉뚱한 크기가 나오므로 매번 의식하고 켜는 게 낫다.
  bool lockAspect = false;

  bool useCustomBitrate = false;
  double customBitrateMbps = 8.0;

  bool useCustomFps = false;
  double customFpsValue = 30.0;

  String outputDir = '';

  /// 수동으로 입력한 파일 이름. 자동 이름이 켜져 있으면 쓰이지 않는다.
  String outputName = '';

  /// 파일 이름을 영상이 있던 폴더 이름에서 자동으로 만들지.
  /// 기본 켜짐.
  bool autoNaming = true;

  /// 자동 이름 뒤에 붙일 말. 기본은 비어 있어서 폴더 이름을 그대로 쓴다.
  /// 무엇을 붙이고 싶은지는 사람마다 달라서(`_합침`, `_merged`, 없음 …)
  /// 미리 정해 두지 않고 입력칸의 예시로만 안내한다.
  String nameSuffix = '';

  /// 저장 폴더를 사용자가 직접 골랐는지.
  /// 고르지 않았으면 영상이 있던 폴더를 따라간다.
  bool outputDirManual = false;

  // --- 대기열 ---
  //
  // 대기열에 넣는 즉시 뒤에서 순차 처리가 시작된다. "전체 시작" 같은
  // 버튼을 따로 누를 필요가 없다. 한 묶음에도 오래 걸릴 수 있어
  // 걸어두고 자리를 비울 수 있어야 한다.
  final List<QueuedJob> queue = [];
  bool _workerBusy = false;

  /// 끝내지 못한 대기열을 적어 두는 곳. null 이면 저장하지 않는다.
  ///
  /// 실제 앱에서만 [enableQueueStore] 로 켠다. 상태 초기화에 섞어 두면
  /// 테스트가 사용자의 진짜 대기열 파일을 건드리게 된다.
  QueueStore? _store;

  /// 창을 닫는 중인지. 닫으면서 ffmpeg 을 정리하면 작업이 "취소됨"으로
  /// 바뀌는데, 그 상태가 저장되면 다음에 켰을 때 되살릴 게 없어진다.
  bool _exiting = false;

  /// 지난번에 끝내지 못하고 남은 작업들. 사용자에게 물어본 뒤 비운다.
  List<StoredJob> _pendingRestore = const [];
  int get pendingRestoreCount => _pendingRestore.length;

  Timer? _suffixSaveTimer;
  int _jobSeq = 0;

  Executor? _executor;
  StreamSubscription<JobProgress>? _sub;
  String? lastLogPath;

  /// 지금 처리 중인 작업. 없으면 null.
  QueuedJob? get runningJob {
    for (final j in queue) {
      if (j.status == QueuedStatus.running) return j;
    }
    return null;
  }

  int get waitingCount =>
      queue.where((j) => j.status == QueuedStatus.waiting).length;

  bool get queueActive => runningJob != null || waitingCount > 0;

  /// 대기열 전체 진행률(0~1). 재생시간 기준 가중.
  double get queueProgress {
    final active = queue.where((j) => !j.isFinished).toList();
    if (active.isEmpty) return 1;
    var total = 0.0;
    var done = 0.0;
    for (final j in active) {
      final w = j.totalDuration <= 0 ? 1.0 : j.totalDuration;
      total += w;
      done += w * j.progress;
    }
    return total <= 0 ? 0 : (done / total).clamp(0.0, 1.0);
  }

  /// 파일을 읽어들이는 중인지.
  bool loading = false;
  int loadDone = 0;
  int loadTotal = 0;

  double uiScaleBoost = 1.0;

  SharedPreferences? _prefs;


  /// 바탕화면 바로가기를 만들지 물어봐야 하는 상태인지.
  /// UI 가 이 값을 보고 한 번만 팝업을 띄운다.
  bool needAskDesktopShortcut = false;

  static String _defaultOutputDir() {
    final home = Platform.environment['USERPROFILE'];
    if (home != null) {
      final videos = Directory(p.join(home, 'Videos'));
      if (videos.existsSync()) return videos.path;
      return home;
    }
    return Directory.current.path;
  }

  int duplicateSkipped = 0;
  int _idSeq = 0;

  /// 편집을 실제 영상 길이에 맞춘다.
  ///
  /// 저장해 둔 목록을 불러올 때 그 사이 파일이 짧아졌을 수 있고,
  /// 길이를 못 읽은 영상(0초)은 자를 수 없다. 영상 전체를 남기는 구간
  /// 하나뿐이면 자르지 않은 것과 같으므로 비운다 — 그래야 무손실이 가능할 때
  /// 괜히 다시 만들지 않는다.
  static ClipEdit _fitEdit(ClipEdit e, VideoSpec spec) {
    if (e.keep.isEmpty) return e;
    final d = spec.durationSec;
    if (!spec.ok || d <= 0) return e.copyWith(keep: const []);
    final rs = normalizeRanges(e.keep, duration: d);
    final whole = rs.length == 1 && rs.first.start <= 0.05 && rs.first.end >= d - 0.05;
    if (rs.isEmpty || whole) return e.copyWith(keep: const []);
    return e.copyWith(keep: rs);
  }


  /// H.264 는 가로·세로가 짝수여야 한다. 홀수가 들어오면 1 올려서 맞춘다.
  static int _even(int v) => v.isEven ? v : v + 1;

  /// 짝수로 맞춘다. 따라오는 쪽은 프로그램이 정하는 값이라
  /// "홀수는 짝수로 맞춥니다" 안내가 뜰 일을 만들지 않는 게 낫다.
  static int _toEven(double v) {
    final n = (v / 2).round() * 2;
    return n < 2 ? 2 : n;
  }

  bool _disposed = false;

  /// 창을 닫은 뒤에도 백그라운드 작업(썸네일 생성, 인코딩 진행 보고)이
  /// 잠깐 더 살아 있다가 알림을 보내려 한다. 그대로 두면
  /// "A AppState was used after being disposed" 로 터진다.
  /// 여기서 한 번에 막는다.
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    // 닫으면서 생기는 "취소됨" 상태가 대기열 파일에 적히지 않게 한다.
    _exiting = true;
    if (_suffixSaveTimer != null) _flushSuffix();
    _sub?.cancel();
    _executor?.cancel();
    // 창을 닫았는데 절전 금지가 남아 있으면 컴퓨터가 영영 안 잔다.
    KeepAwake.release();
    super.dispose();
  }

  /// 컴퓨터 끄기를 예약한 시각. null 이면 예약된 게 없다.
  DateTime? shutdownAt;

  static const int shutdownDelaySeconds = 120;
}

/// 프레임레이트 표시에 쓰는 짧은 헬퍼.
extension FpsLabel on Rational {
  String get shortLabel => label;
}
