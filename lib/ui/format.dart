/// 1:23 또는 1:23.4 (정밀). 한 시간이 넘으면 1:02:03.
String formatClock(double sec, {bool precise = false}) {
  if (sec < 0) sec = 0;
  final tenth = (sec * 10).floor();
  final total = tenth ~/ 10;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final base = h > 0
      ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
      : '$m:${s.toString().padLeft(2, '0')}';
  return precise ? '$base.${tenth % 10}' : base;
}
