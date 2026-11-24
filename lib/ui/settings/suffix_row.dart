part of 'settings_panel.dart';

/// 자동 이름 뒤에 붙일 말.
class _SuffixRow extends StatefulWidget {
  final AppState state;

  const _SuffixRow({required this.state});

  @override
  State<_SuffixRow> createState() => _SuffixRowState();
}

class _SuffixRowState extends State<_SuffixRow> {
  late final TextEditingController _c;

  @override
  void initState() {
    super.initState();
    _c = TextEditingController(text: widget.state.nameSuffix);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final s = widget.state;
    final folder = s.sourceFolder();
    final folderName = folder == null ? '폴더이름' : p.basename(folder);

    return Container(
      padding: EdgeInsets.all(d.px(14)),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(d.px(10)),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '뒤에 붙일 말',
                style: TextStyle(
                  fontSize: d.px(16),
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(width: d.px(12)),
              Expanded(
                child: SizedBox(
                  height: d.px(44),
                  child: HangulCaretFix(
                    controller: _c,
                    // 값은 건드리지 않고 커서 그리는 자리만 바로잡는다.
                    builder: (context, cursorColor) => TextField(
                      controller: _c,
                      cursorColor: cursorColor,
                      onChanged: s.setNameSuffix,
                      style: TextStyle(fontSize: d.px(17)),
                      decoration: InputDecoration(
                        isDense: true,
                        // 무엇을 넣을 수 있는지 예시로만 알려 준다.
                        // 결과는 바로 아래 줄에서 실시간으로 보인다.
                        hintText: '예: _합침, _merged, _모음  (비워 두어도 됩니다)',
                        hintStyle: TextStyle(
                          fontSize: d.px(15),
                          color: AppColors.textFaint,
                        ),
                        filled: true,
                        fillColor: AppColors.surface,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: d.px(12),
                          vertical: d.px(10),
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(d.px(8)),
                          borderSide: const BorderSide(
                            color: AppColors.borderStrong,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(d.px(8)),
                          borderSide: const BorderSide(
                            color: AppColors.borderStrong,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: d.px(8)),
          // 어디에 붙는 말인지만 설명한다. 폴더 이름은 따옴표로 감싸 경계를 분명히 하고,
          // 결과는 위쪽 이름 칸에서 보이므로 되풀이하지 않는다.
          Row(
            children: [
              Icon(
                Icons.folder_outlined,
                size: d.px(16),
                color: AppColors.textFaint,
              ),
              SizedBox(width: d.px(6)),
              Flexible(
                child: Text(
                  s.nameSuffix.trim().isEmpty
                      ? '지금은 폴더 이름 "$folderName" 만 씁니다'
                      : '폴더 이름 "$folderName" 뒤에 붙습니다',
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
        ],
      ),
    );
  }
}
