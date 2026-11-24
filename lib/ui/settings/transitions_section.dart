part of 'settings_panel.dart';

/// 영상 사이 부드럽게 넘기기. 켜면 같은 카드 안에 효과·길이 선택이 나온다.
class SmoothTransitionCard extends StatelessWidget {
  final AppState state;
  final bool losslessPossibleWithout;

  const SmoothTransitionCard(
      {super.key, required this.state, required this.losslessPossibleWithout});

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final on = state.smoothTransitions;
    final style = state.transitionStyle;
    return Material(
      color: on ? AppColors.primaryLight : AppColors.surface,
      borderRadius: BorderRadius.circular(d.radius),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(d.radius),
          border: Border.all(
              color: on ? AppColors.primary : AppColors.border, width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CheckRow(
              on: on,
              title: '영상 사이를 부드럽게 넘기기',
              note: '영상이 바뀌는 곳마다 고른 효과로 넘어갑니다.'
                  '${losslessPossibleWithout ? (on ? ' 끄면 그대로 이어붙이기를 다시 고를 수 있습니다.' : ' 켜면 다시 만들기로 바뀝니다.') : ''}',
              onTap: () => state.setSmoothTransitions(!on),
            ),
            if (on)
              Padding(
                padding: EdgeInsets.fromLTRB(d.px(14), 0, d.px(14), d.px(12)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('효과',
                        style: TextStyle(
                            fontSize: d.px(16),
                            fontWeight: FontWeight.w700,
                            color: AppColors.textSub)),
                    SizedBox(height: d.px(8)),
                    _StyleGrid(
                      selected: style,
                      onSelect: state.setTransitionStyle,
                      // 거치기는 어두워지기+밝아지기, 겹치기는 그 두 배를 겹치므로
                      // 눈에 보이는 길이는 어느 효과든 한쪽 길이의 두 배다.
                      transitionSeconds: state.transitionLength.seconds * 2,
                    ),
                    SizedBox(height: d.px(12)),
                    _PillRow<TransitionLength>(
                      label: '길이',
                      values: TransitionLength.values,
                      selected: state.transitionLength,
                      text: (v) => v.label,
                      onSelect: state.setTransitionLength,
                    ),
                    if (style.isOverlap) ...[
                      SizedBox(height: d.px(10)),
                      Text('영상이 겹치는 만큼 전체 길이가 조금 짧아집니다.',
                          style: TextStyle(
                              fontSize: d.px(15), color: AppColors.textSub)),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 효과 8가지를 고르는 목록. 넓으면 2열, 좁으면 1열.
class _StyleGrid extends StatelessWidget {
  final TransitionStyle selected;
  final void Function(TransitionStyle) onSelect;
  final double transitionSeconds;

  const _StyleGrid(
      {required this.selected,
      required this.onSelect,
      required this.transitionSeconds});

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    return LayoutBuilder(builder: (context, c) {
      // 한 칸이 글자 배율에 비례해 너무 좁아지지 않을 때만 2열로 나눈다.
      final cols = c.maxWidth >= d.px(560) ? 2 : 1;
      final gap = d.px(8);
      final items = TransitionStyle.values;
      // 맛보기 화면 폭. 칸의 약 40% 이되 너무 커지지 않게.
      final tileW = (c.maxWidth - gap * (cols - 1)) / cols;
      // 칸이 좁으면(글씨를 크게 키운 경우) 맛보기를 위에, 글씨를 아래에 둔다.
      // 옆에 두면 글씨 칸이 한두 글자 폭으로 줄어 읽을 수가 없다.
      final vertical = tileW < d.px(420);
      final previewW = vertical
          ? (tileW - d.px(22)).clamp(d.px(96), d.px(320)).toDouble()
          : (tileW * 0.40).clamp(d.px(96), d.px(170)).toDouble();
      return Column(
        children: [
          for (var i = 0; i < items.length; i += cols) ...[
            if (i > 0) SizedBox(height: gap),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var k = 0; k < cols; k++) ...[
                    if (k > 0) SizedBox(width: gap),
                    Expanded(
                      child: i + k < items.length
                          ? _StyleTile(
                              previewWidth: previewW,
                              transitionSeconds: transitionSeconds,
                              vertical: vertical,
                              style: items[i + k],
                              selected: items[i + k] == selected,
                              onTap: () => onSelect(items[i + k]),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      );
    });
  }
}

/// 효과 한 칸: 왼쪽에 움직이는 맛보기, 오른쪽에 이름과 설명.
/// 고른 칸과 마우스를 올린 칸만 움직인다(여덟 개가 한꺼번에 움직이면 어지럽다).
class _StyleTile extends StatefulWidget {
  final TransitionStyle style;
  final bool selected;
  final double previewWidth;
  final double transitionSeconds;
  final bool vertical;
  final VoidCallback onTap;

  const _StyleTile({
    required this.style,
    required this.selected,
    required this.previewWidth,
    required this.transitionSeconds,
    required this.onTap,
    this.vertical = false,
  });

  @override
  State<_StyleTile> createState() => _StyleTileState();
}

class _StyleTileState extends State<_StyleTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final selected = widget.selected;
    final style = widget.style;
    final preview = TransitionPreview(
      asset: style.name,
      animate: selected || _hover,
      width: widget.previewWidth,
      transitionSeconds: widget.transitionSeconds,
    );
    final texts = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(style.label,
            style: TextStyle(
                fontSize: d.px(17),
                fontWeight: FontWeight.w700,
                color: selected ? Colors.white : AppColors.text)),
        SizedBox(height: d.px(3)),
        Text(style.description,
            style: TextStyle(
                fontSize: d.px(15),
                color: selected ? Colors.white : AppColors.textSub)),
      ],
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Material(
        color: selected ? AppColors.primary : AppColors.surface,
        borderRadius: BorderRadius.circular(d.radius),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(d.radius),
          child: Container(
            constraints: BoxConstraints(minHeight: d.tapMin),
            padding: EdgeInsets.all(d.px(10)),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(d.radius),
              border: Border.all(
                  color: selected ? AppColors.primary : AppColors.border,
                  width: 1.5),
            ),
            child: widget.vertical
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      preview,
                      SizedBox(height: d.px(8)),
                      texts,
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      preview,
                      SizedBox(width: d.px(12)),
                      Expanded(child: texts),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// 맨 처음과 맨 끝도 서서히. 영상 사이 넘기기와 따로 켜고 끈다.
class FadeEndsToggle extends StatelessWidget {
  final AppState state;
  final bool losslessPossibleWithout;

  const FadeEndsToggle(
      {super.key, required this.state, required this.losslessPossibleWithout});

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final on = state.fadeEnds;
    return Material(
      color: on ? AppColors.primaryLight : AppColors.surface,
      borderRadius: BorderRadius.circular(d.radius),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(d.radius),
          border: Border.all(
              color: on ? AppColors.primary : AppColors.border, width: 1.5),
        ),
        child: _CheckRow(
          on: on,
          title: '맨 처음과 맨 끝도 서서히',
          note: '영상이 서서히 나타나며 시작하고, 서서히 사라지며 끝납니다.'
              '${losslessPossibleWithout ? (on ? ' 끄면 그대로 이어붙이기를 다시 고를 수 있습니다.' : ' 켜면 다시 만들기로 바뀝니다.') : ''}',
          onTap: () => state.setFadeEnds(!on),
        ),
      ),
    );
  }
}
