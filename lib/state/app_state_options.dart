part of 'app_state.dart';

// 확장 메서드 안에서 notifyListeners 를 부르는 건 의도된 것이다. 이 파일들은
// AppState 의 한 부분일 뿐이라 알림 시점과 순서가 원래와 같다.
// ignore_for_file: invalid_use_of_protected_member

/// 현재 선택에서 파생되는 값과 직접 입력(고급) 값, 실행 전 점검.
extension AppStateOptions on AppState {
  // --- 현재 설정으로부터 파생되는 값 -----------------------------------------

  List<BitrateOption> get bitrateOptions {
    final pl = plan;
    final r = resolution;
    final f = fps;
    if (pl == null || r == null || f == null) return const [];
    return pl.bitrateOptions(r.width, r.height, f.fps, codec);
  }

  BitrateOption? get selectedBitrate {
    final opts = bitrateOptions;
    if (opts.isEmpty) return null;
    for (final o in opts) {
      if (o.kind == bitrateKind) return o;
    }
    return opts.first;
  }

  /// 직접 입력을 켰으면 그 값을, 아니면 프리셋 값을 쓴다.
  int get effectiveWidth =>
      useCustomResolution ? AppState._even(customWidth) : (resolution?.width ?? 1920);
  int get effectiveHeight =>
      useCustomResolution ? AppState._even(customHeight) : (resolution?.height ?? 1080);

  Rational get effectiveFps => useCustomFps
      ? Rational.fromDouble(customFpsValue)
      : (fps?.fps ?? const Rational(30, 1));

  int get effectiveBitrate => useCustomBitrate
      ? (customBitrateMbps * 1000000).round()
      : (selectedBitrate?.bps ?? 8000000);

  OutputSettings? buildSettings() {
    if (resolution == null || fps == null) return null;
    return OutputSettings(
      lossless: useLossless,
      width: effectiveWidth,
      height: effectiveHeight,
      frameRate: effectiveFps,
      videoBitrate: effectiveBitrate,
      codec: codec,
      fitMode: fitMode,
      useGpu: useGpu && encoders.anyGpu,
      smoothTransitions: smoothTransitions && !useLossless,
      transitionStyle: transitionStyle,
      transitionLength: transitionLength,
      fadeEnds: fadeEnds && !useLossless,
      outputDir: effectiveOutputDir,
      outputName: effectiveOutputName,
    );
  }

  void setAdvancedOpen(bool v) {
    advancedOpen = v;
    notifyListeners();
  }

  void setUseCustomResolution(bool v) {
    useCustomResolution = v;
    // 켜는 순간 지금 고른 프리셋 값을 출발점으로 채워준다.
    // 빈 칸에서 시작하면 무엇을 넣어야 할지 알기 어렵다.
    if (v && resolution != null) {
      customWidth = resolution!.width;
      customHeight = resolution!.height;
    }
    notifyListeners();
  }

  void setCustomResolution({int? width, int? height}) {
    if (width != null) customWidth = width;
    if (height != null) customHeight = height;

    // 비율을 묶어 뒀으면 사용자가 건드리지 않은 쪽이 따라온다.
    // 둘 다 한 번에 들어오면 양쪽 다 사용자가 정한 값이므로 손대지 않는다.
    if (lockAspect && (width == null) != (height == null)) {
      if (width != null) {
        final h = _heightForWidth(width);
        if (h != null) customHeight = h;
      } else {
        final w = _widthForHeight(height!);
        if (w != null) customWidth = w;
      }
    }
    notifyListeners();
  }

  /// 원본 비율 고정을 켜고 끈다.
  ///
  /// 켜는 순간 지금 가로를 기준으로 세로를 맞춰 준다. 묶여 있다고 해놓고
  /// 숫자는 비율이 안 맞는 상태로 두면 무엇이 참인지 알 수 없다.
  void setLockAspect(bool v) {
    lockAspect = v;
    if (v) {
      final h = _heightForWidth(customWidth);
      if (h != null) customHeight = h;
    }
    notifyListeners();
  }

  /// 원본 화면의 가로÷세로. 원본을 알 수 없으면 null.
  double? get sourceAspect {
    final r = plan?.defaultResolution;
    if (r == null || r.width <= 0 || r.height <= 0) return null;
    return r.width / r.height;
  }

  /// `16:9` 처럼 사람이 읽을 수 있는 비율. 깔끔하게 안 떨어지면 null.
  String? get sourceAspectLabel {
    final r = plan?.defaultResolution;
    if (r == null || r.width <= 0 || r.height <= 0) return null;

    var a = r.width;
    var b = r.height;
    while (b != 0) {
      final t = b;
      b = a % b;
      a = t;
    }
    if (a == 0) return null;
    final w = r.width ~/ a;
    final h = r.height ~/ a;
    // 427:240 같은 값은 알려줘도 도움이 안 된다.
    if (w > 99 || h > 99) return null;
    return '$w:$h';
  }

  int? _heightForWidth(int width) {
    final a = sourceAspect;
    if (a == null || a <= 0 || width <= 0) return null;
    return AppState._toEven(width / a);
  }

  int? _widthForHeight(int height) {
    final a = sourceAspect;
    if (a == null || a <= 0 || height <= 0) return null;
    return AppState._toEven(height * a);
  }

  void setUseCustomBitrate(bool v) {
    useCustomBitrate = v;
    if (v) {
      final b = selectedBitrate;
      if (b != null) customBitrateMbps = (b.bps / 1000000 * 10).round() / 10;
    }
    notifyListeners();
  }

  void setCustomBitrate(double mbps) {
    customBitrateMbps = mbps;
    notifyListeners();
  }

  void setUseCustomFps(bool v) {
    useCustomFps = v;
    if (v && fps != null) {
      customFpsValue = (fps!.fps.toDouble() * 100).round() / 100;
    }
    notifyListeners();
  }

  void setCustomFps(double v) {
    customFpsValue = v;
    notifyListeners();
  }

  /// 직접 입력한 값이 쓸 만한지 확인한다. 문제가 없으면 null.
  String? get customValueIssue {
    if (useCustomResolution) {
      if (customWidth < 160 || customWidth > 7680) {
        return '가로 크기는 160 ~ 7680 사이로 넣어 주세요.';
      }
      if (customHeight < 160 || customHeight > 4320) {
        return '세로 크기는 160 ~ 4320 사이로 넣어 주세요.';
      }
    }
    if (useCustomBitrate) {
      if (customBitrateMbps < 0.3 || customBitrateMbps > 400) {
        return '비트레이트는 0.3 ~ 400 Mbps 사이로 넣어 주세요.';
      }
    }
    if (useCustomFps) {
      if (customFpsValue < 1 || customFpsValue > 240) {
        return '프레임레이트는 1 ~ 240 사이로 넣어 주세요.';
      }
    }
    return null;
  }

  int get estimatedBytes {
    final pl = plan;
    final s = buildSettings();
    if (pl == null || s == null) return 0;
    return pl.estimateOutputBytes(s);
  }

  double get estimatedSeconds {
    final pl = plan;
    final s = buildSettings();
    if (pl == null || s == null) return 0;
    return pl.estimateSeconds(s, gpuAvailable: encoders.anyGpu);
  }

  /// 저장할 드라이브의 여유 공간(바이트). 알 수 없으면 -1.
  int get freeSpace {
    try {
      final dir = Directory(outputDir);
      if (!dir.existsSync()) return -1;
      // Dart 표준 라이브러리에 디스크 여유 공간 API 가 없다.
      // 대신 실행 중 ffmpeg 이 실패하면 메시지로 안내한다.
      return -1;
    } on Object {
      return -1;
    }
  }

  /// 출력 파일이 이미 있는지.
  bool get outputExists {
    final s = buildSettings();
    if (s == null) return false;
    return File(s.outputPath).existsSync();
  }

  /// 시작 전에 막아야 하는 문제. 없으면 null.
  String? get blockingIssue {
    if (clips.isEmpty) return null;
    if (clips.where((c) => c.spec.ok).isEmpty) {
      return '읽을 수 있는 영상이 없습니다.';
    }
    // 자동 이름은 폴더명에서 만들고 금지 문자를 이미 걸러내므로
    // 사용자가 직접 넣은 이름만 검사한다.
    if (!autoNaming) {
      if (outputName.trim().isEmpty) return '저장할 파일 이름을 입력해 주세요.';
      final invalid = RegExp(r'[\\/:*?"<>|]');
      if (invalid.hasMatch(outputName)) {
        return r'파일 이름에 \ / : * ? " < > | 는 쓸 수 없습니다.';
      }
    }
    if (effectiveOutputDir.trim().isEmpty) {
      return '저장할 폴더를 선택해 주세요.';
    }

    // 직접 입력한 값은 '다시 만들기'일 때만 쓰인다.
    if (!useLossless) {
      final custom = customValueIssue;
      if (custom != null) return custom;
    }

    final s = buildSettings();
    if (s != null) {
      final outPath = p.normalize(s.outputPath).toLowerCase();
      for (final c in clips) {
        if (p.normalize(c.spec.path).toLowerCase() == outPath) {
          return '저장할 파일 이름이 원본 영상과 같습니다.';
        }
      }
    }
    return null;
  }
}
