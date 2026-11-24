part of 'app_state.dart';

// 확장 메서드 안에서 notifyListeners 를 부르는 건 의도된 것이다. 이 파일들은
// AppState 의 한 부분일 뿐이라 알림 시점과 순서가 원래와 같다.
// ignore_for_file: invalid_use_of_protected_member

/// 영상 목록(추가·삭제·정렬·회전·편집)과 작업 목록 파일 저장/불러오기.
extension AppStateClips on AppState {
  // --- 파일 추가/제거 --------------------------------------------------------

  /// 드롭되거나 선택된 경로들을 받아들인다.
  /// 폴더가 들어오면 안의 영상 파일을 전부 펼친다.
  Future<void> addPaths(List<String> paths) async {
    if (tools == null) return;

    final files = <String>[];
    for (final raw in paths) {
      final dir = Directory(raw);
      if (dir.existsSync()) {
        try {
          final inner = dir
              .listSync()
              .whereType<File>()
              .map((f) => f.path)
              .where(isVideoFile)
              .toList()
            ..sort(naturalCompare);
          files.addAll(inner);
        } on Object {
          // 접근 불가 폴더는 건너뛴다.
        }
        continue;
      }
      if (File(raw).existsSync() && isVideoFile(raw)) files.add(raw);
    }

    if (files.isEmpty) return;

    // 이미 목록에 있는 파일은 다시 넣지 않는다. 같은 파일을 두 번
    // 끌어다 놓는 건 대개 실수다.
    final existing = clips.map((c) => p.normalize(c.spec.path).toLowerCase()).toSet();
    final fresh = files
        .where((f) => !existing.contains(p.normalize(p.absolute(f)).toLowerCase()))
        .toList();

    duplicateSkipped = files.length - fresh.length;
    if (fresh.isEmpty) {
      notifyListeners();
      return;
    }

    loading = true;
    loadDone = 0;
    loadTotal = fresh.length;
    notifyListeners();

    final prober = Prober(tools!);
    final specs = await prober.probeAll(fresh, onProgress: (done, total) {
      loadDone = done;
      notifyListeners();
    });

    for (final s in specs) {
      clips.add(ClipItem(id: '${_idSeq++}', spec: s));
    }

    loading = false;
    _recomputePlan(resetChoices: true);
    notifyListeners();

    // 썸네일은 백그라운드로 채운다. 목록은 먼저 떠야 한다.
    unawaited(_fillThumbnails());
  }

  Future<void> _fillThumbnails() async {
    final t = Thumbnailer(tools!);
    for (final c in List<ClipItem>.from(clips)) {
      // 창을 닫았으면 남은 썸네일은 만들 필요가 없다.
      if (_disposed) return;
      if (c.thumbnailPath != null || !c.spec.ok) continue;
      final path = await t.generate(c.spec);
      if (path != null) {
        c.thumbnailPath = path;
        notifyListeners();
      }
    }
  }

  void removeClip(String id) {
    clips.removeWhere((c) => c.id == id);
    _recomputePlan();
    notifyListeners();
  }

  void clearAll() {
    clips.clear();
    plan = null;
    resolution = null;
    fps = null;
    duplicateSkipped = 0;
    notifyListeners();
  }

  void moveClip(int from, int to) {
    if (from < 0 || from >= clips.length) return;
    if (to < 0 || to >= clips.length) return;
    final item = clips.removeAt(from);
    clips.insert(to, item);
    notifyListeners();
  }

  void sortBy(SortMode mode, {bool descending = false}) {
    sortClips(clips, mode, descending: descending);
    notifyListeners();
  }

  /// 이름순으로 정렬할 때, 파일명 규칙을 자동으로 알아낸 결과가
  /// 평범한 정렬과 다른지 알려준다. 다를 때만 사용자에게 물어보면 된다.
  ///
  /// 돌려주는 두 목록은 각각의 방식으로 정렬한 파일명이다.
  ({List<String> plain, List<String> smart})? nameSortPreview() {
    if (clips.length < 4) return null;
    final names = clips.map((c) => c.spec.fileName).toList();
    final order = detectNameKeyOrder(names);
    if (order.isPlain) return null;

    final plain = [...names]..sort(naturalCompare);
    final smart = [...names]..sort((a, b) => smartNameCompare(a, b, order));
    return (plain: plain, smart: smart);
  }

  void reverseOrder() {
    final r = clips.reversed.toList();
    clips
      ..clear()
      ..addAll(r);
    notifyListeners();
  }

  /// 파일 한 개를 90도씩 돌린다. 두 번 누르면 180도.
  void rotateClip(String id, int delta) {
    final c = clips.firstWhere((c) => c.id == id);
    c.userRotation = (c.userRotation + delta) % 360;
    if (c.userRotation < 0) c.userRotation += 360;
    _recomputePlan();
    notifyListeners();
  }

  /// 영상 한 개의 편집(자르기·소리·밝기)을 바꾼다.
  void setClipEdit(String id, ClipEdit edit) {
    final c = clips.firstWhere((c) => c.id == id);
    c.edit = AppState._fitEdit(edit, c.spec);
    _recomputePlan();
    notifyListeners();
  }

  /// 목록에 있는 모든 영상의 편집을 지운다.
  void clearAllEdits() {
    for (final c in clips) {
      c.edit = ClipEdit.none;
    }
    _recomputePlan();
    notifyListeners();
  }

  int get editedClipCount => clips.where((c) => !c.edit.isDefault).length;

  // --- 작업 목록 저장/불러오기 ------------------------------------------------

  /// 순서와 회전까지 그대로 파일로 저장한다.
  Future<String?> saveJobList(String path) async {
    try {
      await JobListFile.save(path, clips);
      return null;
    } on Object catch (e) {
      return '목록을 저장하지 못했습니다. ($e)';
    }
  }

  /// 저장해 둔 목록을 불러온다.
  /// 경로만 저장돼 있으므로 스펙은 다시 읽는다 — 그 사이 파일이
  /// 옮겨졌거나 바뀌었을 수 있다.
  Future<String?> loadJobList(String path) async {
    if (tools == null) return 'ffmpeg 을 찾을 수 없습니다.';
    try {
      final entries = await JobListFile.load(path);
      if (entries.isEmpty) return '목록이 비어 있습니다.';

      clips.clear();
      plan = null;
      resolution = null;
      fps = null;
      notifyListeners();

      loading = true;
      loadDone = 0;
      loadTotal = entries.length;
      notifyListeners();

      final prober = Prober(tools!);
      final specs = await prober.probeAll(
        entries.map((e) => e.path).toList(),
        onProgress: (done, total) {
          loadDone = done;
          notifyListeners();
        },
      );

      for (var i = 0; i < specs.length; i++) {
        clips.add(ClipItem(
          id: '${_idSeq++}',
          spec: specs[i],
          userRotation: entries[i].rotation,
          edit: AppState._fitEdit(entries[i].edit, specs[i]),
        ));
      }

      loading = false;
      _recomputePlan(resetChoices: true);
      notifyListeners();
      unawaited(_fillThumbnails());

      final missing = specs.where((s) => !s.ok).length;
      if (missing > 0) {
        return '$missing개 영상을 찾을 수 없습니다. 파일이 옮겨졌거나 지워졌을 수 있습니다.';
      }
      return null;
    } on Object catch (e) {
      loading = false;
      notifyListeners();
      return '목록을 불러오지 못했습니다. ($e)';
    }
  }
}
