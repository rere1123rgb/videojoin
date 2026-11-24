part of 'app_state.dart';

// 확장 메서드 안에서 notifyListeners 를 부르는 건 의도된 것이다. 이 파일들은
// AppState 의 한 부분일 뿐이라 알림 시점과 순서가 원래와 같다.
// ignore_for_file: invalid_use_of_protected_member

/// 계획 재계산, 저장 이름·폴더 계산, 출력 선택(해상도·fps·전환·이름·폴더)과 설정 기억.
extension AppStatePlan on AppState {
  Future<void> setSmoothTransitions(bool v) async {
    smoothTransitions = v;
    // 켜면 다시 만들기로 넘어간다(무손실로는 할 수 없다).
    _recomputePlan();
    notifyListeners();
    await _prefs?.setBool('smoothTransitions', v);
  }

  Future<void> setTransitionStyle(TransitionStyle v) async {
    transitionStyle = v;
    notifyListeners();
    await _prefs?.setString('transitionStyle', v.name);
  }

  Future<void> setTransitionLength(TransitionLength v) async {
    transitionLength = v;
    notifyListeners();
    await _prefs?.setString('transitionLength', v.name);
  }

  Future<void> setFadeEnds(bool v) async {
    fadeEnds = v;
    // 켜면 다시 만들기로 넘어간다(무손실로는 할 수 없다).
    _recomputePlan();
    notifyListeners();
    await _prefs?.setBool('fadeEnds', v);
  }

  // --- 계획 재계산 -----------------------------------------------------------

  void _recomputePlan({bool resetChoices = false}) {
    if (clips.isEmpty) {
      plan = null;
      resolution = null;
      fps = null;
      return;
    }

    final newPlan = JobPlan.analyze(clips,
        smoothTransitions: smoothTransitions, fadeEnds: fadeEnds);
    plan = newPlan;

    // 무손실이 가능하면 그게 기본이다.
    // 화질 손실이 없고 몇십 초면 끝나므로 다른 선택지보다 언제나 낫다.
    if (resetChoices || !newPlan.losslessPossible) {
      useLossless = newPlan.losslessPossible;
    }

    // 해상도·프레임레이트 기본값은 언제나 원본 최대치다.
    // 사용자가 이미 고른 값이 여전히 유효하면 그대로 둔다.
    if (resolution == null ||
        !newPlan.resolutions.any((r) => r == resolution) ||
        resetChoices) {
      resolution = newPlan.defaultResolution;
    }
    if (fps == null ||
        !newPlan.frameRates.any((f) => f.fps == fps!.fps) ||
        resetChoices) {
      fps = newPlan.defaultFps;
    }

    // 수동 이름은 비어 있을 때만 채워 준다(자동 이름을 출발점으로).
    // 저장 폴더는 effectiveOutputDir 이 알아서 영상 폴더를 따라가므로
    // 여기서 손대지 않는다.
    if (outputName.isEmpty && clips.isNotEmpty) {
      outputName = autoName;
    }
  }

  /// 영상들이 들어 있던 폴더. 자동 이름과 저장 위치의 기준이 된다.
  ///
  /// **가장 많은 영상이 온 폴더**를 고른다. 보통 한 폴더에서 통째로 고르기
  /// 때문에 이 규칙이면 대부분 맞는다.
  /// 여러 폴더에서 같은 수만큼 왔으면 **목록 맨 위** 영상의 폴더를 쓴다 —
  /// 그게 결과물의 첫 장면이라 사용자가 예측하기 쉽다.
  String? sourceFolder() {
    final valid = clips.where((c) => c.spec.ok).toList();
    if (valid.isEmpty) return null;

    final counts = <String, int>{};
    for (final c in valid) {
      final dir = p.dirname(c.spec.path);
      counts[dir] = (counts[dir] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;

    var best = 0;
    for (final v in counts.values) {
      if (v > best) best = v;
    }
    final tops = counts.entries
        .where((e) => e.value == best)
        .map((e) => e.key)
        .toList();
    if (tops.length == 1) return tops.first;

    // 동률 — 목록 맨 위 영상의 폴더로 정한다.
    final firstDir = p.dirname(valid.first.spec.path);
    return tops.contains(firstDir) ? firstDir : tops.first;
  }

  /// 폴더 이름에서 만든 파일 이름 (접미사 포함).
  String get autoName {
    final dir = sourceFolder();
    var base = dir == null ? '' : p.basename(dir).trim();

    // C:\ 같은 드라이브 루트는 폴더 이름이 없다.
    if (base.isEmpty || base.endsWith(':')) base = '합친영상';

    // 파일 이름에 쓸 수 없는 글자를 걸러낸다.
    base = base.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (base.isEmpty) base = '합친영상';
    if (base.length > 40) base = base.substring(0, 40).trim();

    return '$base$nameSuffix';
  }

  /// 실제로 쓰이는 파일 이름.
  ///
  /// 자동 이름은 폴더 이름에서 나오므로, 같은 폴더에서 두 묶음을 만들면
  /// 이름이 겹친다. 그때는 탐색기처럼 뒤에 번호를 붙여 피한다.
  /// 직접 입력한 이름은 사용자의 뜻이므로 건드리지 않는다.
  String get effectiveOutputName {
    final n = (autoNaming ? autoName : outputName).trim();
    final base = n.isEmpty ? '합친영상' : n;
    return autoNaming ? _avoidCollision(base) : base;
  }

  /// 대기열에 이미 있거나 폴더에 이미 있는 이름이면 (2), (3) … 을 붙인다.
  String _avoidCollision(String base) {
    final dir = effectiveOutputDir;

    bool taken(String name) {
      for (final j in queue) {
        if (!j.isFinished && j.settings.outputName == name) return true;
      }
      if (dir.isEmpty) return false;
      try {
        return File(p.join(dir, '$name.mp4')).existsSync();
      } on Object {
        return false;
      }
    }

    if (!taken(base)) return base;
    for (var i = 2; i < 1000; i++) {
      final candidate = '$base ($i)';
      if (!taken(candidate)) return candidate;
    }
    return base;
  }

  /// 실제로 쓰이는 저장 폴더.
  /// 직접 고른 적이 없으면 영상이 있던 폴더를 따라간다.
  String get effectiveOutputDir {
    if (outputDirManual && outputDir.isNotEmpty) return outputDir;
    return sourceFolder() ?? outputDir;
  }

  /// 저장 폴더가 지금 영상 폴더를 따라가고 있는지.
  bool get outputDirIsAuto =>
      !outputDirManual && sourceFolder() != null;

  /// 영상이 있던 폴더로 되돌릴 수 있는 상태인지.
  bool get canResetOutputDir =>
      outputDirManual && sourceFolder() != null &&
      sourceFolder() != outputDir;

  // --- 설정 변경 -------------------------------------------------------------

  void setLossless(bool v) {
    useLossless = v;
    notifyListeners();
  }

  void setResolution(ResolutionOption r) {
    resolution = r;
    notifyListeners();
  }

  void setFps(FpsOption f) {
    fps = f;
    notifyListeners();
  }

  void setBitrateKind(BitrateKind k) {
    bitrateKind = k;
    notifyListeners();
  }

  void setCodec(CodecChoice c) {
    codec = c;
    notifyListeners();
  }

  void setFitMode(FitMode m) {
    fitMode = m;
    notifyListeners();
  }

  Future<void> setUseGpu(bool v) async {
    useGpu = v;
    await _prefs?.setBool('useGpu', v);
    notifyListeners();
  }

  void setShutdownWhenDone(bool v) {
    shutdownWhenDone = v;
    notifyListeners();
  }

  Future<void> setOpenFolderWhenDone(bool v) async {
    openFolderWhenDone = v;
    await _prefs?.setBool('openFolderWhenDone', v);
    notifyListeners();
  }

  Future<void> setPreventSleep(bool v) async {
    preventSleep = v;
    await _prefs?.setBool('preventSleep', v);
    // 이미 만들고 있는 중이면 곧바로 반영한다.
    KeepAwake.apply(keep: v && _workerBusy && !isPaused);
    notifyListeners();
  }

  /// 사용자가 [폴더 바꾸기]로 직접 고른 경우.
  Future<void> setOutputDir(String dir) async {
    outputDir = dir;
    outputDirManual = true;
    await _prefs?.setString('outputDir', dir);
    notifyListeners();
  }

  /// 영상이 있던 폴더로 되돌린다.
  void resetOutputDirToSource() {
    outputDirManual = false;
    notifyListeners();
  }

  void setOutputName(String name) {
    outputName = name;
    notifyListeners();
  }

  Future<void> setAutoNaming(bool v) async {
    autoNaming = v;
    // 수동으로 바꾸는 순간, 지금 보이던 자동 이름을 편집 출발점으로 넣어 준다.
    // 빈 칸으로 떨어뜨리면 처음부터 지어내야 한다.
    if (!v && outputName.trim().isEmpty) outputName = autoName;
    await _prefs?.setBool('autoNaming', v);
    notifyListeners();
  }

  /// 화면은 곧바로 바꾸고, 파일에 적는 일은 타자가 멈춘 뒤로 미룬다.
  ///
  /// 글자마다 파일을 쓰면 화면이 늦고, 쓰기가 겹치면 마지막 글자가 아닌 값이 저장될 수 있다.
  Future<void> setNameSuffix(String s) async {
    nameSuffix = s;
    notifyListeners();
    _suffixSaveTimer?.cancel();
    _suffixSaveTimer = Timer(const Duration(milliseconds: 400), _flushSuffix);
  }

  void _flushSuffix() {
    _suffixSaveTimer?.cancel();
    _suffixSaveTimer = null;
    unawaited(_prefs?.setString('nameSuffix', nameSuffix));
  }
}
