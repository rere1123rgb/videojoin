import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// 한글을 조합하는 동안 커서를 글자 **뒤**에 그려 주는 포장 위젯.
///
/// ## 무슨 문제인가
///
/// 윈도우용 Flutter 엔진의 `FlutterWindow::OnImeComposition` 은
/// `GCS_CURSORPOS` 가 lparam 에 들어 있는지 보지 않고
/// `ImmGetCompositionString(..., GCS_CURSORPOS, ...)` 을 그대로 읽는다.
/// 한글 IME 는 이 값을 보고하지 않아서 0 이 돌아오고, 그 0 이 "조합 구간의
/// 시작"으로 해석돼 커서가 조합 중인 글자 앞에 그려진다. '테' 를 치면 커서가
/// 맨 앞에, '테스트용' 까지 치면 '트' 와 '용' 사이에 남는 증상이다.
/// 글자 자체는 멀쩡하게 들어간다 — 틀린 것은 커서가 그려지는 자리뿐이다.
///
/// 업스트림 수정(flutter/flutter#186353)은 아직 stable 에 들어오지 않았다.
///
/// ## 값을 고치면 안 된다
///
/// 컨트롤러 값의 커서 위치를 조합 구간 끝으로 **바꾸면** 글자가 망가진다.
/// Flutter 가 바뀐 값을 엔진으로 도로 보내는데(`setEditingState`), 엔진은 그
/// 순간 조합 상태를 잃어 다음 글쇠부터 새 글자로 끼어들기 때문이다.
///
/// 그래서 **값에는 절대 손대지 않는다.** 대신 그리는 것만 바꾼다:
/// 엔진이 잘못된 자리를 보낸 동안에는 진짜 커서를 투명하게 숨기고,
/// 조합 구간 끝에 커서 모양을 따로 그린다.
///
/// 엔진이 고쳐지면 "잘못된 자리"라는 조건이 성립하지 않으므로 이 위젯은
/// 아무 일도 하지 않게 된다.
///
/// 쓰는 법 — [builder] 가 넘겨주는 색을 `TextField.cursorColor` 에 그대로 준다:
///
/// ```dart
/// HangulCaretFix(
///   controller: c,
///   builder: (context, cursorColor) =>
///       TextField(controller: c, cursorColor: cursorColor),
/// )
/// ```
class HangulCaretFix extends StatefulWidget {
  final TextEditingController controller;

  /// [cursorColor] 는 평소에는 null(기본 색), 진짜 커서를 숨겨야 할 때는 투명.
  final Widget Function(BuildContext context, Color? cursorColor) builder;

  const HangulCaretFix({
    super.key,
    required this.controller,
    required this.builder,
  });

  /// 대신 그린 커서를 테스트에서 찾기 위한 열쇠.
  static const Key caretKey = ValueKey('hangul-caret-overlay');

  @override
  State<HangulCaretFix> createState() => _HangulCaretFixState();
}

class _HangulCaretFixState extends State<HangulCaretFix> {
  /// 대신 그릴 커서의 자리(이 위젯 기준). null 이면 그리지 않는다.
  Rect? _caret;
  bool _misplaced = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onValue);
  }

  @override
  void didUpdateWidget(HangulCaretFix old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onValue);
      widget.controller.addListener(_onValue);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onValue);
    super.dispose();
  }

  void _onValue() {
    final v = widget.controller.value;
    _trace(v);

    final bad = caretIsMisplaced(v);
    if (!bad) {
      if (_misplaced || _caret != null) {
        _update(() {
          _misplaced = false;
          _caret = null;
        });
      }
      return;
    }

    // 새 글자가 배치된 뒤라야 자리를 잴 수 있다. 그때까지는 진짜 커서만
    // 먼저 숨겨 둔다 — 틀린 자리에서 한 프레임 깜빡이는 것을 막는다.
    if (!_misplaced) _update(() => _misplaced = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  /// 화면을 그리는 도중에 컨트롤러 값이 바뀌는 경우가 있다(부모가 build 안에서
  /// 입력칸 글자를 맞춰 넣을 때). 그 순간 setState 를 부르면 터지므로
  /// 그럴 때는 이번 프레임이 끝난 뒤로 미룬다.
  void _update(VoidCallback change) {
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(change);
      });
    } else {
      setState(change);
    }
  }

  void _measure() {
    if (!mounted) return;
    final v = widget.controller.value;
    if (!caretIsMisplaced(v)) return;

    Rect? rect;
    try {
      final box = context.findRenderObject();
      final editable = _findEditable(box);
      if (box is RenderBox && editable != null && editable.hasSize) {
        final local = editable.getLocalRectForCaret(
          TextPosition(offset: v.composing.end),
        );
        final origin = editable.localToGlobal(local.topLeft, ancestor: box);
        rect = origin & local.size;
      }
    } on Object {
      // 재지 못하면 커서를 숨긴 채로 둔다. 밑줄 친 조합 글자가 자리를 알려 준다.
      rect = null;
    }

    if (rect != _caret) setState(() => _caret = rect);
  }

  static RenderEditable? _findEditable(RenderObject? root) {
    if (root == null) return null;
    if (root is RenderEditable) return root;
    RenderEditable? found;
    root.visitChildren((child) {
      found ??= _findEditable(child);
    });
    return found;
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.builder(
      context,
      _misplaced ? Colors.transparent : null,
    );
    final caret = _misplaced ? _caret : null;

    final color =
        Theme.of(context).textSelectionTheme.cursorColor ??
        Theme.of(context).colorScheme.primary;

    // 커서를 그리지 않을 때도 **언제나 같은 모양(Stack)** 으로 돌려준다.
    // 그릴 때만 Stack 으로 감싸면 입력칸이 트리에서 자리를 옮기게 되고,
    // Flutter 는 그것을 새 입력칸으로 보아 포커스와 조합을 날려 버린다.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        if (caret != null)
          Positioned(
            left: caret.left,
            top: caret.top,
            // 입력을 가로채지 않게 한다. 눌리는 건 아래의 입력칸이어야 한다.
            child: IgnorePointer(
              child: Container(
                key: HangulCaretFix.caretKey,
                width: 2,
                height: caret.height,
                color: color,
              ),
            ),
          ),
      ],
    );
  }
}

/// 엔진이 커서를 조합 구간의 **시작**에 놓았는가 — 고쳐 그려야 하는 상태인가.
///
/// 조합 도중 커서를 직접 옮기는 경우(주로 일본어·중국어 IME)는 건드리지
/// 않도록, 커서가 정확히 시작 위치에 있을 때만 참이다.
bool caretIsMisplaced(TextEditingValue v) {
  final composing = v.composing;
  if (!composing.isValid || composing.isCollapsed) return false;

  final sel = v.selection;
  // 글자를 범위로 고르고 있는 중이면 해당 없음.
  if (!sel.isValid || !sel.isCollapsed) return false;
  if (sel.baseOffset != composing.start) return false;

  // 엔진이 보낸 값이 어긋나 있으면 손대지 않는다.
  return composing.end <= v.text.length;
}

/// 진단용 기록. 환경 변수 `VIDEOJOIN_IME_LOG` 에 파일 경로를 주고 띄웠을
/// 때만 켜진다. 평소에는 아무 일도 하지 않는다.
///
/// 입력칸에 들어온 값을 한 줄씩 남겨 조합이 끊기지 않았는지 확인할 수 있다.
/// 글자는 코드포인트로 적는다 — 콘솔 인코딩(CP949)에 따른 깨짐을 피하려는 것이다.
final String? _tracePath = Platform.environment['VIDEOJOIN_IME_LOG'];

void _trace(TextEditingValue v) {
  final path = _tracePath;
  if (path == null || path.isEmpty) return;
  try {
    final cps = v.text.runes
        .map((r) => r.toRadixString(16).toUpperCase().padLeft(4, '0'))
        .join(' ');
    File(path).writeAsStringSync(
      'len=${v.text.length} '
      'composing=${v.composing.start}..${v.composing.end} '
      'caret=${v.selection.baseOffset} '
      'misplaced=${caretIsMisplaced(v)} '
      'text=[$cps]\n',
      mode: FileMode.append,
      flush: true,
    );
  } on Object {
    // 기록에 실패해도 입력은 계속돼야 한다.
  }
}
