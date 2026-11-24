import 'executor.dart';
import 'models.dart';
import 'planner.dart';

/// 겹치기 전환(디졸브·밀어내기 등) 계획과 ffmpeg 인자.
///
/// ## 구조
/// 이음매마다 앞 조각(몸통 A) · 전환 조각 · 뒤 조각(몸통 B) 세 토막이 된다.
/// 전환 조각은 A 의 마지막 d 초와 B 의 처음 d 초를 xfade 로 섞은 d 초짜리다.
/// 몸통은 그만큼 짧아진다(양쪽 이음매가 있으면 앞뒤 모두).
/// 그래서 결과물 길이 = 남긴 구간 합 − (전환 수 × d).

/// 몸통에 남겨야 하는 최소 길이. 이보다 짧아지면 그 이음매는 전환 없이 그냥 자른다.
const double kMinBodySec = 0.5;

/// 한 이음매의 전환 조각이 읽을 두 입력.
class TransitionJoin {
  /// 뒤 영상(앞 영상은 [SegmentUnit.clip]).
  final ClipItem clipB;
  final int clipIndexB;

  /// A 의 마지막 d 초, B 의 처음 d 초.
  final TimeRange rangeA;
  final TimeRange rangeB;
  final TransitionStyle style;

  /// 겹치는 길이(초). 출력 프레임에 맞춰 반올림한 값.
  final double d;

  const TransitionJoin({
    required this.clipB,
    required this.clipIndexB,
    required this.rangeA,
    required this.rangeB,
    required this.style,
    required this.d,
  });
}

bool overlapActive(OutputSettings s) =>
    !s.lossless && s.smoothTransitions && s.transitionStyle.isOverlap;

/// 겹치는 길이(초): 길이 값의 2배를 출력 프레임 수로 반올림한 값.
/// 겹치기 전환이 아니면 0.
double overlapSeconds(OutputSettings s) {
  if (!overlapActive(s)) return 0;
  final fps = s.frameRate.toDouble();
  final want = s.transitionLength.seconds * 2;
  if (fps <= 0) return want;
  final frames = (want * fps).round();
  return frames < 1 ? 1 / fps : frames / fps;
}

/// 구간 길이들 사이사이(i 와 i+1)에 전환을 넣을지 정한다.
///
/// 왼쪽부터 차례로 정한다: 몸통 i 는 (앞 이음매가 있었다면 d) + d 를 내어주고도
/// [kMinBodySec] 이상 남아야 하고, 다음 구간도 최소 d + [kMinBodySec] 이어야 한다.
/// 어느 쪽이든 모자라면 그 이음매는 그냥 자른다. 순서만으로 결정되므로
/// 이어하기(.done)에서도 같은 조각 목록이 나온다.
List<bool> planSeams(List<double> durations, double d) {
  final n = durations.length;
  final seams = List<bool>.filled(n < 2 ? 0 : n - 1, false);
  if (d <= 0) return seams;
  var incoming = false;
  for (var k = 0; k < n - 1; k++) {
    final left = durations[k] - (incoming ? d : 0) - d;
    final nextOk = durations[k + 1] - d >= kMinBodySec;
    final ok = left >= kMinBodySec - 1e-9 && nextOk;
    seams[k] = ok;
    incoming = ok;
  }
  return seams;
}

List<({ClipItem clip, int clipIndex, TimeRange range, bool trimmed})>
    flattenRanges(List<ClipItem> clips) {
  final out = <({ClipItem clip, int clipIndex, TimeRange range, bool trimmed})>[];
  for (var i = 0; i < clips.length; i++) {
    final c = clips[i];
    for (final r in c.ranges) {
      out.add((clip: c, clipIndex: i, range: r, trimmed: c.edit.isTrimmed));
    }
  }
  return out;
}

double _rangeSec(
    ({ClipItem clip, int clipIndex, TimeRange range, bool trimmed}) r) =>
    r.trimmed ? r.range.length : r.clip.spec.durationSec;

/// 결과물 전체 길이. 겹치기 전환이 아니면 남긴 구간의 합 그대로.
/// 계획·진행률·예상 용량·목록 요약이 모두 이 함수 하나를 쓴다.
double outputDurationFor(List<ClipItem> clips, OutputSettings s) {
  final valid = clips.where((c) => c.spec.ok).toList();
  final sum = valid.fold<double>(0, (a, c) => a + c.effectiveDuration);
  final d = overlapSeconds(s);
  if (d <= 0) return sum;
  final seams = planSeams(flattenRanges(valid).map(_rangeSec).toList(), d);
  return sum - seams.where((x) => x).length * d;
}

/// 겹치기 전환용 조각 목록(몸통 · 전환 · 몸통 …).
List<SegmentUnit> buildOverlapUnits(List<ClipItem> clips, OutputSettings s) {
  final raw = flattenRanges(clips);
  final d = overlapSeconds(s);
  final seams = planSeams(raw.map(_rangeSec).toList(), d);
  final fadeSec = s.transitionLength.seconds;
  final endsDip = s.transitionStyle.endsDip;
  final out = <SegmentUnit>[];

  for (var k = 0; k < raw.length; k++) {
    final r = raw[k];
    final inT = k > 0 && seams[k - 1];
    final outT = k < raw.length - 1 && seams[k];
    final full = _rangeSec(r);
    final start = r.range.start;
    final bodyStart = start + (inT ? d : 0);
    final bodyEnd = start + full - (outT ? d : 0);
    final shortened = inT || outT;
    final body = shortened ? TimeRange(bodyStart, bodyEnd) : r.range;
    final bodyLen = shortened ? body.length : full;

    // 맨 처음·끝 서서히 여부는 거치기 방식과 같게 원래 구간 길이로 판단한다
    // (깎인 몸통 기준이면 효과 종류에 따라 결과가 달라진다). 단 페이드가
    // 몸통 안에서 끝나야 하므로 몸통도 페이드 길이 이상이어야 한다.
    final canFade = full >= fadeSec * 3 && bodyLen >= fadeSec;
    out.add(SegmentUnit(
      clip: r.clip,
      clipIndex: r.clipIndex,
      range: body,
      trimmed: r.trimmed || shortened,
      fadeIn: k == 0 && s.fadeEnds && canFade,
      fadeOut: k == raw.length - 1 && s.fadeEnds && canFade,
      fadeSec: fadeSec,
      fadeColor: endsDip,
    ));

    if (outT) {
      final nx = raw[k + 1];
      final aEnd = start + full;
      out.add(SegmentUnit(
        clip: r.clip,
        clipIndex: r.clipIndex,
        range: TimeRange(aEnd - d, aEnd),
        trimmed: true,
        join: TransitionJoin(
          clipB: nx.clip,
          clipIndexB: nx.clipIndex,
          rangeA: TimeRange(aEnd - d, aEnd),
          rangeB: TimeRange(nx.range.start, nx.range.start + d),
          style: s.transitionStyle,
          d: d,
        ),
      ));
    }
  }
  return out;
}

String _t(double v) => v.toStringAsFixed(3);

/// 전환 조각 하나를 만드는 ffmpeg 인자. 입력 두 개(각각 -ss/-t 로 d 초만),
/// 소리 없는 영상에는 무음 입력을 뒤에 붙인다.
///
/// 영상: 각자 몸통과 같은 정규화 체인을 거친 뒤 xfade(offset=0, duration=d).
/// 소리: 각자 d 초로 맞추고(apad+atrim) 페이드 아웃/인 후 amix 로 더한다.
/// acrossfade 는 출력이 짧아져서 쓰지 않는다.
List<String> transitionArgs(
  SegmentUnit unit,
  OutputSettings s,
  String outPath, {
  required String encoder,
}) {
  final j = unit.join!;
  final a = unit.clip;
  final b = j.clipB;
  final d = j.d;
  final ds = _t(d);

  final args = <String>[
    '-hide_banner', '-nostdin', '-y', '-progress', 'pipe:1',
    '-ss', _t(j.rangeA.start), '-t', ds, '-i', a.spec.path,
    '-ss', _t(j.rangeB.start), '-t', ds, '-i', b.spec.path,
  ];

  // 무음 입력 번호는 두 영상 입력(0, 1) 다음부터 필요한 순서대로.
  var next = 2;
  String audioIn(ClipItem c, int videoInput) {
    if (c.spec.hasAudio) return '$videoInput:a:0';
    args.addAll([
      '-f', 'lavfi', '-t', ds,
      '-i', 'anullsrc=channel_layout=stereo:sample_rate=48000',
    ]);
    return '${next++}:a:0';
  }

  final inA = audioIn(a, 0);
  final inB = audioIn(b, 1);

  String audioChain(ClipItem c, String input, String fade, String label) {
    final af = Executor.buildAudioFilter(c);
    return '[$input]aresample=48000,aformat=channel_layouts=stereo,'
        '${af.isEmpty ? '' : '$af,'}apad,atrim=0:$ds,'
        'afade=t=$fade:st=0:d=$ds[$label]';
  }

  final filter = [
    '[0:v:0]${Executor.buildFilterChain(a, s)}[va]',
    '[1:v:0]${Executor.buildFilterChain(b, s)}[vb]',
    '[va][vb]xfade=transition=${j.style.xfade}:duration=$ds:offset=0[v]',
    audioChain(a, inA, 'out', 'aa'),
    audioChain(b, inB, 'in', 'ab'),
    '[aa][ab]amix=inputs=2:normalize=0:duration=longest[a]',
  ].join(';');

  args.addAll(['-filter_complex', filter, '-map', '[v]', '-map', '[a]']);
  args.addAll(Executor.videoEncodeArgs(encoder, s));
  args.addAll([
    '-c:a', 'aac',
    '-b:a', '${(s.audioBitrate / 1000).round()}k',
    '-ar', '48000',
    '-ac', '2',
    '-r', s.frameRate.toFFmpegArg(),
    '-video_track_timescale', '90000',
    '-f', 'mpegts', outPath,
  ]);
  return args;
}
