import '../engine/models.dart';
import '../engine/planner.dart';

enum QueuedStatus {
  waiting('대기 중'),
  running('만드는 중'),
  done('완료'),
  failed('실패'),
  skipped('건너뜀');

  final String label;
  const QueuedStatus(this.label);
}

/// 대기열에 올라간 작업 하나.
///
/// 넣는 시점의 목록과 설정을 복사해 보관하므로, 이후 화면에서 목록을 바꿔도 영향이 없다.
class QueuedJob {
  final String id;
  final List<ClipItem> clips;
  final OutputSettings settings;
  final JobPlan plan;

  QueuedStatus status;
  String? resultPath;
  String? errorMessage;
  int? actualBytes;

  /// 진행률(0~1). 실행 중일 때만 의미가 있다.
  double progress;
  String currentFile;

  String stageLabel;
  int fileIndex;
  int fileCount;
  Duration? remaining;

  QueuedJob({
    required this.id,
    required this.clips,
    required this.settings,
    required this.plan,
    this.status = QueuedStatus.waiting,
    this.progress = 0,
    this.currentFile = '',
    this.stageLabel = '',
    this.fileIndex = 0,
    this.fileCount = 0,
    this.remaining,
  });

  String get title => '${settings.outputName}.mp4';

  int get clipCount => clips.where((c) => c.spec.ok).length;

  double get totalDuration => plan.outputDuration(settings);

  int get estimatedBytes => plan.estimateOutputBytes(settings);

  bool get isFinished =>
      status == QueuedStatus.done ||
      status == QueuedStatus.failed ||
      status == QueuedStatus.skipped;

  String get summaryLine {
    final parts = <String>[
      '$clipCount개',
      formatDurationKorean(totalDuration),
    ];
    if (settings.lossless) {
      parts.add('그대로 이어붙이기');
    } else {
      parts.add('${settings.width}×${settings.height}');
      parts.add(settings.frameRate.label);
      parts.add(formatBitrate(settings.videoBitrate));
    }
    return parts.join(' · ');
  }
}
