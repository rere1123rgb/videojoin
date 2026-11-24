import 'package:flutter/material.dart';

import '../../engine/job_queue.dart';
import '../../engine/models.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import 'common.dart';

/// 대기열 패널.
///
/// 인코딩이 도는 동안에도 화면을 빼앗지 않아, 그 사이에 다음 묶음을 준비해
/// 대기열에 넣을 수 있다. 진행 상황은 여기서 계속 보인다.
class QueuePanel extends StatelessWidget {
  final AppState state;

  const QueuePanel({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    if (state.queue.isEmpty) return const SizedBox.shrink();

    final running = state.runningJob;
    final paused = running != null && state.isPaused;
    final waiting = state.waitingCount;
    final doneCount =
        state.queue.where((j) => j.status == QueuedStatus.done).length;

    return Container(
      width: double.infinity,
      margin: EdgeInsets.only(bottom: d.gap),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(d.radius),
        border: Border.all(
          color: running != null ? AppColors.primary : AppColors.border,
          width: running != null ? 2 : 1,
        ),
      ),
      padding: EdgeInsets.all(d.sectionPad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                paused
                    ? Icons.pause_circle_outline
                    : (running != null
                        ? Icons.autorenew
                        : Icons.playlist_add_check),
                size: d.px(30),
                color: paused
                    ? AppColors.warning
                    : (running != null
                        ? AppColors.primary
                        : AppColors.textSub),
              ),
              SizedBox(width: d.px(12)),
              Text(
                '작업 대기열',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              SizedBox(width: d.px(12)),
              Text(
                paused
                    ? '일시정지됨 · 대기 $waiting개'
                    : (running != null
                        ? '만드는 중 · 대기 $waiting개'
                        : (waiting > 0 ? '대기 $waiting개' : '모두 끝났습니다')),
                style: TextStyle(
                    fontSize: d.px(17),
                    fontWeight: paused ? FontWeight.w700 : FontWeight.w400,
                    color: paused ? AppColors.warning : AppColors.textSub),
              ),
              const Spacer(),
              if (doneCount > 0 || state.queue.any((j) => j.isFinished))
                OutlineButton(
                  label: '끝난 작업 지우기',
                  icon: Icons.clear_all,
                  onPressed: state.clearFinished,
                ),
            ],
          ),

          // 전체 진행률 — 창을 최소화해 두어도 어디까지 왔는지 알 수 있게
          if (running != null) ...[
            SizedBox(height: d.gap),
            Stack(
              children: [
                Container(
                  height: d.px(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE3E8ED),
                    borderRadius: BorderRadius.circular(d.px(7)),
                  ),
                ),
                LayoutBuilder(builder: (context, c) {
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    height: d.px(14),
                    width: c.maxWidth * state.queueProgress.clamp(0.0, 1.0),
                    decoration: BoxDecoration(
                      color: paused ? AppColors.warning : AppColors.primary,
                      borderRadius: BorderRadius.circular(d.px(7)),
                    ),
                  );
                }),
              ],
            ),
            SizedBox(height: d.px(6)),
            Text(
              '남은 작업 전체 ${(state.queueProgress * 100).toStringAsFixed(0)}%',
              style: TextStyle(fontSize: d.px(15), color: AppColors.textSub),
            ),
          ],

          SizedBox(height: d.gap),
          for (final job in state.queue) ...[
            _JobRow(state: state, job: job),
            SizedBox(height: d.px(8)),
          ],
        ],
      ),
    );
  }
}

/// 차례를 바꾸는 작은 화살표. 더 갈 데가 없으면 흐리게 꺼진다.
class _OrderArrow extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  const _OrderArrow({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    return IconButton(
      icon: Icon(icon, size: d.px(24)),
      tooltip: tooltip,
      color: AppColors.textSub,
      disabledColor: AppColors.border,
      constraints: BoxConstraints(minWidth: d.px(44), minHeight: d.px(44)),
      onPressed: onPressed,
    );
  }
}

class _JobRow extends StatelessWidget {
  final AppState state;
  final QueuedJob job;

  const _JobRow({required this.state, required this.job});

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);

    final (Color color, Color bg, IconData icon) = switch (job.status) {
      QueuedStatus.waiting => (AppColors.textSub, const Color(0xFFF5F7F9), Icons.schedule),
      QueuedStatus.running => (AppColors.primary, AppColors.primaryLight, Icons.autorenew),
      QueuedStatus.done => (AppColors.success, AppColors.successLight, Icons.check_circle),
      QueuedStatus.failed => (AppColors.danger, AppColors.dangerLight, Icons.error_outline),
      QueuedStatus.skipped => (AppColors.warning, AppColors.warningLight, Icons.pause_circle_outline),
    };

    final waiting = job.status == QueuedStatus.waiting;

    final card = Container(
      padding: EdgeInsets.all(d.px(14)),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(d.px(10)),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: d.px(26)),
              SizedBox(width: d.px(12)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      job.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: d.px(18), fontWeight: FontWeight.w700),
                    ),
                    SizedBox(height: d.px(3)),
                    Text(
                      job.summaryLine,
                      style: TextStyle(
                          fontSize: d.px(15), color: AppColors.textSub),
                    ),
                  ],
                ),
              ),
              SizedBox(width: d.px(12)),
              _statusArea(context, color),
              SizedBox(width: d.px(12)),
              ..._actions(context),
            ],
          ),
          if (job.status == QueuedStatus.running) ...[
            SizedBox(height: d.px(10)),
            Stack(
              children: [
                Container(
                  height: d.px(10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(d.px(5)),
                  ),
                ),
                LayoutBuilder(builder: (context, c) {
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    height: d.px(10),
                    width: c.maxWidth * job.progress.clamp(0.0, 1.0),
                    decoration: BoxDecoration(
                      color:
                          state.isPaused ? AppColors.warning : AppColors.primary,
                      borderRadius: BorderRadius.circular(d.px(5)),
                    ),
                  );
                }),
              ],
            ),
          ],
          if (job.status == QueuedStatus.failed) ...[
            if (job.errorMessage != null) ...[
              SizedBox(height: d.px(8)),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  job.errorMessage!,
                  style: TextStyle(fontSize: d.px(15), color: AppColors.danger),
                ),
              ),
            ],
            // [문제 보고] 를 눌러 폴더가 열려도 무엇을 하라는 건지 모를 수 있다.
            // 무엇을 해야 하는지 한 줄로 적어 둔다.
            SizedBox(height: d.px(6)),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '[문제 보고]를 누르면 기록 폴더가 열립니다. '
                '그 안의 가장 최근 파일을 만든 사람에게 전해 주세요.',
                style: TextStyle(fontSize: d.px(14), color: AppColors.textSub),
              ),
            ),
          ],
        ],
      ),
    );

    if (!waiting) return card;

    // 줄 전체를 눌러도 고칠 수 있다. [수정] 버튼은 눌러도 된다는 걸 눈에 보이게 남겨 둔다.
    return InkWell(
      onTap: () => _edit(context),
      borderRadius: BorderRadius.circular(d.px(10)),
      child: card,
    );
  }

  /// 아직 순서를 기다리는 작업을 편집기로 되돌린다.
  ///
  /// 설정 화면을 따로 만들지 않고 원래 편집기를 그대로 쓴다.
  /// 목록·순서·회전·화질이 전부 살아나므로 평소처럼 고치면 된다.
  Future<void> _edit(BuildContext context) async {
    final d = Dim.of(context);

    // 편집기에 이미 올려둔 영상이 있으면 그게 밀려난다. 말없이 지우면 안 된다.
    if (state.clips.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  color: AppColors.warning, size: d.px(30)),
              SizedBox(width: d.px(10)),
              Flexible(
                child: Text('지금 올려둔 목록이 내려갑니다',
                    style: TextStyle(
                        fontSize: d.px(22), fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          content: SizedBox(
            width: d.px(560),
            child: Text(
              '아래에 올려둔 영상 ${state.clips.length}개가 목록에서 내려가고, '
              '그 자리에 "${job.title}" 의 영상들이 올라옵니다.\n'
              '영상 파일이 지워지는 것은 아닙니다.',
              style: TextStyle(fontSize: d.px(17)),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('그만두기', style: TextStyle(fontSize: d.px(17))),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('바꾸기',
                  style:
                      TextStyle(fontSize: d.px(17), color: AppColors.danger)),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    if (!context.mounted) return;
    final err = state.editQueued(job.id);
    if (!context.mounted) return;

    // 작업이 대기열에서 사라지므로, 지워진 게 아니라 아래로 내려왔다는 것과
    // 다시 올리려면 무엇을 눌러야 하는지를 알려 준다.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          err ?? '대기열에서 꺼냈습니다. 아래에서 고친 뒤 [영상 합치기]를 다시 눌러 주세요.',
          style: TextStyle(fontSize: d.px(17)),
        ),
        backgroundColor: err != null ? AppColors.danger : AppColors.primary,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  Widget _statusArea(BuildContext context, Color color) {
    final d = Dim.of(context);

    switch (job.status) {
      case QueuedStatus.running:
        // 멈춰 있는 동안 남은 시간은 의미가 없다. 계속 보여주면
        // 시간이 흐르는데 숫자가 안 줄어드는 것처럼 보인다.
        final paused = state.isPaused;
        final pct = '${(job.progress * 100).toStringAsFixed(1)}%';
        return SizedBox(
          width: d.px(300),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                paused
                    ? '일시정지됨  ·  $pct'
                    : '$pct'
                        '${job.remaining != null ? "  ·  남은 시간 ${_remain(job.remaining!)}" : ""}',
                style: TextStyle(
                    fontSize: d.px(17),
                    fontWeight: FontWeight.w700,
                    color: paused ? AppColors.warning : color),
              ),
              SizedBox(height: d.px(2)),
              Text(
                paused
                    ? '[계속하기]를 누르면 멈춘 자리에서 이어집니다'
                    : (job.fileCount > 0
                        ? '${job.stageLabel} · ${job.fileIndex}/${job.fileCount} ${job.currentFile}'
                        : job.stageLabel),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: d.px(14), color: AppColors.textSub),
              ),
            ],
          ),
        );
      case QueuedStatus.done:
        return Text(
          job.actualBytes != null ? formatBytes(job.actualBytes!) : '완료',
          style: TextStyle(
              fontSize: d.px(17), fontWeight: FontWeight.w700, color: color),
        );
      default:
        return Text(
          job.status.label,
          style: TextStyle(
              fontSize: d.px(16), fontWeight: FontWeight.w600, color: color),
        );
    }
  }

  List<Widget> _actions(BuildContext context) {
    final d = Dim.of(context);

    switch (job.status) {
      case QueuedStatus.waiting:
        return [
          // 급한 묶음을 앞세울 수 있게 차례를 바꾼다. 기다리는 작업이
          // 하나뿐이면 바꿀 상대가 없으므로 화살표를 아예 그리지 않는다.
          if (state.waitingCount > 1) ...[
            _OrderArrow(
              icon: Icons.arrow_upward,
              tooltip: '차례를 앞으로',
              onPressed: state.isFirstWaiting(job.id)
                  ? null
                  : () => state.moveQueued(job.id, -1),
            ),
            _OrderArrow(
              icon: Icons.arrow_downward,
              tooltip: '차례를 뒤로',
              onPressed: state.isLastWaiting(job.id)
                  ? null
                  : () => state.moveQueued(job.id, 1),
            ),
            SizedBox(width: d.px(8)),
          ],
          // 아직 순서를 기다리는 중이라면 언제든 고칠 수 있어야 한다.
          OutlineButton(
            label: '수정',
            icon: Icons.edit_outlined,
            onPressed: () => _edit(context),
          ),
          SizedBox(width: d.px(8)),
          OutlineButton(
            label: '빼기',
            icon: Icons.close,
            color: AppColors.danger,
            onPressed: () => state.removeQueued(job.id),
          ),
        ];
      case QueuedStatus.running:
        final paused = state.isPaused;
        return [
          // 일시정지는 중간 결과를 그대로 두고 그 자리에서 멈춘다.
          // [중지]와 달리 다시 누르면 이어서 계속된다.
          OutlineButton(
            label: paused ? '계속하기' : '일시정지',
            icon: paused ? Icons.play_arrow : Icons.pause,
            color: paused ? AppColors.success : null,
            onPressed: paused ? state.resumeRunning : state.pauseRunning,
          ),
          SizedBox(width: d.px(8)),
          OutlineButton(
            label: '중지',
            icon: Icons.stop_circle_outlined,
            color: AppColors.danger,
            onPressed: state.cancelRunning,
          ),
        ];
      case QueuedStatus.done:
        return [
          OutlineButton(
            label: '재생',
            icon: Icons.play_circle_outline,
            onPressed: () => state.playResultOf(job),
          ),
          SizedBox(width: d.px(8)),
          OutlineButton(
            label: '폴더',
            icon: Icons.folder_open,
            onPressed: () => state.openFolderOf(job),
          ),
        ];
      case QueuedStatus.failed:
      case QueuedStatus.skipped:
        return [
          OutlineButton(
            label: '다시 시도',
            icon: Icons.refresh,
            onPressed: () => state.retryJob(job.id),
          ),
          SizedBox(width: d.px(8)),
          // 같은 설정으로 다시 해 봐야 또 실패할 수 있다.
          // 설정을 바꿔서 다시 걸 수 있게 편집기로 되돌리는 길을 둔다.
          OutlineButton(
            label: '수정',
            icon: Icons.edit_outlined,
            onPressed: () => _edit(context),
          ),
          SizedBox(width: d.px(8)),
          OutlineButton(
            label: '문제 보고',
            icon: Icons.bug_report_outlined,
            onPressed: state.openLogFolder,
          ),
        ];
    }
  }

  static String _remain(Duration dur) {
    if (dur.inSeconds < 60) return '${dur.inSeconds}초';
    if (dur.inMinutes < 60) return '${dur.inMinutes}분';
    return '${dur.inHours}시간 ${dur.inMinutes % 60}분';
  }
}
