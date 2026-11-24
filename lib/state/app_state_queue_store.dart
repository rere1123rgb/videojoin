part of 'app_state.dart';

// 확장 메서드 안에서 notifyListeners 를 부르는 건 의도된 것이다. 이 파일들은
// AppState 의 한 부분일 뿐이라 알림 시점과 순서가 원래와 같다.
// ignore_for_file: invalid_use_of_protected_member

/// 대기열 파일 보존·복원, 종료 준비, 끝난 작업 정리와 결과 열기.
extension AppStateQueueStore on AppState {
  // --- 대기열 보존 -----------------------------------------------------------

  /// 대기열을 파일에 남기기 시작한다. 실제 앱을 띄울 때만 부른다.
  ///
  /// 지난번에 끝내지 못한 작업이 있으면 [pendingRestoreCount] 가 0 보다
  /// 커지고, 화면이 사용자에게 이어서 할지 물어본다.
  void enableQueueStore([String? path]) {
    final at = path ?? QueueStore.defaultPath();
    if (at == null) return;
    final store = QueueStore(at);
    _store = store;
    _pendingRestore = store.load();
    if (_pendingRestore.isNotEmpty) notifyListeners();
  }

  void _saveQueue() {
    if (_exiting) return;
    // 아직 대답을 듣지 못한 지난번 작업이 있으면 덮어쓰지 않는다.
    if (_pendingRestore.isNotEmpty) return;
    _store?.save(queue);
  }

  /// 지난번 작업을 이어서 할지에 대한 대답.
  ///
  /// 이어서 한다면 영상 정보를 다시 읽어 대기열 **맨 뒤**에 붙인다.
  /// 영상이 하나라도 없어진 작업은 되살리지 않는다 — 빠진 채로 만들면
  /// 원하던 것과 다른 결과물이 나온다.
  /// 반환값은 되살리지 못한 작업 수.
  Future<int> answerRestore(bool resume) async {
    final stored = _pendingRestore;
    _pendingRestore = const [];
    notifyListeners();

    if (!resume || tools == null) {
      _saveQueue();
      return 0;
    }

    var lost = 0;
    final prober = Prober(tools!);
    for (final sj in stored) {
      final specs = await prober.probeAll([for (final c in sj.clips) c.path]);
      if (_disposed) return lost;
      if (specs.any((s) => !s.ok)) {
        lost++;
        continue;
      }
      final items = [
        for (var i = 0; i < specs.length; i++)
          ClipItem(
            id: '${_idSeq++}',
            spec: specs[i],
            userRotation: sj.clips[i].rotation,
            edit: AppState._fitEdit(sj.clips[i].edit, specs[i]),
          ),
      ];
      queue.add(QueuedJob(
        id: 'q${_jobSeq++}',
        clips: items,
        settings: sj.settings,
        plan: JobPlan.analyze(items,
            smoothTransitions: sj.settings.smoothTransitions,
            fadeEnds: sj.settings.fadeEnds),
      ));
    }

    _saveQueue();
    notifyListeners();
    unawaited(_pumpQueue());
    return lost;
  }

  /// 창을 닫기 직전에 부른다.
  ///
  /// 남은 대기열을 적어 두고 ffmpeg 을 직접 끝낸다. 창이 닫힐 때
  /// [dispose] 가 불린다는 보장이 없어서, 여기서 하지 않으면 ffmpeg 이
  /// 주인 없이 계속 돌 수 있다.
  Future<void> prepareForExit() async {
    if (_suffixSaveTimer != null) _flushSuffix();
    _saveQueue();
    _exiting = true;
    KeepAwake.release();
    await _executor?.cancel();
  }

  /// 대기열에 저장돼 있던 결과 설정으로부터 화면의 선택지를 되살린다.
  ///
  /// 작업에는 최종 수치만 남아 있고 "어느 항목을 골랐는지"는 없다.
  /// 그래서 같은 수치의 프리셋이 있으면 그 프리셋을 고른 것으로 보고,
  /// 없으면 직접 입력으로 되살린다 — 어느 쪽이든 수치는 정확히 같다.
  void _restoreChoices(OutputSettings s) {
    useLossless = s.lossless;
    codec = s.codec;
    fitMode = s.fitMode;
    useGpu = s.useGpu;
    // 대기열 작업의 전환 설정은 그 작업 것이다. 화면의 기본값(설정 파일)은
    // 건드리지 않고 지금 목록에만 되살린다.
    smoothTransitions = s.smoothTransitions;
    transitionStyle = s.transitionStyle;
    transitionLength = s.transitionLength;
    fadeEnds = s.fadeEnds;

    final pl = plan;
    if (pl != null) {
      ResolutionOption? r;
      for (final o in pl.resolutions) {
        if (o.width == s.width && o.height == s.height) r = o;
      }
      if (r != null) {
        resolution = r;
        useCustomResolution = false;
      } else {
        useCustomResolution = true;
        customWidth = s.width;
        customHeight = s.height;
      }

      FpsOption? f;
      for (final o in pl.frameRates) {
        if (o.fps == s.frameRate) f = o;
      }
      if (f != null) {
        fps = f;
        useCustomFps = false;
      } else {
        useCustomFps = true;
        // 30000/1001 을 그대로 풀면 29.970029… 가 되어 입력칸이 흉하다.
        // 두 자리로 줄여도 Rational.fromDouble 이 표준값으로 도로 붙여 준다.
        customFpsValue = (s.frameRate.toDouble() * 100).round() / 100;
      }

      // 비트레이트 후보는 위에서 정한 해상도·프레임레이트에 따라 달라지므로
      // 반드시 그 두 개를 정한 뒤에 찾아야 한다.
      BitrateOption? b;
      for (final o in bitrateOptions) {
        if (o.bps == s.videoBitrate) b = o;
      }
      if (b != null) {
        bitrateKind = b.kind;
        useCustomBitrate = false;
      } else {
        useCustomBitrate = true;
        customBitrateMbps = (s.videoBitrate / 1000000 * 10).round() / 10;
      }
    }

    // 프리셋에 없는 수치였다면 접혀 있는 직접 입력 칸을 펴 준다.
    // 펴 주지 않으면 화면에 안 보이는 값이 결과를 좌우한다.
    if (useCustomResolution || useCustomFps || useCustomBitrate) {
      advancedOpen = true;
    }

    // 이름과 폴더도 수치와 같은 사정이다. 자동으로 지었을 때와 결과가
    // 같으면 자동이었다고 보고, 다르면 직접 지은 이름으로 되살린다.
    outputName = s.outputName;
    autoNaming = autoName == s.outputName;

    outputDir = s.outputDir;
    outputDirManual = sourceFolder() != s.outputDir;
  }

  /// 끝난 작업 기록을 목록에서 지운다.
  void clearFinished() {
    queue.removeWhere((j) => j.isFinished);
    notifyListeners();
  }

  /// 실패했거나 취소한 작업을 다시 대기 상태로 돌린다.
  /// 중간 파일이 남아 있으면 이어서 진행된다.
  void retryJob(String id) {
    for (final j in queue) {
      if (j.id == id && (j.status == QueuedStatus.failed ||
          j.status == QueuedStatus.skipped)) {
        j.status = QueuedStatus.waiting;
        j.errorMessage = null;
        j.progress = 0;
      }
    }
    _saveQueue();
    notifyListeners();
    unawaited(_pumpQueue());
  }

  void openFolderOf(QueuedJob job) {
    final path = job.resultPath;
    if (path == null) return;
    try {
      Process.run('explorer', ['/select,', path], runInShell: false);
    } on Object {
      // 무시
    }
  }

  void playResultOf(QueuedJob job) {
    final path = job.resultPath;
    if (path == null) return;
    try {
      Process.run('cmd', ['/c', 'start', '', path], runInShell: false);
    } on Object {
      // 무시
    }
  }
}
