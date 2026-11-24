part of 'settings_panel.dart';

/// 해상도 선택과, 화면비가 다른 영상을 어떻게 맞출지 고르는 곳.
extension _ResolutionSection on SettingsPanel {
  Widget _buildResolution(BuildContext context, JobPlan plan) {
    final d = Dim.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Label('해상도 (화면 크기)'),
        SizedBox(height: d.px(8)),
        for (final r in plan.resolutions) ...[
          ChoiceRow(
            selected: state.resolution == r,
            label: r.nickname,
            value: r.label,
            badge: r.isOriginalMax ? '원본' : null,
            note: r.note,
            onTap: () => state.setResolution(r),
          ),
          SizedBox(height: d.px(6)),
        ],
        if (plan.mixedOrientation || _needsFitChoice(plan)) ...[
          SizedBox(height: d.px(10)),
          _Label('화면비가 다른 영상 처리'),
          SizedBox(height: d.px(8)),
          Row(
            children: [
              Expanded(
                child: ChoiceRow(
                  selected: state.fitMode == FitMode.pad,
                  label: '여백 채움',
                  note: '전체가 보임 · 남는 곳은 검은색',
                  onTap: () => state.setFitMode(FitMode.pad),
                ),
              ),
              SizedBox(width: d.px(10)),
              Expanded(
                child: ChoiceRow(
                  selected: state.fitMode == FitMode.crop,
                  label: '잘라내기',
                  note: '화면을 꽉 채움 · 가장자리가 잘림',
                  onTap: () => state.setFitMode(FitMode.crop),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  bool _needsFitChoice(JobPlan plan) {
    final valid = plan.clips.where((c) => c.spec.ok).toList();
    if (valid.length < 2) return false;
    final aspects = valid.map((c) => (c.aspect * 100).round()).toSet();
    return aspects.length > 1;
  }
}
