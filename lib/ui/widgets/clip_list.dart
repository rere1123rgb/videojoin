import 'dart:io';

import 'package:flutter/material.dart';

import '../../engine/models.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import 'clip_editor.dart';
import 'common.dart';

/// 영상 목록.
///
/// 순서 변경의 주 수단은 큼직한 ▲▼ 버튼이다. 드래그도 되게 해두었지만
/// 어디까지나 보조다 — 드래그는 손떨림에 취약하고, 무엇보다 "끌어서
/// 옮길 수 있다"는 걸 알아채지 못하는 경우가 많다.
class ClipList extends StatelessWidget {
  final AppState state;

  const ClipList({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final clips = state.clips;

    return Column(
      children: [
        Wrap(
          spacing: d.px(10),
          runSpacing: d.px(10),
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '순서 바꾸기: ',
              style: TextStyle(fontSize: d.px(16), color: AppColors.textSub),
            ),
            OutlineButton(
              label: '이름순',
              icon: Icons.sort_by_alpha,
              onPressed: () => _sortByName(context, state),
            ),
            OutlineButton(
              label: '만든 날짜순',
              icon: Icons.photo_camera_outlined,
              onPressed: () => state.sortBy(SortMode.createdDate),
            ),
            OutlineButton(
              label: '수정한 날짜순',
              icon: Icons.edit_calendar_outlined,
              onPressed: () => state.sortBy(SortMode.modifiedDate),
            ),
            OutlineButton(
              label: '거꾸로',
              icon: Icons.swap_vert,
              onPressed: () => state.reverseOrder(),
            ),
          ],
        ),
        SizedBox(height: d.px(10)),

        // 조작 방법 안내. 툴팁은 마우스를 올려야 보이고 "처음 몇 번만" 안내는
        // 다시 나오지 않으므로 **항상 보이는 한 줄**로 둔다.
        Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(
            horizontal: d.px(14),
            vertical: d.px(10),
          ),
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(d.px(8)),
          ),
          child: Row(
            children: [
              Icon(
                Icons.info_outline,
                size: d.px(19),
                color: AppColors.textFaint,
              ),
              SizedBox(width: d.px(8)),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    style: TextStyle(
                      fontSize: d.px(15),
                      color: AppColors.textSub,
                    ),
                    children: [
                      const TextSpan(text: '순서를 바꾸려면  '),
                      TextSpan(
                        text: '▲▼',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppColors.text,
                        ),
                      ),
                      const TextSpan(text: ' 를 누르세요. 꾹 누르면 맨 끝으로 갑니다.  ·  '),
                      TextSpan(
                        text: '⣿',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppColors.text,
                        ),
                      ),
                      const TextSpan(text: ' 를 잡고 끌어도 됩니다.'),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: d.px(12)),

        ReorderableListView.builder(
          key: const ValueKey('clip-reorder-list'),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: clips.length,
          // onReorderItem 은 뺀 자리를 이미 반영한 newIndex 를 준다(옛 onReorder 처럼
          // 1 을 빼면 한 칸씩 어긋난다).
          onReorderItem: (oldIndex, newIndex) =>
              state.moveClip(oldIndex, newIndex),
          itemBuilder: (context, i) => Padding(
            key: ValueKey(clips[i].id),
            padding: EdgeInsets.only(bottom: d.px(10)),
            child: _ClipTile(
              state: state,
              clip: clips[i],
              index: i,
              total: clips.length,
            ),
          ),
        ),
      ],
    );
  }
}

/// 이름순 정렬.
///
/// 카메라가 만든 파일명 중에는 숫자의 뒷자리가 실제 상위 키인 경우가 있다
/// (E-10463, E-20463, E-30463, E-10464 ...). 이때는 평범한 정렬과 결과가
/// 달라지므로 두 순서를 나란히 보여주고 고르게 한다.
///
/// 결과가 같으면 물어볼 이유가 없으므로 그냥 정렬한다.
Future<void> _sortByName(BuildContext context, AppState state) async {
  final preview = state.nameSortPreview();
  if (preview == null) {
    state.sortBy(SortMode.name);
    return;
  }

  final d = Dim.of(context);
  final smart = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(
        '어느 순서가 맞습니까?',
        style: TextStyle(fontSize: d.px(22), fontWeight: FontWeight.w700),
      ),
      content: SizedBox(
        width: d.px(560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '이 영상들의 파일 이름은 두 가지로 읽을 수 있습니다.\n'
              '앞부분을 보고 고르세요.',
              style: TextStyle(fontSize: d.px(16), color: AppColors.textSub),
            ),
            SizedBox(height: d.px(16)),
            _OrderChoice(
              title: '이름 그대로',
              names: preview.plain,
              onTap: () => Navigator.pop(ctx, false),
            ),
            SizedBox(height: d.px(10)),
            _OrderChoice(
              title: '날짜별로 묶기',
              names: preview.smart,
              onTap: () => Navigator.pop(ctx, true),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, null),
          child: Text('그만두기', style: TextStyle(fontSize: d.px(17))),
        ),
      ],
    ),
  );

  if (smart == null) return;
  state.sortBy(smart ? SortMode.nameSmart : SortMode.name);
}

/// 정렬 후보 한 개. 앞쪽 파일명 몇 개를 보여줘서 눈으로 판단하게 한다.
class _OrderChoice extends StatelessWidget {
  final String title;
  final List<String> names;
  final VoidCallback onTap;

  const _OrderChoice({
    required this.title,
    required this.names,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final shown = names.take(6).join(',  ');

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(d.px(10)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(d.px(10)),
        child: Container(
          padding: EdgeInsets.all(d.px(14)),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(d.px(10)),
            border: Border.all(color: AppColors.borderStrong, width: 1.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: d.px(18),
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: d.px(6)),
              Text(
                names.length > 6 ? '$shown,  …' : shown,
                style: TextStyle(fontSize: d.px(15), color: AppColors.textSub),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ClipTile extends StatelessWidget {
  final AppState state;
  final ClipItem clip;
  final int index;
  final int total;

  const _ClipTile({
    required this.state,
    required this.clip,
    required this.index,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final spec = clip.spec;
    final failed = !spec.ok;

    return Container(
      decoration: BoxDecoration(
        color: failed ? AppColors.dangerLight : AppColors.surface,
        borderRadius: BorderRadius.circular(d.radius),
        border: Border.all(
          color: failed
              ? AppColors.danger.withValues(alpha: 0.5)
              : AppColors.border,
        ),
      ),
      padding: EdgeInsets.all(d.px(12)),
      // 글씨를 크게 키운 좁은 창에서는 [손보기] 글자를 빼고 가위 아이콘만 둔다.
      child: LayoutBuilder(
        builder: (context, box) {
          final compact = box.maxWidth < d.px(640);
          return Row(
            children: [
              SizedBox(
                width: d.px(34),
                child: Text(
                  '${index + 1}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: d.px(21),
                    fontWeight: FontWeight.w700,
                    color: AppColors.textSub,
                  ),
                ),
              ),
              SizedBox(width: d.px(8)),

              // 썸네일 (사용자 회전을 화면에서 바로 반영). 누르면 손보기.
              MouseRegion(
                cursor: failed ? MouseCursor.defer : SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: failed
                      ? null
                      : () => showClipEditor(context, state, clip),
                  child: Tooltip(
                    message: failed ? '' : '눌러서 손보기 (자르기·소리·밝기)',
                    child: _Thumbnail(clip: clip),
                  ),
                ),
              ),
              SizedBox(width: d.px(14)),

              Expanded(child: _ClipInfo(clip: clip)),

              // 손보기(자르기·소리·밝기). 회전보다 앞에 둔다 — 가장 자주 쓴다.
              if (!failed) ...[
                _EditButton(
                  compact: compact,
                  edited: !clip.edit.isDefault,
                  onTap: () => showClipEditor(context, state, clip),
                ),
                SizedBox(width: d.px(8)),
              ],

              if (!failed) ...[
                _IconAction(
                  icon: Icons.rotate_90_degrees_ccw,
                  tooltip: '왼쪽으로 90도 회전',
                  onTap: () => state.rotateClip(clip.id, -90),
                ),
                SizedBox(width: d.px(4)),
                _IconAction(
                  icon: Icons.rotate_90_degrees_cw,
                  tooltip: '오른쪽으로 90도 회전',
                  onTap: () => state.rotateClip(clip.id, 90),
                ),
                SizedBox(width: d.px(12)),
              ],

              // 순서 이동 — 이게 주 수단이다.
              // 길게 누르면 맨 끝까지 한 번에 간다.
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _IconAction(
                    icon: Icons.keyboard_arrow_up,
                    tooltip: '위로 (꾹 누르면 맨 위로)',
                    big: true,
                    onTap: index == 0
                        ? null
                        : () => state.moveClip(index, index - 1),
                    onLongPress: index == 0
                        ? null
                        : () => state.moveClip(index, 0),
                  ),
                  SizedBox(height: d.px(4)),
                  _IconAction(
                    icon: Icons.keyboard_arrow_down,
                    tooltip: '아래로 (꾹 누르면 맨 아래로)',
                    big: true,
                    onTap: index == total - 1
                        ? null
                        : () => state.moveClip(index, index + 1),
                    onLongPress: index == total - 1
                        ? null
                        : () => state.moveClip(index, total - 1),
                  ),
                ],
              ),
              SizedBox(width: d.px(10)),

              _IconAction(
                icon: Icons.close,
                tooltip: '목록에서 빼기',
                color: AppColors.danger,
                onTap: () => state.removeClip(clip.id),
              ),

              // 드래그 손잡이.
              // 아이콘만으로는 잡을 수 있는지 알기 어려워 배경과 '순서' 라벨을 붙인다.
              SizedBox(width: d.px(8)),
              ReorderableDragStartListener(
                index: index,
                child: MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: Tooltip(
                    message: '잡고 끌어서 순서 바꾸기',
                    child: Container(
                      width: d.px(46),
                      height: d.px(52),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEDF1F5),
                        borderRadius: BorderRadius.circular(d.px(8)),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.drag_indicator,
                            color: AppColors.textSub,
                            size: d.px(22),
                          ),
                          SizedBox(height: d.px(1)),
                          Text(
                            '순서',
                            style: TextStyle(
                              fontSize: d.px(11),
                              color: AppColors.textSub,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  final ClipItem clip;

  const _Thumbnail({required this.clip});

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final w = d.px(112);
    final h = d.px(64);

    Widget inner;
    final path = clip.thumbnailPath;
    if (!clip.spec.ok) {
      inner = Icon(
        Icons.broken_image_outlined,
        color: AppColors.danger,
        size: d.px(28),
      );
    } else if (path != null && File(path).existsSync()) {
      // 사용자 회전은 이미지를 화면에서 돌려서 보여준다.
      // 회전 버튼을 누를 때마다 썸네일을 다시 뽑을 이유가 없다.
      inner = Transform.rotate(
        angle: clip.userRotation * 3.1415926535 / 180.0,
        child: Image.file(
          File(path),
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => Icon(
            Icons.movie_outlined,
            color: AppColors.textFaint,
            size: d.px(28),
          ),
        ),
      );
    } else {
      inner = SizedBox(
        width: d.px(20),
        height: d.px(20),
        child: const CircularProgressIndicator(strokeWidth: 2),
      );
    }

    return Container(
      width: w,
      height: h,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFF11151A),
        borderRadius: BorderRadius.circular(d.px(8)),
      ),
      clipBehavior: Clip.antiAlias,
      child: inner,
    );
  }
}

class _ClipInfo extends StatelessWidget {
  final ClipItem clip;

  const _ClipInfo({required this.clip});

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final spec = clip.spec;

    if (!spec.ok) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            spec.fileName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: d.px(18), fontWeight: FontWeight.w600),
          ),
          SizedBox(height: d.px(4)),
          Text(
            spec.errorMessage ?? '읽을 수 없는 파일입니다.',
            style: TextStyle(fontSize: d.px(15), color: AppColors.danger),
          ),
        ],
      );
    }

    final tags = <Widget>[
      _Tag('${clip.finalWidth}×${clip.finalHeight}'),
      _Tag(resolutionNickname(clip.finalWidth, clip.finalHeight)),
      _Tag(spec.frameRate.label),
      if (clip.edit.isTrimmed)
        _Tag(
          '✂ ${formatDuration(clip.effectiveDuration)}만 사용 '
          '(원래 ${formatDuration(spec.durationSec)})',
          color: AppColors.primary,
        )
      else
        _Tag(formatDuration(spec.durationSec)),
      _Tag(formatBytes(spec.fileSize)),
      if (spec.isHdr) _Tag(spec.hdrKind, color: AppColors.warning),
      if (!spec.hasAudio) _Tag('소리 없음', color: AppColors.warning),
      if (clip.finalIsPortrait) _Tag('세로', color: AppColors.primary),
      if (clip.userRotation != 0)
        _Tag('${clip.userRotation}° 회전', color: AppColors.primary),
      if (clip.edit.volume != VolumeLevel.normal)
        _Tag('소리: ${clip.edit.volume.label}', color: AppColors.primary),
      if (clip.edit.brightness != BrightnessLevel.normal)
        _Tag('밝기: ${clip.edit.brightness.label}', color: AppColors.primary),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          spec.fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: d.px(18), fontWeight: FontWeight.w600),
        ),
        SizedBox(height: d.px(6)),
        Wrap(spacing: d.px(6), runSpacing: d.px(5), children: tags),
      ],
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final Color? color;

  const _Tag(this.text, {this.color});

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final c = color ?? AppColors.textSub;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: d.px(8), vertical: d.px(2)),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(d.px(5)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: d.px(14),
          color: c,
          fontWeight: color != null ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Color? color;
  final bool big;

  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.onLongPress,
    this.color,
    this.big = false,
  });

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final enabled = onTap != null;
    final size = big ? d.px(38) : d.px(44);

    return Tooltip(
      message: tooltip,
      child: Material(
        color: enabled ? const Color(0xFFEDF1F5) : const Color(0xFFF6F8FA),
        borderRadius: BorderRadius.circular(d.px(8)),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(d.px(8)),
          child: SizedBox(
            width: big ? d.px(52) : size,
            height: size,
            child: Icon(
              icon,
              size: d.px(24),
              color: enabled ? (color ?? AppColors.text) : AppColors.textFaint,
            ),
          ),
        ),
      ),
    );
  }
}

/// 목록 줄의 [손보기] 버튼. 손본 영상은 색을 채워서 한눈에 구분된다.
class _EditButton extends StatelessWidget {
  final bool edited;
  final bool compact;
  final VoidCallback onTap;

  const _EditButton({
    required this.edited,
    required this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final fg = edited ? Colors.white : AppColors.primary;
    return Tooltip(
      message: edited ? '손본 영상 · 다시 손보기' : '자르기 · 소리 · 밝기',
      child: Material(
        color: edited ? AppColors.primary : AppColors.primaryLight,
        borderRadius: BorderRadius.circular(d.px(8)),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(d.px(8)),
          child: Container(
            height: d.px(44),
            padding: EdgeInsets.symmetric(horizontal: d.px(12)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.content_cut, size: d.px(20), color: fg),
                if (!compact) ...[
                  SizedBox(width: d.px(6)),
                  Text(
                    edited ? '다시 손보기' : '손보기',
                    style: TextStyle(
                      fontSize: d.px(16),
                      fontWeight: FontWeight.w700,
                      color: fg,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
