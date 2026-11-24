import 'package:flutter/material.dart';

import '../theme.dart';

/// 섹션 카드. 화면이 세로로 길게 흐르는 구조라 구획이 뚜렷해야 한다.
class SectionCard extends StatelessWidget {
  final String? stepNumber;
  final String title;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets? padding;

  const SectionCard({
    super.key,
    this.stepNumber,
    required this.title,
    this.trailing,
    required this.child,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(d.radius),
        border: Border.all(color: AppColors.border),
      ),
      padding: padding ?? EdgeInsets.all(d.sectionPad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (stepNumber != null) ...[
                Container(
                  width: d.px(36),
                  height: d.px(36),
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: AppColors.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    stepNumber!,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: d.px(19),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                SizedBox(width: d.px(12)),
              ],
              Expanded(
                child: Text(title, style: Theme.of(context).textTheme.titleLarge),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          SizedBox(height: d.px(18)),
          child,
        ],
      ),
    );
  }
}

/// 큼직한 주 버튼.
class BigButton extends StatelessWidget {
  final String label;
  final String? sublabel;
  final IconData? icon;
  final VoidCallback? onPressed;
  final Color color;
  final bool expanded;

  const BigButton({
    super.key,
    required this.label,
    this.sublabel,
    this.icon,
    required this.onPressed,
    this.color = AppColors.primary,
    this.expanded = true,
  });

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final enabled = onPressed != null;

    final btn = Material(
      color: enabled ? color : const Color(0xFFC9CFD6),
      borderRadius: BorderRadius.circular(d.radius),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(d.radius),
        child: Container(
          height: sublabel == null ? d.buttonHeight : d.bigButtonHeight,
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(horizontal: d.px(28)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, color: Colors.white, size: d.px(28)),
                SizedBox(width: d.px(12)),
              ],
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: sublabel == null ? d.px(21) : d.px(24),
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                  if (sublabel != null) ...[
                    SizedBox(height: d.px(4)),
                    Text(
                      sublabel!,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.92),
                        fontSize: d.px(15),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );

    return expanded ? SizedBox(width: double.infinity, child: btn) : btn;
  }
}

/// 보조 버튼 (테두리형).
class OutlineButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final Color? color;

  const OutlineButton({
    super.key,
    required this.label,
    this.icon,
    required this.onPressed,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final c = color ?? AppColors.text;
    final enabled = onPressed != null;

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(d.radius),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(d.radius),
        child: Container(
          height: d.tapMin,
          padding: EdgeInsets.symmetric(horizontal: d.px(18)),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(d.radius),
            border: Border.all(
              color: enabled ? AppColors.borderStrong : AppColors.border,
              width: 1.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon,
                    size: d.px(21),
                    color: enabled ? c : AppColors.textFaint),
                SizedBox(width: d.px(8)),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: d.px(17),
                  fontWeight: FontWeight.w600,
                  color: enabled ? c : AppColors.textFaint,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 선택지 한 줄.
///
/// 라디오 버튼 대신 줄 전체를 누를 수 있는 큰 영역으로 만든다.
/// 작은 동그라미를 정확히 클릭하게 하면 실패율이 높다.
///
/// [note] 에는 항상 "원본이 실제로 어떤가"에 대한 답이 들어간다.
class ChoiceRow extends StatelessWidget {
  final bool selected;
  final String label;
  final String? value;
  final String? note;
  final String? badge;
  final Color? badgeColor;
  final VoidCallback onTap;

  const ChoiceRow({
    super.key,
    required this.selected,
    required this.label,
    this.value,
    this.note,
    this.badge,
    this.badgeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    return Material(
      color: selected ? AppColors.primaryLight : Colors.transparent,
      borderRadius: BorderRadius.circular(d.px(10)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(d.px(10)),
        child: Container(
          constraints: BoxConstraints(minHeight: d.tapMin),
          padding: EdgeInsets.symmetric(
              horizontal: d.px(14), vertical: d.px(10)),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(d.px(10)),
            border: Border.all(
              color: selected ? AppColors.primary : Colors.transparent,
              width: 2,
            ),
          ),
          // 창 최소 크기가 화면에 따라 작아질 수 있으므로 폭에 따라 배치를 바꾼다.
          // 좁을 때 한 줄로 밀어 넣으면 글자가 잘리거나 넘친다.
          child: LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth >= d.px(520);
            return Row(
              crossAxisAlignment:
                  wide ? CrossAxisAlignment.center : CrossAxisAlignment.start,
              children: [
                Icon(
                  selected ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: selected ? AppColors.primary : AppColors.textFaint,
                  size: d.px(24),
                ),
                SizedBox(width: d.px(12)),
                Expanded(
                  child: wide
                      ? Row(children: _wideParts(d))
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: _labelValueBadge(d, tight: true)),
                            if (note != null) ...[
                              SizedBox(height: d.px(3)),
                              Text(
                                note!,
                                style: TextStyle(
                                  fontSize: d.px(14),
                                  color: AppColors.textSub,
                                ),
                              ),
                            ],
                          ],
                        ),
                ),
              ],
            );
          }),
        ),
      ),
    );
  }

  List<Widget> _wideParts(Dim d) => [
        ..._labelValueBadge(d, tight: false),
        if (note != null)
          Expanded(
            child: Text(
              note!,
              style: TextStyle(fontSize: d.px(15), color: AppColors.textSub),
            ),
          )
        else
          const Spacer(),
      ];

  List<Widget> _labelValueBadge(Dim d, {required bool tight}) => [
        // '그대로 이어붙이기' 처럼 긴 항목이 두 줄로 접히지 않을 만큼 넓게.
        // 좁은 창에서는 고정폭을 포기하고 남는 만큼만 쓴다.
        if (tight)
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: d.px(17),
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: AppColors.text,
              ),
            ),
          )
        else
          SizedBox(
            width: d.px(200),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: d.px(18),
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: AppColors.text,
              ),
            ),
          ),
        if (value != null && value!.isNotEmpty) ...[
          SizedBox(width: d.px(10)),
          tight
              ? Text(
                  value!,
                  style: TextStyle(
                    fontSize: d.px(16),
                    fontWeight: FontWeight.w600,
                    color: AppColors.text,
                  ),
                )
              : SizedBox(
                  width: d.px(120),
                  child: Text(
                    value!,
                    style: TextStyle(
                      fontSize: d.px(17),
                      fontWeight: FontWeight.w600,
                      color: AppColors.text,
                    ),
                  ),
                ),
        ],
        if (badge != null) ...[
          SizedBox(width: d.px(8)),
          Container(
            padding:
                EdgeInsets.symmetric(horizontal: d.px(9), vertical: d.px(3)),
            decoration: BoxDecoration(
              color: badgeColor ?? AppColors.successLight,
              borderRadius: BorderRadius.circular(d.px(6)),
            ),
            child: Text(
              badge!,
              style: TextStyle(
                fontSize: d.px(14),
                fontWeight: FontWeight.w700,
                color: badgeColor == null ? AppColors.success : Colors.white,
              ),
            ),
          ),
          SizedBox(width: d.px(10)),
        ],
      ];
}

/// 알림 띠.
class NoticeBar extends StatelessWidget {
  final IconData icon;
  final String message;
  final String? detail;
  final Color color;
  final Color background;

  const NoticeBar({
    super.key,
    required this.icon,
    required this.message,
    this.detail,
    required this.color,
    required this.background,
  });

  factory NoticeBar.info(String message, {String? detail}) => NoticeBar(
        icon: Icons.info_outline,
        message: message,
        detail: detail,
        color: AppColors.primary,
        background: AppColors.primaryLight,
      );

  factory NoticeBar.caution(String message, {String? detail}) => NoticeBar(
        icon: Icons.warning_amber_rounded,
        message: message,
        detail: detail,
        color: AppColors.warning,
        background: AppColors.warningLight,
      );

  factory NoticeBar.error(String message, {String? detail}) => NoticeBar(
        icon: Icons.error_outline,
        message: message,
        detail: detail,
        color: AppColors.danger,
        background: AppColors.dangerLight,
      );

  factory NoticeBar.success(String message, {String? detail}) => NoticeBar(
        icon: Icons.check_circle_outline,
        message: message,
        detail: detail,
        color: AppColors.success,
        background: AppColors.successLight,
      );

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: d.px(16), vertical: d.px(13)),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(d.px(10)),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: d.px(24)),
          SizedBox(width: d.px(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message,
                  style: TextStyle(
                    fontSize: d.px(17),
                    fontWeight: FontWeight.w600,
                    color: AppColors.text,
                  ),
                ),
                if (detail != null) ...[
                  SizedBox(height: d.px(3)),
                  Text(
                    detail!,
                    style: TextStyle(fontSize: d.px(15), color: AppColors.textSub),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 요약 표의 한 줄. 라벨 - 값 - 비고
class SummaryRow extends StatelessWidget {
  final String label;
  final String value;
  final String? note;
  final Color? valueColor;
  final bool emphasize;

  const SummaryRow({
    super.key,
    required this.label,
    required this.value,
    this.note,
    this.valueColor,
    this.emphasize = false,
  });

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: d.px(6)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          SizedBox(
            width: d.px(110),
            child: Text(
              label,
              style: TextStyle(fontSize: d.px(16), color: AppColors.textSub),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: emphasize ? d.px(24) : d.px(18),
              fontWeight: FontWeight.w700,
              color: valueColor ?? AppColors.text,
            ),
          ),
          if (note != null) ...[
            SizedBox(width: d.px(12)),
            Expanded(
              child: Text(
                note!,
                style: TextStyle(fontSize: d.px(15), color: AppColors.textSub),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
