part of 'app_state.dart';

// 확장 메서드 안에서 notifyListeners 를 부르는 건 의도된 것이다. 이 파일들은
// AppState 의 한 부분일 뿐이라 알림 시점과 순서가 원래와 같다.
// ignore_for_file: invalid_use_of_protected_member

/// 대기열에 넣기, 순차 처리 워커, 일시정지·재개, 대기 작업 수정, 완료 후 컴퓨터 끄기.
extension AppStateWorker on AppState {
  // --- 실행 -----------------------------------------------------------------

  /// 지금 목록과 설정을 대기열에 넣는다.
  ///
  /// 넣는 즉시 목록은 비워져서 바로 다음 묶음을 준비할 수 있고,
  /// 뒤에서는 워커가 알아서 순서대로 처리한다.
  /// 반환값이 null 이 아니면 넣지 못한 이유다.
  String? enqueueCurrent() {
    if (tools == null) return 'ffmpeg 을 찾을 수 없습니다.';
    final issue = blockingIssue;
    if (issue != null) return issue;
    final settings = buildSettings();
    final pl = plan;
    if (settings == null || pl == null) return '설정을 읽을 수 없습니다.';

    // 대기열에 이미 같은 출력 경로가 있으면 결과가 덮어써진다.
    final outPath = settings.outputPath.toLowerCase();
    for (final j in queue) {
      if (!j.isFinished && j.settings.outputPath.toLowerCase() == outPath) {
        return '대기열에 같은 이름의 작업이 이미 있습니다.';
      }
    }

    // 넣는 시점의 목록을 복사해 둔다. 이후 화면에서 목록을 바꿔도
    // 예약된 작업에는 영향이 없어야 한다.
    final snapshot = [
      for (final c in clips)
        ClipItem(
          id: c.id,
          spec: c.spec,
          userRotation: c.userRotation,
          edit: c.edit,
          thumbnailPath: c.thumbnailPath,
        ),
    ];

    queue.add(QueuedJob(
      id: 'q${_jobSeq++}',
      clips: snapshot,
      settings: settings,
      plan: pl,
    ));

    clearAll();
    notifyListeners();
    _saveQueue();

    unawaited(_pumpQueue());
    return null;
  }

  /// 대기 중인 작업을 하나씩 처리한다. 이미 돌고 있으면 아무것도 하지 않는다.
  Future<void> _pumpQueue() async {
    if (_workerBusy) return;
    _workerBusy = true;
    if (preventSleep) KeepAwake.acquire();
    try {
      while (true) {
        QueuedJob? next;
        for (final j in queue) {
          if (j.status == QueuedStatus.waiting) {
            next = j;
            break;
          }
        }
        if (next == null) break;
        await _runQueuedJob(next);
        // 창이 닫힌 뒤에는 다음 작업을 시작하지 않는다.
        if (_disposed || _exiting) break;
        _saveQueue();
      }
    } finally {
      _workerBusy = false;
      // 할 일이 없어졌으니 컴퓨터를 놓아 준다.
      // 컴퓨터 끄기가 걸려 있어도 종료 자체는 절전과 무관하다.
      KeepAwake.release();
      notifyListeners();

      // 여기는 대기열을 모두 비운 시점이다. 작업마다 처리하면
      // 폴더 창이 여러 개 뜨고 종료도 중간에 걸린다.
      final anyDone = queue.any((j) => j.status == QueuedStatus.done);

      if (shutdownWhenDone && anyDone) {
        // 컴퓨터를 끌 거면 폴더를 열어봐야 볼 사람이 없다. 끄기가 우선.
        _scheduleShutdown();
      } else if (openFolderWhenDone && anyDone) {
        _openLastResultFolder();
      }
    }
  }

  /// 마지막으로 성공한 작업의 결과 폴더를 연다.
  void _openLastResultFolder() {
    for (final j in queue.reversed) {
      if (j.status == QueuedStatus.done && j.resultPath != null) {
        openFolderOf(j);
        return;
      }
    }
  }

  Future<void> _runQueuedJob(QueuedJob job) async {
    final log = JobLog.create();
    lastLogPath = log.file.path;

    final exec = Executor(tools: tools!, encoders: encoders, log: log);
    _executor = exec;

    job.status = QueuedStatus.running;
    job.progress = 0;
    job.currentFile = '';
    notifyListeners();

    final completer = Completer<void>();

    _sub = exec.run(job.clips, job.settings).listen((prog) {
      job.progress = prog.progress;
      job.currentFile = prog.currentFile;
      job.stageLabel = prog.stage.label;
      job.fileIndex = prog.fileIndex;
      job.fileCount = prog.fileCount;
      job.remaining = prog.remaining;
      if (prog.estimatedBytes != null) job.actualBytes = prog.estimatedBytes;

      switch (prog.stage) {
        case JobStage.done:
          job.status = QueuedStatus.done;
          job.progress = 1;
          job.resultPath = prog.outputPath;
          try {
            final f = File(prog.outputPath!);
            if (f.existsSync()) job.actualBytes = f.lengthSync();
          } on Object {
            // 무시
          }
          Notify.success();
          if (!completer.isCompleted) completer.complete();
          break;
        case JobStage.failed:
          job.status = QueuedStatus.failed;
          job.errorMessage = prog.errorMessage == null
              ? prog.message
              : '${prog.message} (${prog.errorMessage})';
          Notify.failure();
          if (!completer.isCompleted) completer.complete();
          break;
        case JobStage.cancelled:
          job.status = QueuedStatus.skipped;
          job.errorMessage = '사용자가 취소했습니다.';
          if (!completer.isCompleted) completer.complete();
          break;
        default:
          break;
      }
      notifyListeners();
    }, onDone: () {
      if (!completer.isCompleted) completer.complete();
    });

    await completer.future;
    await _sub?.cancel();
    _sub = null;
    _executor = null;
    notifyListeners();
  }

  /// 지금 만들고 있는 작업을 멈춘다. 대기 중인 나머지는 이어서 처리된다.
  Future<void> cancelRunning() async {
    await _executor?.cancel();
  }

  /// 지금 만들고 있는 작업이 얼어 있는지.
  bool get isPaused => _executor?.isPaused ?? false;

  /// 만들던 것을 그 자리에서 멈춘다. 중간 결과는 그대로 남는다.
  ///
  /// 멈춰 있는 동안에는 다음 작업도 시작되지 않는다 — 대기열 처리기가
  /// 지금 작업이 끝나기를 기다리고 있기 때문이다.
  void pauseRunning() {
    _executor?.pause();
    // 멈춰 둔 동안까지 컴퓨터를 깨워 둘 이유가 없다. 일시정지하고 자리를
    // 비우면 평소처럼 절전에 들어가야 한다.
    KeepAwake.release();
    notifyListeners();
  }

  void resumeRunning() {
    _executor?.resume();
    KeepAwake.apply(keep: preventSleep && _workerBusy);
    notifyListeners();
  }

  /// 창을 닫기 전에 물어봐야 하는지.
  ///
  /// 만들던 중이거나 줄 서 있는 작업이 있으면 그냥 닫으면 안 된다.
  /// 일시정지도 "진행 중"으로 본다 — 멈춰 있을 뿐 끝난 게 아니다.
  /// 대기열이 비어 있거나 전부 끝났으면 묻지 않고 닫는다.
  bool get hasUnfinishedWork => queueActive;

  /// 아직 시작하지 않은 작업을 대기열에서 뺀다.
  void removeQueued(String id) {
    queue.removeWhere((j) => j.id == id && j.status == QueuedStatus.waiting);
    _saveQueue();
    notifyListeners();
  }

  /// 기다리는 작업의 차례를 한 칸 앞([delta] -1)이나 뒤(+1)로 옮긴다.
  ///
  /// 처리기는 목록에서 맨 먼저 나오는 대기 작업을 집으므로, 목록 안의 자리만 바꾸면 된다.
  /// 끝난 작업이나 만드는 중인 작업은 건너뛰고 **기다리는 작업끼리만** 바꾼다.
  void moveQueued(String id, int delta) {
    final i = queue.indexWhere((j) => j.id == id);
    if (i < 0 || queue[i].status != QueuedStatus.waiting) return;
    final step = delta < 0 ? -1 : 1;
    for (var k = i + step; k >= 0 && k < queue.length; k += step) {
      if (queue[k].status == QueuedStatus.waiting) {
        final t = queue[i];
        queue[i] = queue[k];
        queue[k] = t;
        _saveQueue();
        notifyListeners();
        return;
      }
    }
  }

  /// 기다리는 작업들 가운데 이 작업이 맨 앞/맨 뒤인지 (화살표를 끄는 데 쓴다).
  bool isFirstWaiting(String id) {
    for (final j in queue) {
      if (j.status == QueuedStatus.waiting) return j.id == id;
    }
    return false;
  }

  bool isLastWaiting(String id) {
    for (final j in queue.reversed) {
      if (j.status == QueuedStatus.waiting) return j.id == id;
    }
    return false;
  }

  /// 아직 시작하지 않은 작업을 편집기로 도로 가져온다.
  ///
  /// 이미 만들고 있는 작업은 [cancelRunning] 으로 멈춰야 하지만,
  /// 순서를 기다리는 작업은 **원래 편집기로 되돌려** 목록·순서·회전·화질까지
  /// 그대로 고친 뒤 [enqueueCurrent] 로 다시 올릴 수 있다.
  ///
  /// 되돌린 작업은 대기열에서 빠진다. 남겨두면 고치는 사이에 순서가 돌아와
  /// 옛 설정으로 만들어져 버린다.
  ///
  /// 반환값이 null 이 아니면 되돌리지 못한 이유다.
  String? editQueued(String id) {
    QueuedJob? job;
    for (final j in queue) {
      if (j.id == id) {
        job = j;
        break;
      }
    }
    if (job == null) return '작업을 찾을 수 없습니다.';
    if (job.status == QueuedStatus.running) {
      return '지금 만들고 있는 작업은 고칠 수 없습니다. 먼저 중지해 주세요.';
    }
    // 실패했거나 중지한 작업도 되돌릴 수 있다.
    if (job.status == QueuedStatus.done) {
      return '이미 다 만든 작업입니다.';
    }

    // 대기열에서 먼저 빼야 이름 겹침 검사(_avoidCollision)가 자기 자신을
    // 세지 않는다. 그대로 두면 되돌릴 때마다 "(2)" 가 붙는다.
    queue.remove(job);

    clips
      ..clear()
      ..addAll([
        for (final c in job.clips)
          ClipItem(
            id: '${_idSeq++}',
            spec: c.spec,
            userRotation: c.userRotation,
            edit: c.edit,
            thumbnailPath: c.thumbnailPath,
          ),
      ]);

    // 같은 목록이므로 계획은 똑같이 다시 나온다. 기본값을 먼저 깔아 두고
    // 그 위에 이 작업이 갖고 있던 선택을 덮어쓴다.
    // 전환 설정은 무손실 가능 여부를 바꾸므로 계획을 세우기 전에 되살린다.
    smoothTransitions = job.settings.smoothTransitions;
    transitionStyle = job.settings.transitionStyle;
    transitionLength = job.settings.transitionLength;
    fadeEnds = job.settings.fadeEnds;
    _recomputePlan(resetChoices: true);
    _restoreChoices(job.settings);

    duplicateSkipped = 0;
    _saveQueue();
    notifyListeners();
    unawaited(_fillThumbnails());
    return null;
  }

  /// 완료 후 컴퓨터 끄기.
  ///
  /// Windows 가 띄우는 종료 경고는 사용자가 알아보기 어렵고 취소 방법도
  /// 모른다. 그래서 넉넉히 2분을 주고, 앱 화면에도 큰 취소 버튼을 띄운다.
  void _scheduleShutdown() {
    try {
      Process.run(
        'shutdown',
        ['/s', '/t', '${AppState.shutdownDelaySeconds}'],
        runInShell: false,
      );
      shutdownAt = DateTime.now().add(
        const Duration(seconds: AppState.shutdownDelaySeconds),
      );
      notifyListeners();
    } on Object {
      // 실패해도 결과물은 이미 만들어졌다.
    }
  }

  /// 예약된 컴퓨터 끄기를 취소한다.
  void cancelShutdown() {
    try {
      Process.run('shutdown', ['/a'], runInShell: false);
    } on Object {
      // 무시
    }
    shutdownAt = null;
    shutdownWhenDone = false;
    notifyListeners();
  }
}
