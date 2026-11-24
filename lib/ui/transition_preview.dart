import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 전환 효과 맛보기. 앞 장면 → 효과 → 뒤 장면을 반복한다.
///
/// 그림은 `tool/make_transition_previews.py` 가 실제 결과물과 같은 ffmpeg
/// 필터로 미리 그려 둔 것이다(`assets/transitions/<효과>.jpg`, 6×6 격자 36장).
/// 각 장은 시간이 아니라 전환 진행 정도(0%→100%)라서, [transitionSeconds] 에
/// 맞춰 넘기는 속도만 바꾸면 고른 '길이'와 똑같은 빠르기로 보인다.
/// 실행 중에 영상을 만들지 않으므로 바로 뜨고 느린 PC 에서도 끊기지 않는다.
///
/// [animate] 가 false 면 전환 도중 장면을 정지 사진으로 보여 준다.
/// 카드 8개가 한꺼번에 움직이면 정신이 없어서, 고른 것과 마우스를 올린 것만 움직인다.
class TransitionPreview extends StatefulWidget {
  /// 자산 파일 이름(효과 이름). 예: 'dissolve'
  final String asset;
  final bool animate;
  final double width;

  /// 눈에 보이는 전환 전체 길이(초). 실제 결과물과 같게 넘긴다.
  final double transitionSeconds;

  const TransitionPreview({
    super.key,
    required this.asset,
    required this.animate,
    required this.width,
    this.transitionSeconds = 1.0,
  });

  static const int cols = 6;
  static const int rows = 6;
  static const int frames = cols * rows;

  /// 전환 앞뒤로 멈춰 보여 주는 시간.
  static const int holdBeforeMs = 600;
  static const int holdAfterMs = 1100;

  /// 정지했을 때 보여 줄 장면(진행 약 30%. 더 가면 다가가며 넘기기가 지붕만 보인다).
  static const int stillFrame = 10;

  /// 반복 한 바퀴 안의 시각 → 그릴 장 번호.
  static int frameAt(int ms, double transitionSeconds) {
    final transMs = (transitionSeconds * 1000).round().clamp(1, 60000);
    final loopMs = holdBeforeMs + transMs + holdAfterMs;
    final t = ms % loopMs - holdBeforeMs;
    if (t <= 0) return 0;
    if (t >= transMs) return frames - 1;
    return (t * (frames - 1) / transMs).round();
  }

  @override
  State<TransitionPreview> createState() => _TransitionPreviewState();
}

class _TransitionPreviewState extends State<TransitionPreview>
    with SingleTickerProviderStateMixin {
  ui.Image? _sheet;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  late final Ticker _ticker;
  int _frame = TransitionPreview.stillFrame;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
    _syncTicker();
  }

  @override
  void didUpdateWidget(TransitionPreview old) {
    super.didUpdateWidget(old);
    if (old.asset != widget.asset) _load();
    if (old.animate != widget.animate) _syncTicker();
    // 길이를 바꾸면 처음부터 다시 보여 준다(바뀐 빠르기가 바로 눈에 들어오게).
    if (old.transitionSeconds != widget.transitionSeconds && _ticker.isActive) {
      _ticker
        ..stop()
        ..start();
    }
  }

  void _load() {
    final stream = AssetImage('assets/transitions/${widget.asset}.jpg')
        .resolve(createLocalImageConfiguration(context));
    if (_stream?.key == stream.key) return;
    _unlisten();
    _listener = ImageStreamListener((info, _) {
      if (!mounted) return;
      setState(() => _sheet = info.image);
    });
    stream.addListener(_listener!);
    _stream = stream;
  }

  void _unlisten() {
    final l = _listener;
    if (l != null) _stream?.removeListener(l);
    _listener = null;
  }

  void _syncTicker() {
    if (widget.animate && !_ticker.isActive) {
      _ticker.start();
    } else if (!widget.animate && _ticker.isActive) {
      _ticker.stop();
      setState(() => _frame = TransitionPreview.stillFrame);
    }
  }

  void _onTick(Duration elapsed) {
    final f = TransitionPreview.frameAt(
        elapsed.inMilliseconds, widget.transitionSeconds);
    if (f != _frame) setState(() => _frame = f);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _unlisten();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.width * 9 / 16;
    final sheet = _sheet;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: widget.width,
        height: h,
        child: sheet == null
            ? const ColoredBox(color: Color(0xFF11151A))
            : CustomPaint(painter: _FramePainter(sheet, _frame)),
      ),
    );
  }
}

class _FramePainter extends CustomPainter {
  final ui.Image sheet;
  final int frame;

  _FramePainter(this.sheet, this.frame);

  @override
  void paint(Canvas canvas, Size size) {
    final fw = sheet.width / TransitionPreview.cols;
    final fh = sheet.height / TransitionPreview.rows;
    final src = Rect.fromLTWH(
      (frame % TransitionPreview.cols) * fw,
      (frame ~/ TransitionPreview.cols) * fh,
      fw,
      fh,
    );
    canvas.drawImageRect(sheet, src, Offset.zero & size,
        Paint()..filterQuality = FilterQuality.medium);
  }

  @override
  bool shouldRepaint(_FramePainter old) =>
      old.frame != frame || !identical(old.sheet, sheet);
}
