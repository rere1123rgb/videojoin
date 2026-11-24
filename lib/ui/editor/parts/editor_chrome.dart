import 'package:flutter/material.dart';

import '../../format.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../editor_controller.dart';

/// 맨 윗줄: 제목 · 파일 이름 · [처음 상태로].
/// [처음 상태로] 는 자주 누르는 편집 버튼에서 멀리, 오른쪽 위에 둔다.
class EditorHeader extends StatelessWidget {
  final ClipEditorController c;
  final int position;
  final int count;
  final VoidCallback onReset;

  const EditorHeader({
    super.key,
    required this.c,
    required this.position,
    required this.count,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    return Row(
      children: [
        Icon(Icons.content_cut, color: AppColors.primary, size: d.px(26)),
        SizedBox(width: d.px(10)),
        Text(
          '영상 손보기',
          style: TextStyle(fontSize: d.px(22), fontWeight: FontWeight.w700),
        ),
        SizedBox(width: d.px(14)),
        Expanded(
          child: Text(
            count > 1
                ? '$position/$count  ${c.spec.fileName}'
                : c.spec.fileName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: d.px(17), color: AppColors.textSub),
          ),
        ),
        SizedBox(width: d.px(8)),
        Tooltip(
          message: '자른 것·소리·밝기·회전을 모두 지웁니다 (되돌리기로 살릴 수 있음)',
          child: OutlineButton(
            label: '처음 상태로',
            icon: Icons.restart_alt,
            onPressed: c.isEdited ? onReset : null,
          ),
        ),
      ],
    );
  }
}

/// 맨 아랫줄: 쓰는 길이 · [이전 영상] [다음 영상] [취소] [적용].
/// 이전/다음은 [onPrevious]/[onNext] 가 null 이면 숨긴다.
class EditorFooter extends StatelessWidget {
  final ClipEditorController c;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback onCancel;
  final VoidCallback onApply;

  const EditorFooter({
    super.key,
    required this.c,
    required this.onPrevious,
    required this.onNext,
    required this.onCancel,
    required this.onApply,
  });

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final kept = c.canTrim ? c.pieces.keptDuration : c.dur;
    final trimmed = c.canTrim && c.pieces.toKeep().isNotEmpty;
    final lengthText = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '쓰는 길이  ',
            style: TextStyle(color: AppColors.textSub),
          ),
          TextSpan(
            text: formatClock(kept),
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: trimmed ? AppColors.primary : AppColors.text,
            ),
          ),
          if (trimmed)
            TextSpan(
              text: '   (원래 ${formatClock(c.dur)})',
              style: TextStyle(color: AppColors.textFaint),
            ),
        ],
      ),
      style: TextStyle(fontSize: d.px(19)),
    );
    final buttons = Wrap(
      alignment: WrapAlignment.end,
      spacing: d.px(10),
      runSpacing: d.px(8),
      children: [
        if (onPrevious != null)
          OutlineButton(
            label: '이전 영상',
            icon: Icons.chevron_left,
            onPressed: onPrevious,
          ),
        if (onNext != null)
          OutlineButton(
            label: '다음 영상',
            icon: Icons.chevron_right,
            onPressed: onNext,
          ),
        OutlineButton(label: '취소', onPressed: onCancel),
        SizedBox(
          width: d.px(180),
          child: BigButton(label: '적용', icon: Icons.check, onPressed: onApply),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth < d.px(980)) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              lengthText,
              SizedBox(height: d.px(8)),
              Align(alignment: Alignment.centerRight, child: buttons),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: lengthText),
            buttons,
          ],
        );
      },
    );
  }
}
