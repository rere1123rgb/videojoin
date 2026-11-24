import '../../engine/models.dart';

/// 편집 화면에서 다루는 조각. 가위로 자른 한 칸이다.
class EditPiece {
  final double start;
  final double end;
  final bool keep;

  const EditPiece(this.start, this.end, this.keep);

  double get length => end - start;
  bool contains(double t) => t >= start && t < end;
  EditPiece withKeep(bool k) => EditPiece(start, end, k);
}

/// 조각 목록을 다루는 순수 로직. 화면과 떼어 두어 따로 시험할 수 있다.
///
/// 앞뒤 자르기도 중간 잘라내기도 "자르고 조각을 뺀다"는 한 방식으로 처리한다.
class EditPieces {
  final double duration;
  final List<EditPiece> pieces;

  EditPieces(this.duration, this.pieces);

  /// 저장된 편집(남길 구간)으로부터 조각을 되살린다.
  factory EditPieces.fromKeep(double duration, List<TimeRange> keep) {
    if (keep.isEmpty) {
      return EditPieces(duration, [EditPiece(0, duration, true)]);
    }
    final out = <EditPiece>[];
    var t = 0.0;
    for (final r in keep) {
      if (r.start > t + 0.001) out.add(EditPiece(t, r.start, false));
      out.add(EditPiece(r.start, r.end, true));
      t = r.end;
    }
    if (t < duration - 0.001) out.add(EditPiece(t, duration, false));
    return EditPieces(duration, out);
  }

  /// 남길 구간. 전부 남기면 빈 목록(= 자르지 않음).
  List<TimeRange> toKeep() {
    if (pieces.every((p) => p.keep)) return const [];
    return normalizeRanges([
      for (final p in pieces.where((p) => p.keep)) TimeRange(p.start, p.end),
    ], duration: duration);
  }

  double get keptDuration =>
      pieces.where((p) => p.keep).fold<double>(0, (s, p) => s + p.length);

  int indexAt(double t) {
    for (var i = 0; i < pieces.length; i++) {
      if (pieces[i].contains(t)) return i;
    }
    return pieces.length - 1;
  }

  /// 자른 자리들(조각 경계). 화면에 가위 표시를 그릴 때 쓴다.
  List<double> get cutPoints => [
    for (var i = 1; i < pieces.length; i++) pieces[i].start,
  ];

  /// [t] 에서 자른다. 경계에 너무 가까우면(0.5초 이내) 부스러기 조각이 생기므로
  /// 자르지 않는다. [t] 를 시작으로 하는 조각의 번호를 돌려준다(못 잘랐으면 null).
  int? cutAt(double t) {
    final i = indexAt(t);
    final p = pieces[i];
    if (t - p.start < kMinRangeSec || p.end - t < kMinRangeSec) return null;
    pieces
      ..removeAt(i)
      ..insertAll(i, [
        EditPiece(p.start, t, p.keep),
        EditPiece(t, p.end, p.keep),
      ]);
    return i + 1;
  }

  void toggleAt(double t) {
    final i = indexAt(t);
    pieces[i] = pieces[i].withKeep(!pieces[i].keep);
  }

  /// [t] 앞은 버리고 여기서부터 쓴다.
  void startHere(double t) {
    final cut = cutAt(t);
    final from = cut ?? indexAt(t);
    for (var i = 0; i < pieces.length; i++) {
      if (i < from) pieces[i] = pieces[i].withKeep(false);
    }
    pieces[from] = pieces[from].withKeep(true);
  }

  /// [t] 까지만 쓰고 뒤는 버린다.
  void endHere(double t) {
    final cut = cutAt(t);
    // 잘렸으면 t 앞 조각이 cut-1, 못 잘랐으면 t 가 속한 조각까지 쓴다.
    final last = cut != null ? cut - 1 : indexAt(t);
    for (var i = 0; i < pieces.length; i++) {
      if (i > last) pieces[i] = pieces[i].withKeep(false);
    }
    pieces[last] = pieces[last].withKeep(true);
  }

  /// 같은 상태(둘 다 남김/둘 다 뺌)로 맞닿은 조각은 다시 붙인다.
  void mergeSame() {
    final out = <EditPiece>[];
    for (final p in pieces) {
      if (out.isNotEmpty && out.last.keep == p.keep) {
        out[out.length - 1] = EditPiece(out.last.start, p.end, p.keep);
      } else {
        out.add(p);
      }
    }
    pieces
      ..clear()
      ..addAll(out);
  }

  /// [a]~[b] 구간을 통째로 남기거나([keep] true) 뺀다.
  /// 끌어서 고른 구간에 쓴다. 조각 경계와 무관하다.
  void setRange(double a, double b, bool keep) {
    final lo = (a < b ? a : b).clamp(0.0, duration);
    final hi = (a < b ? b : a).clamp(0.0, duration);
    if (hi - lo <= 0) return;
    final out = <EditPiece>[];
    for (final p in pieces) {
      if (p.end <= lo || p.start >= hi) {
        out.add(p);
        continue;
      }
      if (p.start < lo) out.add(EditPiece(p.start, lo, p.keep));
      out.add(
        EditPiece(p.start > lo ? p.start : lo, p.end < hi ? p.end : hi, keep),
      );
      if (p.end > hi) out.add(EditPiece(hi, p.end, p.keep));
    }
    pieces
      ..clear()
      ..addAll(out);
    mergeSame();
    _absorbSlivers();
  }

  /// 0.5초가 안 되는 부스러기 조각은 옆 조각에 붙인다(결과물에서는 버려지는 길이).
  void _absorbSlivers() {
    var changed = true;
    while (changed && pieces.length > 1) {
      changed = false;
      for (var i = 0; i < pieces.length; i++) {
        if (pieces[i].length >= kMinRangeSec) continue;
        final neighbour = i > 0 ? pieces[i - 1] : pieces[i + 1];
        pieces[i] = pieces[i].withKeep(neighbour.keep);
        mergeSame();
        changed = true;
        break;
      }
    }
  }

  EditPieces copy() => EditPieces(duration, List.of(pieces));
}
