import 'package:flutter/material.dart';

import '../../../engine/models.dart';
import '../../format.dart';
import '../../theme.dart';
import '../editor_controller.dart';
import 'editor_buttons.dart';

/// 이동 줄: ◀ 5초 … [재생] … 5초 ▶
class EditorTransportRow extends StatelessWidget {
  final ClipEditorController c;

  const EditorTransportRow(this.c, {super.key});

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    Widget step(String label, double delta) => SmallButton(
      label: label,
      onTap: () => c.seek(c.pos + delta, immediate: true),
    );

    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: d.px(6),
      runSpacing: d.px(6),
      children: [
        step('◀ 5초', -5),
        step('◀ 1초', -1),
        step('◀ 0.1초', -0.1),
        SizedBox(width: d.px(4)),
        Tooltip(
          message: '스페이스 바',
          child: SizedBox(
            width: d.px(170),
            child: PlayButton(playing: c.playing, onTap: c.togglePlay),
          ),
        ),
        SizedBox(width: d.px(4)),
        step('0.1초 ▶', 0.1),
        step('1초 ▶', 1),
        step('5초 ▶', 5),
      ],
    );
  }
}

/// 자르기 줄. 두 묶음으로 읽히게 나눈다.
///  - 왼쪽: 지금 자리를 기준으로 앞/뒤를 통째로 버리는 큰 동작
///  - 오른쪽: 가운데 구간을 골라 빼는 동작(시작/끝 찍기 → 빼기 → 되돌리기)
/// 글씨가 커지면 묶음 안에서도, 묶음끼리도 줄바꿈된다.
class EditorCutRow extends StatelessWidget {
  final ClipEditorController c;

  const EditorCutRow(this.c, {super.key});

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final sel = c.sel;
    var selHasKept = false;
    var selHasRemoved = false;
    if (sel != null) {
      for (final p in c.pieces.pieces) {
        final overlap =
            (p.end < sel.hi ? p.end : sel.hi) -
            (p.start > sel.lo ? p.start : sel.lo);
        if (overlap > 0.05) {
          if (p.keep) {
            selHasKept = true;
          } else {
            selHasRemoved = true;
          }
        }
      }
    }
    final onlyRemoved = sel != null && selHasRemoved && !selHasKept;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: d.px(16),
          runSpacing: d.px(8),
          children: [
            Wrap(
              spacing: d.px(10),
              runSpacing: d.px(8),
              children: [
                ActionButton(
                  icon: Icons.first_page,
                  label: '여기부터 쓰기',
                  onTap: c.startHere,
                ),
                ActionButton(
                  icon: Icons.last_page,
                  label: '여기까지만 쓰기',
                  onTap: c.endHere,
                ),
              ],
            ),
            // 구간을 지금 자리로 정확히 고르는 묶음. 옅은 바탕으로 한 덩어리로 보인다.
            Container(
              padding: EdgeInsets.all(d.px(8)),
              decoration: BoxDecoration(
                color: const Color(0xFFF4F6F9),
                borderRadius: BorderRadius.circular(d.px(14)),
              ),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: d.px(8),
                runSpacing: d.px(8),
                children: [
                  Tooltip(
                    message: '지금 자리를 고를 구간의 시작으로 (I 키)',
                    child: SmallButton(label: '여기를 구간 시작으로', onTap: c.markIn),
                  ),
                  Tooltip(
                    message: '지금 자리를 고를 구간의 끝으로 (O 키)',
                    child: SmallButton(label: '여기를 구간 끝으로', onTap: c.markOut),
                  ),
                  if (onlyRemoved)
                    ActionButton(
                      icon: Icons.add_circle_outline,
                      label: '고른 구간 다시 넣기',
                      color: AppColors.success,
                      onTap: () => c.applySelection(true),
                    )
                  else
                    ActionButton(
                      icon: Icons.content_cut,
                      label: sel == null
                          ? '고른 구간 빼기'
                          : '고른 구간 빼기 (${formatClock(sel.hi - sel.lo)})',
                      color: AppColors.danger,
                      enabled: sel != null,
                      onTap: () => c.applySelection(false),
                    ),
                  ActionButton(
                    icon: Icons.crop,
                    label: '고른 구간만 쓰기',
                    color: AppColors.primary,
                    enabled: sel != null && !onlyRemoved,
                    onTap: c.keepOnlySelection,
                  ),
                  Tooltip(
                    message: '방금 한 것을 취소 (Ctrl+Z)',
                    child: ActionButton(
                      icon: Icons.undo,
                      label: '되돌리기',
                      color: AppColors.text,
                      enabled: c.canUndo,
                      onTap: c.undo,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        SizedBox(height: d.px(6)),
        _SelectionLine(c),
      ],
    );
  }
}

/// 고르는 중인 구간의 상태를 한 줄로 늘 보여 준다(잠깐 뜨는 안내만으로는 놓친다).
class _SelectionLine extends StatelessWidget {
  final ClipEditorController c;

  const _SelectionLine(this.c);

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final sel = c.sel;
    final a = c.selA;
    final marking = sel == null && a != null && c.selB == null;
    final String text;
    if (sel != null) {
      text = '고른 구간: ${formatClock(sel.lo, precise: true)} ~ '
          '${formatClock(sel.hi, precise: true)}';
    } else if (marking) {
      text = '구간 시작: ${formatClock(a, precise: true)}  →  끝낼 곳으로 옮긴 뒤 '
          '[여기를 구간 끝으로]';
    } else {
      text = '구간 고르기: 장면 띠를 끌거나 [여기를 구간 시작으로]·[여기를 구간 끝으로] '
          '→ [고른 구간 빼기] 또는 [고른 구간만 쓰기]';
    }
    final active = sel != null || marking;
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: d.px(10),
      runSpacing: d.px(4),
      children: [
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: d.px(15),
            color: active ? AppColors.text : AppColors.textSub,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        if (active)
          SmallButton(label: '고르기 취소', onTap: c.clearSelection),
      ],
    );
  }
}

/// 소리·밝기·회전 줄.
class EditorAdjustRow extends StatelessWidget {
  final ClipEditorController c;

  const EditorAdjustRow(this.c, {super.key});

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    Widget label(String t) => Padding(
      padding: EdgeInsets.only(right: d.px(8)),
      child: Text(
        t,
        style: TextStyle(fontSize: d.px(17), fontWeight: FontWeight.w700),
      ),
    );

    Widget group(List<Widget> children) => Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: d.px(6),
      runSpacing: d.px(6),
      children: children,
    );

    return Wrap(
      spacing: d.px(26),
      runSpacing: d.px(8),
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        group([
          label('소리'),
          for (final v in VolumeLevel.values)
            Pill(
              label: v.label,
              icon: v == VolumeLevel.mute ? Icons.volume_off : null,
              selected: c.volume == v,
              onTap: () => c.setVolume(v),
            ),
        ]),
        group([
          label('밝기'),
          for (final b in BrightnessLevel.values)
            Pill(
              label: b.label,
              selected: c.brightness == b,
              onTap: () => c.setBrightness(b),
            ),
        ]),
        group([
          label('회전'),
          Pill(
            label: '왼쪽',
            icon: Icons.rotate_90_degrees_ccw,
            selected: false,
            onTap: () => c.rotateBy(270),
          ),
          Pill(
            label: '오른쪽',
            icon: Icons.rotate_90_degrees_cw,
            selected: false,
            onTap: () => c.rotateBy(90),
          ),
        ]),
      ],
    );
  }
}
