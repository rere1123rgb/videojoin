part of 'settings_panel.dart';

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    return Text(
      text,
      style: TextStyle(
        fontSize: d.px(19),
        fontWeight: FontWeight.w700,
        color: AppColors.text,
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  final bool on;
  final String title;
  final String note;
  final VoidCallback onTap;

  const _CheckRow(
      {required this.on,
      required this.title,
      required this.note,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(d.radius),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: d.px(14), vertical: d.px(10)),
        child: Row(
          children: [
            Icon(on ? Icons.check_box : Icons.check_box_outline_blank,
                color: on ? AppColors.primary : AppColors.textSub,
                size: d.px(28)),
            SizedBox(width: d.px(12)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: d.px(18), fontWeight: FontWeight.w700)),
                  SizedBox(height: d.px(2)),
                  Text(note,
                      style: TextStyle(
                          fontSize: d.px(15), color: AppColors.textSub)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "색  [검은 화면] [흰 화면]" 같은 한 줄. 좁거나 글자가 커지면 줄바꿈한다.
class _PillRow<T> extends StatelessWidget {
  final String label;
  final List<T> values;
  final T selected;
  final String Function(T) text;
  final void Function(T) onSelect;

  const _PillRow(
      {required this.label,
      required this.values,
      required this.selected,
      required this.text,
      required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    return Wrap(
      spacing: d.px(8),
      runSpacing: d.px(8),
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Padding(
          padding: EdgeInsets.only(right: d.px(4)),
          child: Text(label,
              style: TextStyle(
                  fontSize: d.px(16),
                  fontWeight: FontWeight.w700,
                  color: AppColors.textSub)),
        ),
        for (final v in values)
          _Pill(
            text: text(v),
            selected: v == selected,
            onTap: () => onSelect(v),
          ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final bool selected;
  final VoidCallback onTap;

  const _Pill(
      {required this.text, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    return Material(
      color: selected ? AppColors.primary : AppColors.surface,
      borderRadius: BorderRadius.circular(d.px(21)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(d.px(21)),
        child: Container(
          // alignment 를 주면 Wrap 안에서 줄 전체 폭으로 늘어난다.
          // 높이는 위아래 여백으로 맞춘다(약 42px).
          constraints: BoxConstraints(minWidth: d.px(64)),
          padding: EdgeInsets.symmetric(horizontal: d.px(18), vertical: d.px(9)),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(d.px(21)),
            border: Border.all(
                color: selected ? AppColors.primary : AppColors.border,
                width: 1.5),
          ),
          child: Text(text,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: d.px(16),
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.white : AppColors.text)),
        ),
      ),
    );
  }
}
