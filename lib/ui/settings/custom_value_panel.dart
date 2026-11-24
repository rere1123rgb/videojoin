part of 'settings_panel.dart';

/// 수치를 직접 넣는 곳.
///
/// 프리셋으로 안 되는 값이 필요할 때를 위한 탈출구다. 평소에는 접혀 있다 —
/// 대부분의 경우 손댈 이유가 없고, 펼쳐 두면 오히려 시선을 뺏는다.
/// 켠 항목만 프리셋을 밀어내고, 끄면 원래대로 돌아간다.
class CustomValuePanel extends StatefulWidget {
  final AppState state;

  const CustomValuePanel({super.key, required this.state});

  @override
  State<CustomValuePanel> createState() => _CustomValuePanelState();
}

class _CustomValuePanelState extends State<CustomValuePanel> {
  late final TextEditingController _w;
  late final TextEditingController _h;
  late final TextEditingController _b;
  late final TextEditingController _f;

  @override
  void initState() {
    super.initState();
    final s = widget.state;
    _w = TextEditingController(text: '${s.customWidth}');
    _h = TextEditingController(text: '${s.customHeight}');
    _b = TextEditingController(text: _trim(s.customBitrateMbps));
    _f = TextEditingController(text: _trim(s.customFpsValue));
  }

  static String _trim(double v) {
    final s = v.toStringAsFixed(2);
    return s.endsWith('.00') ? s.substring(0, s.length - 3) : s;
  }

  @override
  void dispose() {
    _w.dispose();
    _h.dispose();
    _b.dispose();
    _f.dispose();
    super.dispose();
  }

  /// 스위치를 켤 때 현재 프리셋 값이 입력칸에 들어오도록 동기화한다.
  void _syncFromState() {
    final s = widget.state;
    _w.text = '${s.customWidth}';
    _h.text = '${s.customHeight}';
    _b.text = _trim(s.customBitrateMbps);
    _f.text = _trim(s.customFpsValue);
  }

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final s = widget.state;
    final issue = s.customValueIssue;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9FB),
        borderRadius: BorderRadius.circular(d.radius),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 접힌 상태에서는 이 줄만 보인다.
          InkWell(
            onTap: () => s.setAdvancedOpen(!s.advancedOpen),
            borderRadius: BorderRadius.circular(d.radius),
            child: Padding(
              padding: EdgeInsets.all(d.px(16)),
              child: Row(
                children: [
                  Icon(
                    s.advancedOpen ? Icons.expand_less : Icons.expand_more,
                    size: d.px(26),
                    color: AppColors.textSub,
                  ),
                  SizedBox(width: d.px(10)),
                  Text(
                    '수치 직접 넣기',
                    style: TextStyle(
                      fontSize: d.px(18),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(width: d.px(10)),
                  Expanded(
                    child: Text(
                      _summary(s),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: d.px(15),
                        color: AppColors.textSub,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          if (s.advancedOpen) ...[
            Padding(
              padding: EdgeInsets.fromLTRB(d.px(16), 0, d.px(16), d.px(16)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(),
                  SizedBox(height: d.px(10)),

                  _Line(
                    on: s.useCustomResolution,
                    label: '해상도 (화면 크기)',
                    onChanged: (v) {
                      s.setUseCustomResolution(v);
                      if (v) _syncFromState();
                    },
                    fields: [
                      _NumField(
                        controller: _w,
                        suffix: '가로',
                        width: d.px(120),
                        enabled: s.useCustomResolution,
                        onChanged: (v) {
                          final n = int.tryParse(v);
                          if (n == null) return;
                          s.setCustomResolution(width: n);
                          // 묶여 있으면 반대쪽 칸도 따라 움직인 값을 보여 준다.
                          if (s.lockAspect) _h.text = '${s.customHeight}';
                        },
                      ),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: d.px(8)),
                        child: Text(
                          '×',
                          style: TextStyle(
                            fontSize: d.px(18),
                            color: s.useCustomResolution
                                ? AppColors.textSub
                                : AppColors.textFaint,
                          ),
                        ),
                      ),
                      _NumField(
                        controller: _h,
                        suffix: '세로',
                        width: d.px(120),
                        enabled: s.useCustomResolution,
                        onChanged: (v) {
                          final n = int.tryParse(v);
                          if (n == null) return;
                          s.setCustomResolution(height: n);
                          if (s.lockAspect) _w.text = '${s.customWidth}';
                        },
                      ),
                      SizedBox(width: d.px(14)),
                      _AspectLock(
                        on: s.lockAspect,
                        enabled: s.useCustomResolution,
                        ratio: s.sourceAspectLabel,
                        onToggle: () {
                          s.setLockAspect(!s.lockAspect);
                          // 켜는 순간 세로가 비율에 맞춰지므로 칸도 맞춰 준다.
                          _h.text = '${s.customHeight}';
                        },
                      ),
                    ],
                  ),
                  SizedBox(height: d.px(12)),

                  _Line(
                    on: s.useCustomBitrate,
                    label: '비트레이트 (화질)',
                    onChanged: (v) {
                      s.setUseCustomBitrate(v);
                      if (v) _syncFromState();
                    },
                    fields: [
                      _NumField(
                        controller: _b,
                        suffix: 'Mbps',
                        width: d.px(140),
                        decimal: true,
                        enabled: s.useCustomBitrate,
                        onChanged: (v) {
                          final n = double.tryParse(v);
                          if (n != null) s.setCustomBitrate(n);
                        },
                      ),
                    ],
                  ),
                  SizedBox(height: d.px(12)),

                  _Line(
                    on: s.useCustomFps,
                    label: '프레임레이트',
                    onChanged: (v) {
                      s.setUseCustomFps(v);
                      if (v) _syncFromState();
                    },
                    fields: [
                      _NumField(
                        controller: _f,
                        suffix: 'fps',
                        width: d.px(140),
                        decimal: true,
                        enabled: s.useCustomFps,
                        onChanged: (v) {
                          final n = double.tryParse(v);
                          if (n != null) s.setCustomFps(n);
                        },
                      ),
                    ],
                  ),

                  if (issue != null) ...[
                    SizedBox(height: d.gap),
                    NoticeBar.error(issue),
                  ] else if (s.useCustomResolution &&
                      (s.customWidth.isOdd || s.customHeight.isOdd)) ...[
                    SizedBox(height: d.gap),
                    NoticeBar.info(
                      '홀수는 짝수로 맞춰서 만듭니다 '
                      '(${s.effectiveWidth} × ${s.effectiveHeight}).',
                      detail: '영상 형식이 짝수 크기만 지원합니다.',
                    ),
                  ],

                  if (s.useCustomFps) ...[
                    SizedBox(height: d.gap),
                    NoticeBar.info(
                      '실제로 쓰이는 값: ${s.effectiveFps.detailLabel}',
                      detail: '29.97 처럼 딱 떨어지지 않는 값은 정확한 분수로 맞춥니다.',
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _summary(AppState s) {
    final on = <String>[];
    if (s.useCustomResolution) {
      on.add('${s.effectiveWidth}×${s.effectiveHeight}');
    }
    if (s.useCustomBitrate) on.add(formatBitrate(s.effectiveBitrate));
    if (s.useCustomFps) on.add(s.effectiveFps.label);
    if (on.isEmpty) return '프리셋으로 안 되는 값이 필요할 때만 쓰세요';
    return '직접 넣은 값 사용 중 · ${on.join(" · ")}';
  }
}

class _Line extends StatelessWidget {
  final bool on;
  final String label;
  final ValueChanged<bool> onChanged;
  final List<Widget> fields;

  const _Line({
    required this.on,
    required this.label,
    required this.onChanged,
    required this.fields,
  });

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    return Row(
      children: [
        SizedBox(
          width: d.px(56),
          child: Switch(value: on, onChanged: onChanged),
        ),
        SizedBox(width: d.px(8)),
        SizedBox(
          width: d.px(190),
          child: Text(
            label,
            style: TextStyle(
              fontSize: d.px(17),
              fontWeight: on ? FontWeight.w700 : FontWeight.w500,
              color: on ? AppColors.text : AppColors.textSub,
            ),
          ),
        ),
        ...fields,
      ],
    );
  }
}

class _NumField extends StatelessWidget {
  final TextEditingController controller;
  final String suffix;
  final double width;
  final bool decimal;
  final bool enabled;
  final ValueChanged<String> onChanged;

  const _NumField({
    required this.controller,
    required this.suffix,
    required this.width,
    required this.onChanged,
    this.decimal = false,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    return SizedBox(
      width: width,
      height: d.tapMin,
      child: TextField(
        controller: controller,
        // 스위치를 켜지 않으면 아예 입력을 막는다.
        // 흐리게만 해 두면 값을 고칠 수 있어서 켜진 줄 착각하게 된다.
        enabled: enabled,
        onChanged: onChanged,
        keyboardType: TextInputType.numberWithOptions(decimal: decimal),
        inputFormatters: [
          FilteringTextInputFormatter.allow(
            decimal ? RegExp(r'[0-9.]') : RegExp(r'[0-9]'),
          ),
        ],
        style: TextStyle(
          fontSize: d.px(17),
          color: enabled ? AppColors.text : AppColors.textFaint,
        ),
        decoration: InputDecoration(
          isDense: true,
          suffixText: suffix,
          suffixStyle: TextStyle(
            fontSize: d.px(14),
            color: enabled ? AppColors.textSub : AppColors.textFaint,
          ),
          filled: true,
          fillColor: enabled ? AppColors.surface : AppColors.surface2,
          contentPadding: EdgeInsets.symmetric(
            horizontal: d.px(12),
            vertical: d.px(10),
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(d.px(8)),
            borderSide: const BorderSide(color: AppColors.borderStrong),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(d.px(8)),
            borderSide: const BorderSide(color: AppColors.borderStrong),
          ),
          disabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(d.px(8)),
            borderSide: const BorderSide(color: AppColors.border),
          ),
        ),
      ),
    );
  }
}
