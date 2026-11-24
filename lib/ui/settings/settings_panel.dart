import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../engine/models.dart';
import '../../engine/planner.dart';
import '../../state/app_state.dart';
import '../hangul_caret.dart';
import '../theme.dart';
import '../transition_preview.dart';
import '../widgets/common.dart';

part 'advanced_section.dart';
part 'aspect_lock.dart';
part 'custom_value_panel.dart';
part 'fps_bitrate_section.dart';
part 'mode_section.dart';
part 'output_panel.dart';
part 'resolution_section.dart';
part 'settings_widgets.dart';
part 'suffix_row.dart';
part 'transitions_section.dart';

/// 출력 설정.
///
/// 용어는 그대로 쓰되(해상도, 비트레이트, 프레임레이트) 괄호로 쉬운 말을
/// 병기한다. 필요한 건 설명이 아니라 **어떤 값을 골라야 하는지에 대한 근거**다.
/// 그래서 모든 선택지 옆에는 "원본이 실제로 어떤가"가 붙는다.
class SettingsPanel extends StatelessWidget {
  final AppState state;

  const SettingsPanel({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final plan = state.plan;
    if (plan == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildModeChoice(context, plan),
        SizedBox(height: d.px(14)),
        SmoothTransitionCard(
            state: state, losslessPossibleWithout: _losslessIfOff(plan)),
        SizedBox(height: d.px(10)),
        FadeEndsToggle(
            state: state, losslessPossibleWithout: _losslessIfOffEnds(plan)),
        if (!state.useLossless) ...[
          SizedBox(height: d.gapLg),
          _buildResolution(context, plan),
          SizedBox(height: d.gapLg),
          _buildFps(context, plan),
          SizedBox(height: d.gapLg),
          _buildBitrate(context, plan),
          SizedBox(height: d.gapLg),
          _buildAdvanced(context, plan),
          SizedBox(height: d.gapLg),
          CustomValuePanel(state: state),
        ],
      ],
    );
  }

  /// 전환을 끄면 그대로 이어붙이기가 가능한가. 켤 때 안내 문구에 쓴다.
  bool _losslessIfOff(JobPlan plan) =>
      plan.losslessPossible ||
      (state.smoothTransitions &&
          !state.fadeEnds &&
          plan.losslessBlockedReason ==
              '영상 사이를 부드럽게 넘기려면 다시 만들어야 합니다.');

  /// 처음·끝 서서히를 끄면 그대로 이어붙이기가 가능한가.
  bool _losslessIfOffEnds(JobPlan plan) =>
      plan.losslessPossible ||
      (state.fadeEnds &&
          plan.losslessBlockedReason ==
              '처음과 끝을 서서히 하려면 다시 만들어야 합니다.');
}
