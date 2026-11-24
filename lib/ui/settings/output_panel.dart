part of 'settings_panel.dart';

/// 저장 위치와 파일 이름.
class OutputPanel extends StatefulWidget {
  final AppState state;

  const OutputPanel({super.key, required this.state});

  @override
  State<OutputPanel> createState() => _OutputPanelState();
}

class _OutputPanelState extends State<OutputPanel> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.state.outputName);
  }

  @override
  void didUpdateWidget(OutputPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 파일이 새로 들어와서 이름이 자동 제안된 경우 입력칸에도 반영한다.
    if (_controller.text != widget.state.outputName &&
        !_controller.selection.isValid) {
      _controller.text = widget.state.outputName;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final state = widget.state;
    final auto = state.autoNaming;

    // 수동 모드에서 상태의 이름이 밖에서 바뀌었으면 입력칸에도 반영
    if (!auto &&
        _controller.text != state.outputName &&
        !_controller.selection.isValid) {
      _controller.text = state.outputName;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _Label('파일 이름'),
            const Spacer(),
            _AutoNameToggle(state: state),
          ],
        ),
        SizedBox(height: d.px(10)),

        // 최종 파일 이름(결과)을 접미사 설정보다 위에 먼저 보여 준다.
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: d.tapMin,
                child: auto
                    // 자동일 때는 결과를 보여주기만 한다. 고칠 수 있는 것처럼
                    // 보이는데 무시되면 오히려 헷갈린다.
                    ? Container(
                        alignment: Alignment.centerLeft,
                        padding: EdgeInsets.symmetric(horizontal: d.px(14)),
                        decoration: BoxDecoration(
                          color: AppColors.primaryLight,
                          borderRadius: BorderRadius.circular(d.px(10)),
                          border: Border.all(
                            color: AppColors.primary.withValues(alpha: 0.35),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.movie_outlined,
                              size: d.px(20),
                              color: AppColors.primary,
                            ),
                            SizedBox(width: d.px(8)),
                            Expanded(
                              child: Text(
                                state.effectiveOutputName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: d.px(19),
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.primaryDark,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    : HangulCaretFix(
                        controller: _controller,
                        // 값은 건드리지 않고 커서 그리는 자리만 바로잡는다.
                        builder: (context, cursorColor) => TextField(
                          controller: _controller,
                          cursorColor: cursorColor,
                          onChanged: state.setOutputName,
                          style: TextStyle(fontSize: d.px(18)),
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: AppColors.surface,
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: d.px(14),
                              vertical: d.px(12),
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(d.px(10)),
                              borderSide: const BorderSide(
                                color: AppColors.borderStrong,
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(d.px(10)),
                              borderSide: const BorderSide(
                                color: AppColors.borderStrong,
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
            ),
            SizedBox(width: d.px(10)),
            Text(
              '.mp4',
              style: TextStyle(
                fontSize: d.px(19),
                fontWeight: FontWeight.w600,
                color: AppColors.textSub,
              ),
            ),
          ],
        ),

        // 접미사는 위 이름이 어떻게 만들어졌는지에 대한 부가 설정이다.
        // 자동일 때만 의미가 있다.
        if (auto) ...[SizedBox(height: d.px(10)), _SuffixRow(state: state)],

        SizedBox(height: d.gap),
        _Label('저장할 폴더'),
        SizedBox(height: d.px(8)),
        Row(
          children: [
            Expanded(
              child: Container(
                height: d.tapMin,
                alignment: Alignment.centerLeft,
                padding: EdgeInsets.symmetric(horizontal: d.px(14)),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(d.px(10)),
                  border: Border.all(color: AppColors.borderStrong),
                ),
                child: Text(
                  state.effectiveOutputDir,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: d.px(17)),
                ),
              ),
            ),
            SizedBox(width: d.px(10)),
            OutlineButton(
              label: '폴더 바꾸기',
              icon: Icons.folder_open,
              onPressed: () async {
                final dir = await getDirectoryPath(
                  confirmButtonText: '이 폴더에 저장',
                  initialDirectory: state.effectiveOutputDir,
                );
                if (dir != null) await state.setOutputDir(dir);
              },
            ),
          ],
        ),

        // 상태를 설명하는 문구는 두지 않는다. 저장될 곳은 바로 위 경로에 적혀 있다.
        // 직접 고른 뒤에만 되돌아갈 길을 보여 준다.
        if (state.canResetOutputDir) ...[
          SizedBox(height: d.px(8)),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlineButton(
              label: '영상이 있던 폴더로 되돌리기',
              icon: Icons.undo,
              onPressed: state.resetOutputDirToSource,
            ),
          ),
        ],

        if (state.outputExists) ...[
          SizedBox(height: d.gap),
          NoticeBar.caution(
            '같은 이름의 파일이 이미 있습니다.',
            detail: '그대로 진행하면 덮어씁니다. 이름을 바꾸는 것을 권합니다.',
          ),
        ],
      ],
    );
  }
}

/// 자동 이름 켜고 끄기.
class _AutoNameToggle extends StatelessWidget {
  final AppState state;

  const _AutoNameToggle({required this.state});

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    return InkWell(
      onTap: () => state.setAutoNaming(!state.autoNaming),
      borderRadius: BorderRadius.circular(d.px(8)),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: d.px(2), horizontal: d.px(4)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IgnorePointer(
              child: Checkbox(value: state.autoNaming, onChanged: (_) {}),
            ),
            SizedBox(width: d.px(4)),
            Text(
              '폴더 이름으로 자동 짓기',
              style: TextStyle(
                fontSize: d.px(17),
                fontWeight: state.autoNaming
                    ? FontWeight.w600
                    : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
