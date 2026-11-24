import 'dart:convert';
import 'dart:io';

import 'job_queue.dart';
import 'models.dart';
import 'planner.dart';
import 'rational.dart';

/// 파일에 적어 둔 작업 하나. 스펙은 저장하지 않는다 — 되살릴 때 다시 읽어야
/// 그 사이 파일이 옮겨지거나 바뀐 것을 알 수 있다.
class StoredJob {
  final List<({String path, int rotation, ClipEdit edit})> clips;
  final OutputSettings settings;

  StoredJob({required this.clips, required this.settings});
}

/// 아직 끝내지 못한 대기열을 파일로 남겨, 재시작 시 이어서 할 수 있게 한다.
/// 대기열이 바뀔 때마다 통째로 다시 적는다.
///
/// 만들던 조각은 출력 폴더의 `.videojoin_temp` 에 완료 표시와 함께 남아 있으므로
/// 되살린 작업은 끊긴 조각부터 이어진다.
///
/// 한글 경로가 들어가므로 **BOM 없는 UTF-8 바이트로 직접 읽고 쓴다.**
class QueueStore {
  static const int _version = 1;

  final String path;

  QueueStore(this.path);

  /// 설정 파일(shared_preferences)과 같은 폴더.
  static String? defaultPath() {
    final appData = Platform.environment['APPDATA'];
    if (appData == null || appData.isEmpty) return null;
    return '$appData\\com.example\\videojoin\\pending_queue.json';
  }

  /// 대기 중·만드는 중인 작업만 적는다. 실패했거나 멈춘 작업은 되살리지 않는다.
  void save(List<QueuedJob> queue) {
    final pending = queue
        .where((j) =>
            j.status == QueuedStatus.waiting ||
            j.status == QueuedStatus.running)
        .toList();
    try {
      final file = File(path);
      if (pending.isEmpty) {
        if (file.existsSync()) file.deleteSync();
        return;
      }
      final data = {
        'version': _version,
        'savedAt': DateTime.now().toIso8601String(),
        'jobs': [
          for (final j in pending)
            {
              'clips': [
                for (final c in j.clips.where((c) => c.spec.ok))
                  {
                    'path': c.spec.path,
                    'rotation': c.userRotation,
                    if (!c.edit.isDefault) 'edit': c.edit.toJson(),
                  },
              ],
              'settings': _settingsToJson(j.settings),
            },
        ],
      };
      file.parent.createSync(recursive: true);
      // 임시 파일에 다 쓴 뒤 바꿔치기해 반쯤 쓰인 파일이 남지 않게 한다.
      final tmp = File('$path.tmp');
      tmp.writeAsBytesSync(utf8.encode(jsonEncode(data)), flush: true);
      tmp.renameSync(path);
    } on Object {
      // 저장 실패가 작업을 막으면 안 된다.
    }
  }

  List<StoredJob> load() {
    try {
      final file = File(path);
      if (!file.existsSync()) return const [];
      final text = utf8.decode(file.readAsBytesSync(), allowMalformed: true);
      final json = jsonDecode(text) as Map<String, dynamic>;
      final result = <StoredJob>[];
      for (final e in (json['jobs'] as List?) ?? const []) {
        final m = (e as Map).cast<String, dynamic>();
        final clips = <({String path, int rotation, ClipEdit edit})>[];
        for (final c in (m['clips'] as List?) ?? const []) {
          final cm = (c as Map).cast<String, dynamic>();
          final p = cm['path'] as String?;
          if (p == null || p.isEmpty) continue;
          clips.add((
            path: p,
            rotation: (cm['rotation'] as num?)?.toInt() ?? 0,
            edit: ClipEdit.fromJson(cm['edit']),
          ));
        }
        final s = _settingsFromJson(
            (m['settings'] as Map?)?.cast<String, dynamic>());
        if (clips.isEmpty || s == null) continue;
        result.add(StoredJob(clips: clips, settings: s));
      }
      return result;
    } on Object {
      // 깨진 파일은 없는 것으로 친다.
      return const [];
    }
  }

  void clear() {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } on Object {
      // 못 지워도 다음 저장 때 덮어쓴다.
    }
  }

  static Map<String, dynamic> _settingsToJson(OutputSettings s) => {
        'lossless': s.lossless,
        'width': s.width,
        'height': s.height,
        // 29.97 은 30000/1001 이므로 소수로 적으면 값이 달라진다.
        'fpsNum': s.frameRate.num,
        'fpsDen': s.frameRate.den,
        'videoBitrate': s.videoBitrate,
        'audioBitrate': s.audioBitrate,
        'codec': s.codec.name,
        'fitMode': s.fitMode.name,
        'useGpu': s.useGpu,
        'smooth': s.smoothTransitions,
        'transStyle': s.transitionStyle.name,
        'transLen': s.transitionLength.name,
        'fadeEnds': s.fadeEnds,
        'outputDir': s.outputDir,
        'outputName': s.outputName,
      };

  /// 옛 저장본의 `transColor`(black/white)를 거치기 방식으로 옮긴다.
  static TransitionStyle _styleFromJson(Map<String, dynamic> m) {
    for (final st in TransitionStyle.values) {
      if (st.name == m['transStyle']) return st;
    }
    return m['transColor'] == 'white'
        ? TransitionStyle.dipWhite
        : TransitionStyle.dipBlack;
  }

  static OutputSettings? _settingsFromJson(Map<String, dynamic>? m) {
    if (m == null) return null;
    final dir = m['outputDir'] as String?;
    final name = m['outputName'] as String?;
    final w = (m['width'] as num?)?.toInt();
    final h = (m['height'] as num?)?.toInt();
    final n = (m['fpsNum'] as num?)?.toInt();
    final d = (m['fpsDen'] as num?)?.toInt();
    final vb = (m['videoBitrate'] as num?)?.toInt();
    if (dir == null || name == null || w == null || h == null) return null;
    if (n == null || d == null || d == 0 || vb == null) return null;

    return OutputSettings(
      lossless: m['lossless'] == true,
      width: w,
      height: h,
      frameRate: Rational(n, d),
      videoBitrate: vb,
      audioBitrate: (m['audioBitrate'] as num?)?.toInt() ?? 192000,
      codec: CodecChoice.values.firstWhere((c) => c.name == m['codec'],
          orElse: () => CodecChoice.h264),
      fitMode: FitMode.values.firstWhere((f) => f.name == m['fitMode'],
          orElse: () => FitMode.pad),
      useGpu: m['useGpu'] != false,
      smoothTransitions: m['smooth'] == true,
      transitionStyle: _styleFromJson(m),
      transitionLength: TransitionLength.values.firstWhere(
          (c) => c.name == m['transLen'],
          orElse: () => TransitionLength.normal),
      fadeEnds: m['fadeEnds'] == true,
      outputDir: dir,
      outputName: name,
    );
  }
}
