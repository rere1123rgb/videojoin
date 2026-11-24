part of 'settings_panel.dart';

/// 영상 형식(코덱)과 그래픽카드 가속.
extension _AdvancedSection on SettingsPanel {
  Widget _buildAdvanced(BuildContext context, JobPlan plan) {
    final d = Dim.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Label('영상 형식 (코덱)'),
        SizedBox(height: d.px(8)),
        ChoiceRow(
          selected: state.codec == CodecChoice.h264,
          label: 'H.264',
          badge: '추천',
          note: '어느 기기에서나 재생됩니다',
          onTap: () => state.setCodec(CodecChoice.h264),
        ),
        SizedBox(height: d.px(6)),
        ChoiceRow(
          selected: state.codec == CodecChoice.hevc,
          label: 'H.265',
          note: '용량이 약 40% 줄지만 오래된 기기에서 재생이 안 될 수 있습니다',
          onTap: () => state.setCodec(CodecChoice.hevc),
        ),
        SizedBox(height: d.gap),
        _GpuToggle(state: state),
      ],
    );
  }
}

class _GpuToggle extends StatelessWidget {
  final AppState state;

  const _GpuToggle({required this.state});

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final available = state.encoders.anyGpu;

    return Container(
      padding: EdgeInsets.all(d.px(14)),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9FB),
        borderRadius: BorderRadius.circular(d.px(10)),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Icon(
            Icons.memory,
            size: d.px(26),
            color: available ? AppColors.primary : AppColors.textFaint,
          ),
          SizedBox(width: d.px(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  available ? '그래픽카드로 처리하기' : '그래픽카드 사용 불가',
                  style: TextStyle(
                    fontSize: d.px(17),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: d.px(2)),
                Text(
                  available
                      ? '${state.encoders.gpuLabel} 감지됨 · 만드는 데 걸리는 시간이 줄어듭니다 (영상 속도는 그대로)'
                      : '이 컴퓨터에서는 CPU 로 처리합니다 (만드는 시간이 더 걸립니다)',
                  style: TextStyle(
                    fontSize: d.px(15),
                    color: AppColors.textSub,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: state.useGpu && available,
            onChanged: available ? (v) => state.setUseGpu(v) : null,
          ),
        ],
      ),
    );
  }
}
