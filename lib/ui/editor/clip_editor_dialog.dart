import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../engine/frame_grabber.dart';
import '../../engine/models.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'editor_controller.dart';
import 'editor_debug.dart';
import 'parts/editor_chrome.dart';
import 'parts/editor_controls.dart';
import 'parts/editor_preview.dart';
import 'parts/editor_timeline.dart';

/// 영상 한 개를 손보는 창을 띄운다.
///
/// 대화상자는 [UiScale] 바깥에 그려지므로 여는 쪽의 배율을 넘겨 감싼다.
/// 창 안의 [이전 영상]/[다음 영상] 으로 목록을 차례로 손볼 수 있다.
Future<void> showClipEditor(
  BuildContext context,
  AppState state,
  ClipItem clip,
) async {
  final tools = state.tools;
  if (tools == null || !clip.spec.ok) return;
  final scale = Dim.of(context).scale;
  final grabber = FrameGrabber(tools);

  var current = clip;
  while (true) {
    final editable = state.clips.where((c) => c.spec.ok).toList();
    final idx = editable.indexWhere((c) => c.id == current.id);
    if (idx < 0) return;
    if (!context.mounted) return;
    final result = await showDialog<EditorExit>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => UiScale(
        factor: scale,
        child: ClipEditorDialog(
          key: ValueKey(current.id),
          state: state,
          clip: current,
          grabber: grabber,
          position: idx + 1,
          count: editable.length,
        ),
      ),
    );
    if (result == EditorExit.next && idx + 1 < editable.length) {
      current = editable[idx + 1];
    } else if (result == EditorExit.previous && idx > 0) {
      current = editable[idx - 1];
    } else {
      return;
    }
  }
}

/// 편집 창을 닫은 이유.
enum EditorExit { close, previous, next }

class ClipEditorDialog extends StatefulWidget {
  final AppState state;
  final ClipItem clip;
  final FrameGrabber grabber;

  /// 목록에서 몇 번째인지(1부터)와 전체 수. 이전/다음 버튼에 쓴다.
  final int position;
  final int count;

  const ClipEditorDialog({
    super.key,
    required this.state,
    required this.clip,
    required this.grabber,
    this.position = 1,
    this.count = 1,
  });

  @override
  State<ClipEditorDialog> createState() => _ClipEditorDialogState();
}

class _ClipEditorDialogState extends State<ClipEditorDialog> {
  late final ClipEditorController _c;
  final FocusNode _focus = FocusNode();
  final GlobalKey _headerKey = GlobalKey();
  final GlobalKey _controlsKey = GlobalKey();
  final GlobalKey _footerKey = GlobalKey();
  double? _restH;
  double? _footerH;

  @override
  void initState() {
    super.initState();
    _c = ClipEditorController(
      state: widget.state,
      clip: widget.clip,
      grabber: widget.grabber,
    );
    applyEditorDebugScenario(_c);
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _navigate(EditorExit dir) {
    if (_c.apply()) Navigator.pop(context, dir);
  }

  void _applyAndClose() {
    if (_c.apply()) Navigator.pop(context, EditorExit.close);
  }

  void _cancel() {
    _c.stop();
    Navigator.pop(context, EditorExit.close);
  }

  /// [처음 상태로]: 전부 지우므로 한 번 물어본다. [되돌리기] 로 살릴 수 있다.
  Future<void> _askReset() async {
    if (!_c.isEdited) return;
    final scale = Dim.of(context).scale;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => UiScale(
        factor: scale,
        child: Builder(
          builder: (ctx) {
            final d = Dim.of(ctx);
            return AlertDialog(
              title: Text(
                '처음 상태로 되돌릴까요?',
                style: TextStyle(
                  fontSize: d.px(22),
                  fontWeight: FontWeight.w700,
                ),
              ),
              content: SizedBox(
                width: d.px(480),
                child: Text(
                  '이 영상에서 자른 것·소리·밝기·회전을 모두 지웁니다.',
                  style: TextStyle(fontSize: d.px(17)),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text('그만두기', style: TextStyle(fontSize: d.px(17))),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(
                    '처음 상태로',
                    style: TextStyle(
                      fontSize: d.px(17),
                      color: AppColors.danger,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
    if (ok == true) _c.resetAll();
    if (mounted) _focus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final kb = HardwareKeyboard.instance;
    final step = kb.isShiftPressed ? 5.0 : (kb.isControlPressed ? 0.1 : 1.0);
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowLeft) {
      _c.seek(_c.pos - step);
    } else if (k == LogicalKeyboardKey.arrowRight) {
      _c.seek(_c.pos + step);
    } else if (k == LogicalKeyboardKey.home) {
      _c.seek(0, immediate: true);
    } else if (k == LogicalKeyboardKey.end) {
      _c.seek(_c.dur, immediate: true);
    } else if (k == LogicalKeyboardKey.space && e is KeyDownEvent) {
      _c.togglePlay();
    } else if (k == LogicalKeyboardKey.keyI && e is KeyDownEvent) {
      _c.markIn();
    } else if (k == LogicalKeyboardKey.keyO && e is KeyDownEvent) {
      _c.markOut();
    } else if (k == LogicalKeyboardKey.delete && e is KeyDownEvent) {
      _c.applySelection(false);
    } else if (k == LogicalKeyboardKey.escape && e is KeyDownEvent) {
      if (_c.sel == null) return KeyEventResult.ignored;
      _c.clearSelection();
    } else if (k == LogicalKeyboardKey.keyZ && kb.isControlPressed) {
      _c.undo();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final screen = MediaQuery.of(context).size;
    final w = (screen.width * 0.94).clamp(600.0, d.px(1320));
    final h = (screen.height * 0.94).clamp(500.0, d.px(980));

    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) => Dialog(
        insetPadding: EdgeInsets.all(d.px(12)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(d.radius),
        ),
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: SizedBox(
            width: w,
            height: h,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                d.px(22),
                d.px(14),
                d.px(22),
                d.px(14),
              ),
              // 글씨가 크면 버튼들이 화면을 다 차지해 미리보기가 사라질 수 있다.
              // 남는 공간에서 높이를 정하되 최소 높이를 보장하고, 넘치면 스크롤한다.
              child: LayoutBuilder(
                builder: (context, box) {
                  // 미리보기를 뺀 나머지의 실제 높이를 그려 본 뒤 재서 남는 높이를
                  // 미리보기에 준다. 버튼이 줄바꿈되면 높이가 달라져 어림값은 안 맞는다.
                  final restGuess = _restH ?? d.px(520);
                  final footerH = _footerH ?? d.px(70);
                  final scrollH = box.maxHeight - footerH;
                  final previewH = (scrollH - restGuess - 2).clamp(
                    240.0,
                    double.infinity,
                  );
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    final h1 = _headerKey.currentContext?.size?.height ?? 0;
                    final h2 = _controlsKey.currentContext?.size?.height ?? 0;
                    final h3 = _footerKey.currentContext?.size?.height ?? 0;
                    final measured = h1 + h2 + d.px(10);
                    final restChanged =
                        h2 > 0 &&
                        (_restH == null || (measured - _restH!).abs() > 1);
                    final footChanged =
                        h3 > 0 &&
                        (_footerH == null || (h3 - _footerH!).abs() > 1);
                    if (restChanged || footChanged) {
                      setState(() {
                        if (restChanged) _restH = measured;
                        if (footChanged) _footerH = h3;
                      });
                    }
                  });
                  // [적용] 줄은 위쪽이 넘치더라도 늘 보이게 스크롤 밖에 둔다.
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              KeyedSubtree(
                                key: _headerKey,
                                child: EditorHeader(
                                  c: _c,
                                  position: widget.position,
                                  count: widget.count,
                                  onReset: _askReset,
                                ),
                              ),
                              SizedBox(height: d.px(10)),
                              SizedBox(
                                key: const ValueKey('clip-editor-preview'),
                                height: previewH,
                                child: EditorPreview(_c),
                              ),
                              Column(
                                key: _controlsKey,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  SizedBox(height: d.px(8)),
                                  if (_c.canTrim) ...[
                                    EditorTimeline(_c),
                                    SizedBox(height: d.px(8)),
                                    EditorTransportRow(_c),
                                    SizedBox(height: d.px(10)),
                                    EditorCutRow(_c),
                                  ] else
                                    NoticeBar.info(
                                      '이 영상은 길이를 읽지 못해 자를 수 없습니다.',
                                      detail: '소리·밝기·회전은 바꿀 수 있습니다.',
                                    ),
                                  SizedBox(height: d.px(12)),
                                  EditorAdjustRow(_c),
                                  SizedBox(height: d.px(6)),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      KeyedSubtree(
                        key: _footerKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(height: d.px(4)),
                            const Divider(height: 1),
                            SizedBox(height: d.px(10)),
                            EditorFooter(
                              c: _c,
                              onPrevious: widget.position > 1
                                  ? () => _navigate(EditorExit.previous)
                                  : null,
                              onNext: widget.position < widget.count
                                  ? () => _navigate(EditorExit.next)
                                  : null,
                              onCancel: _cancel,
                              onApply: _applyAndClose,
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
