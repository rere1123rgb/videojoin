part of 'settings_panel.dart';

/// 프레임레이트 선택.
extension _FpsSection on SettingsPanel {
  Widget _buildFps(BuildContext context, JobPlan plan) {
    final d = Dim.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Label('프레임레이트 (초당 화면 수)'),
        SizedBox(height: d.px(8)),
        for (final f in plan.frameRates) ...[
          ChoiceRow(
            selected: state.fps?.fps == f.fps,
            label: f.label,
            value: f.fps.den != 1 ? '${f.fps.num}/${f.fps.den}' : '',
            badge: f.isOriginalMax ? '원본' : null,
            note: f.note,
            onTap: () => state.setFps(f),
          ),
          SizedBox(height: d.px(6)),
        ],
      ],
    );
  }
}

/// 비트레이트(화질) 선택.
extension _BitrateSection on SettingsPanel {
  Widget _buildBitrate(BuildContext context, JobPlan plan) {
    final d = Dim.of(context);
    final opts = state.bitrateOptions;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Label('비트레이트 (화질)'),
        SizedBox(height: d.px(8)),
        for (final o in opts) ...[
          Builder(
            builder: (context) {
              final s = state.buildSettings();
              final bytes = s == null
                  ? 0
                  : plan.estimateOutputBytes(s..videoBitrate = o.bps);
              return ChoiceRow(
                selected: state.bitrateKind == o.kind,
                label: o.title,
                value: o.label,
                badge: o.isOriginal ? '원본' : null,
                note: '${formatBytes(bytes)}  ·  ${o.note}',
                onTap: () => state.setBitrateKind(o.kind),
              );
            },
          ),
          SizedBox(height: d.px(6)),
        ],
      ],
    );
  }
}
