/// 유리수 프레임레이트.
///
/// 29.97fps 는 30000/1001, 23.976 은 24000/1001 이다. double 로 보관하면 긴 영상에서
/// 오디오 싱크가 밀린다(1시간에 약 3.6초). 분수 그대로 들고 다니다 ffmpeg 에도 그대로 넘긴다.
class Rational implements Comparable<Rational> {
  final int num;
  final int den;

  const Rational(this.num, this.den);

  static const Rational zero = Rational(0, 1);

  /// NTSC 계열을 포함한 표준 프레임레이트. ffprobe 값이 충분히 가까우면 여기로 스냅한다.
  static const List<Rational> standards = [
    Rational(24000, 1001), // 23.976
    Rational(24, 1),
    Rational(25, 1),
    Rational(30000, 1001), // 29.97
    Rational(30, 1),
    Rational(48, 1),
    Rational(50, 1),
    Rational(60000, 1001), // 59.94
    Rational(60, 1),
    Rational(100, 1),
    Rational(120000, 1001), // 119.88
    Rational(120, 1),
  ];

  /// "30000/1001", "30/1", "29.97" 형태를 받는다.
  static Rational? tryParse(String? s) {
    if (s == null) return null;
    final t = s.trim();
    if (t.isEmpty || t == '0/0' || t == 'N/A') return null;

    if (t.contains('/')) {
      final parts = t.split('/');
      if (parts.length != 2) return null;
      final n = int.tryParse(parts[0].trim());
      final d = int.tryParse(parts[1].trim());
      if (n == null || d == null || d == 0 || n == 0) return null;
      return Rational(n, d).reduced();
    }

    final v = double.tryParse(t);
    if (v == null || v <= 0) return null;
    return fromDouble(v);
  }

  /// 가장 가까운 표준 프레임레이트로 스냅한다. 0.05 이상 차이나면 1/1000 정밀도 분수로 만든다.
  static Rational fromDouble(double v) {
    // 첫 번째로 임계값 안에 드는 걸 고르면 29.97 과 30 처럼 가까운 후보에서
    // 목록 순서에 따라 결과가 달라지므로, 가장 가까운 것을 고른다.
    Rational? best;
    var bestDiff = double.infinity;
    for (final s in standards) {
      final d = (s.toDouble() - v).abs();
      if (d < bestDiff) {
        bestDiff = d;
        best = s;
      }
    }
    if (best != null && bestDiff < 0.05) return best;

    final n = (v * 1000).round();
    return Rational(n, 1000).reduced();
  }

  double toDouble() => den == 0 ? 0 : num / den;

  Rational reduced() {
    if (num == 0) return zero;
    final g = _gcd(num.abs(), den.abs());
    if (g == 0) return this;
    var n = num ~/ g;
    var d = den ~/ g;
    if (d < 0) {
      n = -n;
      d = -d;
    }
    return Rational(n, d);
  }

  static int _gcd(int a, int b) {
    while (b != 0) {
      final t = b;
      b = a % b;
      a = t;
    }
    return a;
  }

  bool get isStandard => standards.any((s) => s == this);

  /// ffmpeg 인자 문자열. 분수 형태를 유지한다.
  String toFFmpegArg() => den == 1 ? '$num' : '$num/$den';

  /// UI 표시용. 29.97p / 30p / 59.94p
  String get label {
    final v = toDouble();
    final rounded = v.roundToDouble();
    if ((v - rounded).abs() < 0.001) return '${rounded.toInt()}p';
    return '${v.toStringAsFixed(2)}p';
  }

  String get detailLabel {
    if (den == 1) return label;
    return '$label ($num/$den)';
  }

  @override
  int compareTo(Rational other) => toDouble().compareTo(other.toDouble());

  @override
  bool operator ==(Object other) {
    if (other is! Rational) return false;
    final a = reduced();
    final b = other.reduced();
    return a.num == b.num && a.den == b.den;
  }

  /// 30000/1001 과 29.97 처럼 표기만 다른 경우를 같게 본다.
  bool closeTo(Rational other) => (toDouble() - other.toDouble()).abs() < 0.01;

  @override
  int get hashCode {
    final r = reduced();
    return Object.hash(r.num, r.den);
  }

  @override
  String toString() => toFFmpegArg();
}
