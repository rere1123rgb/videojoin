part of 'app_state.dart';

// 확장 메서드 안에서 notifyListeners 를 부르는 건 의도된 것이다. 이 파일들은
// AppState 의 한 부분일 뿐이라 알림 시점과 순서가 원래와 같다.
// ignore_for_file: invalid_use_of_protected_member

/// 초기화·바로가기·화면 배율 같은 시작 단계 동작.
extension AppStateInit on AppState {
  // --- 초기화 ---------------------------------------------------------------

  Future<void> init() async {
    final found = FFTools.locate();
    if (found == null) {
      fatalError = 'ffmpeg 파일을 찾을 수 없습니다.\n'
          '프로그램을 다시 설치해 주세요.';
      initialized = true;
      notifyListeners();
      return;
    }
    tools = found;

    _prefs = await SharedPreferences.getInstance();
    outputDir = _prefs?.getString('outputDir') ?? AppState._defaultOutputDir();
    useGpu = _prefs?.getBool('useGpu') ?? true;
    uiScaleBoost = _prefs?.getDouble('uiScaleBoost') ?? 1.0;
    openFolderWhenDone = _prefs?.getBool('openFolderWhenDone') ?? false;
    preventSleep = _prefs?.getBool('preventSleep') ?? false;
    smoothTransitions = _prefs?.getBool('smoothTransitions') ?? false;
    // 예전 버전은 'transitionColor'(black/white)만 저장했다.
    final oldColor = _prefs?.getString('transitionColor');
    transitionStyle = TransitionStyle.values.firstWhere(
        (c) => c.name == _prefs?.getString('transitionStyle'),
        orElse: () => oldColor == 'white'
            ? TransitionStyle.dipWhite
            : TransitionStyle.dipBlack);
    transitionLength = TransitionLength.values.firstWhere(
        (c) => c.name == _prefs?.getString('transitionLength'),
        orElse: () => TransitionLength.normal);
    fadeEnds = _prefs?.getBool('fadeEnds') ?? false;
    autoNaming = _prefs?.getBool('autoNaming') ?? true;
    nameSuffix = _prefs?.getString('nameSuffix') ?? '';

    JobLog.prune();
    Thumbnailer.prune();
    FrameGrabber.prune();
    AudioPrep.prune();

    initialized = true;
    notifyListeners();

    // 하드웨어 인코더 감지는 시간이 조금 걸리므로 화면을 먼저 띄우고 뒤에서 돌린다.
    encoders = await EncoderSupport.detect(found);
    if (!encoders.anyGpu) useGpu = false;
    notifyListeners();
  }


  /// 시작할 때 바로가기를 점검한다.
  ///
  /// [init] 과 분리해 둔 이유: 이 작업은 사용자 시스템(시작 메뉴, 바탕화면)에
  /// 파일을 만든다. 상태 초기화에 그런 부작용이 섞여 있으면 테스트에서도
  /// 바로가기가 생겨 테스트끼리 간섭한다.
  /// 진짜 앱을 띄울 때만 부르도록 밖으로 뺀다.
  Future<void> checkShortcutsOnStartup() async {
    // 시작 메뉴에는 조용히 등록한다. 이미 있으면 아무 일도 하지 않는다.
    try {
      await Shortcuts.ensureStartMenu();
    } on Object {
      // 실패해도 프로그램 사용에는 지장이 없다.
    }
    if (_disposed) return;

    // 바탕화면은 사용자 화면을 건드리는 일이라 물어보고 만든다.
    // 물어보는 건 딱 한 번뿐 — 대답이 무엇이었든 다시 묻지 않는다.
    final asked = _prefs?.getBool('askedDesktopShortcut') ?? false;
    if (asked) return;

    final exists = await Shortcuts.desktopExists();
    if (_disposed) return;
    if (exists) {
      // 이미 있으면 물어볼 이유가 없다. 물어본 것으로 표시해 둔다.
      await _prefs?.setBool('askedDesktopShortcut', true);
      return;
    }

    needAskDesktopShortcut = true;
    notifyListeners();
  }

  /// 팝업에 답한 뒤 호출한다. [create] 가 true 면 바로가기를 만든다.
  Future<void> answerDesktopShortcut(bool create) async {
    needAskDesktopShortcut = false;
    await _prefs?.setBool('askedDesktopShortcut', true);
    notifyListeners();
    if (create) {
      try {
        await Shortcuts.createDesktop();
      } on Object {
        // 무시
      }
    }
  }

  Future<void> setUiScaleBoost(double v) async {
    uiScaleBoost = v;
    await _prefs?.setDouble('uiScaleBoost', v);
    notifyListeners();
  }

  // --- 완료 후 동작 ----------------------------------------------------------

  void openLogFolder() {
    try {
      Process.run('explorer', [JobLog.logDirectory().path], runInShell: false);
    } on Object {
      // 무시
    }
  }
}
