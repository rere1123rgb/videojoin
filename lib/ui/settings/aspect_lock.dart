part of 'settings_panel.dart';

/// 가로·세로를 원본 비율에 묶는 토글.
///
/// 사슬이 이어졌는지(`link`) 끊겼는지(`link_off`)로 상태를 보여 준다.
/// 아이콘만으로는 무슨 기능인지 알기 어려워서 글자를 함께 둔다.
/// 켜져 있을 때는 어떤 비율로 묶였는지(`16:9`)도 같이 적어 준다.
class _AspectLock extends StatelessWidget {
  final bool on;
  final bool enabled;
  final String? ratio;
  final VoidCallback onToggle;

  const _AspectLock({
    required this.on,
    required this.enabled,
    required this.ratio,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final lit = enabled && on;
    final fg = !enabled
        ? AppColors.textFaint
        : (on ? AppColors.primaryDark : AppColors.textSub);

    return InkWell(
      onTap: enabled ? onToggle : null,
      borderRadius: BorderRadius.circular(d.px(8)),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: d.px(12), vertical: d.px(9)),
        decoration: BoxDecoration(
          color: lit ? AppColors.primaryLight : Colors.transparent,
          borderRadius: BorderRadius.circular(d.px(8)),
          border: Border.all(
            color: lit
                ? AppColors.primary.withValues(alpha: 0.45)
                : AppColors.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(on ? Icons.link : Icons.link_off, size: d.px(22), color: fg),
            SizedBox(width: d.px(7)),
            Text(
              lit && ratio != null ? '원본 비율 고정 · $ratio' : '원본 비율 고정',
              style: TextStyle(
                fontSize: d.px(16),
                fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
