part of 'settings_panel.dart';

/// "만드는 방법" 선택(그대로 이어붙이기 / 다시 만들기).
extension _ModeSection on SettingsPanel {
  Widget _buildModeChoice(BuildContext context, JobPlan plan) {
    final d = Dim.of(context);

    if (!plan.losslessPossible) {
      return NoticeBar.info(
        '영상을 다시 만들어야 합니다.',
        detail: plan.losslessBlockedReason,
      );
    }

    final losslessBytes = plan.estimateOutputBytes(
      OutputSettings(
        lossless: true,
        width: 0,
        height: 0,
        frameRate: plan.defaultFps.fps,
        videoBitrate: 0,
        outputDir: '',
        outputName: '',
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Label('만드는 방법'),
        SizedBox(height: d.px(8)),
        ChoiceRow(
          selected: state.useLossless,
          label: '그대로 이어붙이기',
          value: formatBytes(losslessBytes),
          badge: '추천',
          note: '화질 손실 없음 · 금방 끝남 (모든 영상 설정이 같습니다)',
          onTap: () => state.setLossless(true),
        ),
        SizedBox(height: d.px(6)),
        ChoiceRow(
          selected: !state.useLossless,
          label: '다시 만들기',
          value: '설정 변경',
          note: '해상도나 화질을 바꾸고 싶을 때 · 만드는 시간이 오래 걸림',
          onTap: () => state.setLossless(false),
        ),
      ],
    );
  }
}
