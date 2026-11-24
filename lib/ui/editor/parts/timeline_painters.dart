import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../format.dart';

/// 눈금 숫자. 막대 폭에 맞춰 5~9칸으로 나눈다.
class RulerPainter extends CustomPainter {
  final double duration;
  final double fontSize;
  final Color color;

  RulerPainter({
    required this.duration,
    required this.fontSize,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (duration <= 0) return;
    final line = Paint()
      ..color = color.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    final n = (size.width / (fontSize * 7)).floor().clamp(2, 10);
    for (var i = 0; i <= n; i++) {
      final x = size.width * i / n;
      canvas.drawLine(
        Offset(x, size.height * 0.55),
        Offset(x, size.height),
        line,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: formatClock(duration * i / n),
          style: TextStyle(
            fontSize: fontSize,
            color: color,
            fontFamily: 'Segoe UI',
            fontFamilyFallback: const ['Malgun Gothic'],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      var tx = x + 3;
      if (i == n) tx = x - tp.width - 3;
      tp.paint(canvas, Offset(tx, 1));
    }
  }

  @override
  bool shouldRepaint(RulerPainter old) =>
      old.duration != duration || old.fontSize != fontSize;
}

/// 소리 파형. 말소리가 어디서 시작하고 끝나는지 눈으로 보인다.
class WavePainter extends CustomPainter {
  final List<double> peaks;

  WavePainter(this.peaks);

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty || size.width <= 0) return;
    final paint = Paint()
      ..color = const Color(0xFF6FD08C)
      ..strokeWidth = 1;
    final mid = size.height / 2;
    final cols = size.width.floor();
    for (var x = 0; x < cols; x++) {
      // 한 픽셀이 여러 칸을 덮으면 그중 가장 큰 값을 쓴다.
      final i0 = (x * peaks.length / cols).floor();
      final i1 = (((x + 1) * peaks.length / cols).ceil()).clamp(
        i0 + 1,
        peaks.length,
      );
      var v = 0.0;
      for (var i = i0; i < i1; i++) {
        if (peaks[i] > v) v = peaks[i];
      }
      // 작은 소리도 보이도록 살짝 키운다(제곱근).
      final hgt = (v <= 0 ? 0.0 : math.sqrt(v)) * (mid - 1);
      canvas.drawLine(
        Offset(x + 0.5, mid - hgt - 0.5),
        Offset(x + 0.5, mid + hgt + 0.5),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(WavePainter old) => !identical(old.peaks, peaks);
}
