import 'dart:io';

import 'package:path/path.dart' as p;

import 'rational.dart';

/// 지원하는 입력 확장자.
const kSupportedExtensions = <String>{
  '.mp4', '.avi', '.mov', '.mkv', '.wmv', '.m4v', '.mpg', '.mpeg',
  '.mts', '.m2ts', '.ts', '.flv', '.webm', '.3gp', '.vob', '.asf', '.divx',
};

bool isVideoFile(String path) =>
    kSupportedExtensions.contains(p.extension(path).toLowerCase());

/// ffprobe 로 읽어낸 영상 한 개의 실측 스펙.
class VideoSpec {
  final String path;
  final int fileSize;
  final DateTime fileModified;

  /// 파일 생성 시각 (Windows 에서 Dart 의 FileStat.changed 는 creation time 이다).
  final DateTime fileCreated;

  /// 컨테이너에 박힌 촬영 시각. 메신저로 전달된 파일에는 없다.
  final DateTime? metaCreationTime;

  final bool ok;
  final String? errorMessage;

  /// 회전 메타데이터를 적용하기 *전* 의 값 (ffprobe 원값).
  final int rawWidth;
  final int rawHeight;

  /// 컨테이너 회전 메타데이터 (0/90/180/270). 세로 촬영 폰 영상은 raw 가 1920×1080 이고
  /// rotation 이 90 이다. ffmpeg 은 기본으로 자동 적용(autorotate)한다.
  final int containerRotation;

  final Rational frameRate; // avg_frame_rate 기준
  final Rational rFrameRate; // r_frame_rate 기준
  final bool isVfr;
  final double durationSec;
  final String videoCodec;
  final String pixFmt;
  final int? videoStreamBitrate;
  final int? formatBitrate;

  /// 픽셀 종횡비(SAR). 옛 DV/DVD 영상은 아나모픽이라 1:1 이 아니다
  /// (720×480, SAR 32:27 은 약 854×480). 무시하면 그 구간만 찌그러진다.
  final int sarNum;
  final int sarDen;

  final String? colorTransfer;
  final String? colorPrimaries;
  final String? colorSpace;

  final bool hasAudio;
  final String? audioCodec;
  final int? audioSampleRate;
  final int? audioChannels;
  final int? audioBitrate;

  const VideoSpec({
    required this.path,
    required this.fileSize,
    required this.fileModified,
    required this.fileCreated,
    this.metaCreationTime,
    this.ok = true,
    this.errorMessage,
    this.rawWidth = 0,
    this.rawHeight = 0,
    this.containerRotation = 0,
    this.frameRate = const Rational(30, 1),
    this.rFrameRate = const Rational(30, 1),
    this.isVfr = false,
    this.durationSec = 0,
    this.videoCodec = '',
    this.pixFmt = '',
    this.videoStreamBitrate,
    this.formatBitrate,
    this.sarNum = 1,
    this.sarDen = 1,
    this.colorTransfer,
    this.colorPrimaries,
    this.colorSpace,
    this.hasAudio = false,
    this.audioCodec,
    this.audioSampleRate,
    this.audioChannels,
    this.audioBitrate,
  });

  factory VideoSpec.failed(String path, String message) {
    DateTime mod = DateTime.now();
    DateTime created = DateTime.now();
    int size = 0;
    try {
      final st = File(path).statSync();
      mod = st.modified;
      created = st.changed;
      size = st.size;
    } on Object {
      // 파일을 못 읽으면 기본값을 쓴다.
    }
    return VideoSpec(
      path: path,
      fileSize: size,
      fileModified: mod,
      fileCreated: created,
      ok: false,
      errorMessage: message,
    );
  }

  String get fileName => p.basename(path);

  bool get _rotSwaps => containerRotation == 90 || containerRotation == 270;

  bool get hasNonSquarePixels => sarNum != sarDen && sarNum > 0 && sarDen > 0;

  int get _squaredWidth {
    if (!hasNonSquarePixels) return rawWidth;
    final w = (rawWidth * sarNum / sarDen).round();
    return w.isEven ? w : w + 1;
  }

  /// 회전과 SAR 을 모두 적용한 화면 표시 크기. UI 와 Planner 는 항상 이 값을 기준으로 한다.
  int get displayWidth => _rotSwaps ? rawHeight : _squaredWidth;
  int get displayHeight => _rotSwaps ? _squaredWidth : rawHeight;

  bool get isPortrait => displayHeight > displayWidth;

  /// HDR 은 톤매핑 없이 SDR 로 인코딩하면 색이 빠져 뿌옇게 나온다.
  bool get isHdr {
    final t = colorTransfer;
    return t == 'smpte2084' || t == 'arib-std-b67';
  }

  String get hdrKind {
    if (colorTransfer == 'smpte2084') return 'HDR10';
    if (colorTransfer == 'arib-std-b67') return 'HLG';
    return '';
  }

  /// 영상 트랙 비트레이트(bps) 추정. 스트림 값이 없으면 컨테이너 전체에서 오디오 몫을 뺀다.
  int get estimatedVideoBitrate {
    if (videoStreamBitrate != null && videoStreamBitrate! > 0) {
      return videoStreamBitrate!;
    }
    final audio = audioBitrate ?? (hasAudio ? 128000 : 0);
    if (formatBitrate != null && formatBitrate! > 0) {
      final v = formatBitrate! - audio;
      if (v > 0) return v;
    }
    if (durationSec > 0.1 && fileSize > 0) {
      final total = (fileSize * 8 / durationSec).round();
      final v = total - audio;
      if (v > 0) return v;
    }
    return 0;
  }

  /// 컨테이너 전체 비트레이트(bps).
  int get totalBitrate {
    if (formatBitrate != null && formatBitrate! > 0) return formatBitrate!;
    if (durationSec > 0.1 && fileSize > 0) {
      return (fileSize * 8 / durationSec).round();
    }
    return 0;
  }

  /// "만든 날짜" 정렬 기준. 촬영 메타데이터가 없으면 파일 생성일로 폴백한다.
  DateTime get createdDate => metaCreationTime ?? fileCreated;

  /// 파일 생성일로 폴백했는지.
  bool get createdDateIsFallback => metaCreationTime == null;

  /// 무손실 이어붙이기 가능 여부 비교 키. 하나라도 다르면 불가능하다.
  String get concatCompatKey => [
        videoCodec,
        displayWidth,
        displayHeight,
        pixFmt,
        '$sarNum:$sarDen',
        frameRate.reduced().toFFmpegArg(),
        hasAudio ? (audioCodec ?? '') : 'noaudio',
        audioSampleRate ?? 0,
        audioChannels ?? 0,
        colorTransfer ?? '',
      ].join('|');
}

/// 영상 안의 한 구간(초).
class TimeRange {
  final double start;
  final double end;

  const TimeRange(this.start, this.end);

  double get length => end - start;

  bool contains(double t) => t >= start && t < end;

  Map<String, dynamic> toJson() => {'s': start, 'e': end};

  static TimeRange? fromJson(Object? o) {
    if (o is! Map) return null;
    final rs = o['s'];
    final re = o['e'];
    final s = rs is num ? rs.toDouble() : null;
    final e = re is num ? re.toDouble() : null;
    if (s == null || e == null || e <= s) return null;
    return TimeRange(s, e);
  }

  @override
  bool operator ==(Object other) =>
      other is TimeRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'TimeRange($start, $end)';
}

/// 소리 크기 단계.
enum VolumeLevel {
  mute('소리 끄기', 0.0),
  low('작게', 0.5),
  normal('원래대로', 1.0),
  high('크게', 1.6),
  max('아주 크게', 2.5);

  final String label;
  final double gain;
  const VolumeLevel(this.label, this.gain);
}

/// 밝기 단계. brightness 는 검은색까지 떠서 뿌옇게 되므로 중간 밝기만 올리는 감마를 쓴다.
enum BrightnessLevel {
  darker('어둡게', 0.8),
  normal('원래대로', 1.0),
  brighter('조금 밝게', 1.25),
  brightest('밝게', 1.5);

  final String label;
  final double gamma;
  const BrightnessLevel(this.label, this.gamma);
}

/// 영상 한 개에 대한 편집. 값 객체라 바꿀 때는 새로 만든다.
class ClipEdit {
  /// 남길 구간들(시간순, 겹치지 않음). 비어 있으면 영상 전체를 쓴다.
  final List<TimeRange> keep;
  final VolumeLevel volume;
  final BrightnessLevel brightness;

  const ClipEdit({
    this.keep = const [],
    this.volume = VolumeLevel.normal,
    this.brightness = BrightnessLevel.normal,
  });

  static const ClipEdit none = ClipEdit();

  bool get isTrimmed => keep.isNotEmpty;

  bool get isDefault =>
      keep.isEmpty &&
      volume == VolumeLevel.normal &&
      brightness == BrightnessLevel.normal;

  ClipEdit copyWith({
    List<TimeRange>? keep,
    VolumeLevel? volume,
    BrightnessLevel? brightness,
  }) =>
      ClipEdit(
        keep: keep ?? this.keep,
        volume: volume ?? this.volume,
        brightness: brightness ?? this.brightness,
      );

  /// 작업 폴더 이름(이어하기 판정)에 들어가는 문자열. 빠진 값이 있으면 편집을 바꿔도 옛 조각을 재사용한다.
  String get signature => [
        for (final r in keep)
          '${r.start.toStringAsFixed(3)}-${r.end.toStringAsFixed(3)}',
        volume.name,
        brightness.name,
      ].join(',');

  Map<String, dynamic> toJson() => {
        if (keep.isNotEmpty) 'keep': [for (final r in keep) r.toJson()],
        if (volume != VolumeLevel.normal) 'volume': volume.name,
        if (brightness != BrightnessLevel.normal) 'brightness': brightness.name,
      };

  /// 편집 정보가 없거나 깨진 값은 편집 없음으로 읽는다.
  static ClipEdit fromJson(Object? o) {
    if (o is! Map) return none;
    final keep = <TimeRange>[];
    final raw = o['keep'];
    if (raw is List) {
      for (final r in raw) {
        final t = TimeRange.fromJson(r);
        if (t != null) keep.add(t);
      }
    }
    return ClipEdit(
      keep: normalizeRanges(keep),
      volume: VolumeLevel.values.firstWhere((v) => v.name == o['volume'],
          orElse: () => VolumeLevel.normal),
      brightness: BrightnessLevel.values.firstWhere(
          (v) => v.name == o['brightness'],
          orElse: () => BrightnessLevel.normal),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ClipEdit &&
      other.volume == volume &&
      other.brightness == brightness &&
      _sameRanges(other.keep, keep);

  @override
  int get hashCode => Object.hash(Object.hashAll(keep), volume, brightness);
}

bool _sameRanges(List<TimeRange> a, List<TimeRange> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 이보다 짧은 조각은 버린다. 인코더에 따라 프레임이 하나도 안 나와 이어붙이기가 깨진다.
const double kMinRangeSec = 0.5;

/// 시간순 정렬 후 겹치거나 맞닿은 구간은 합치고, 너무 짧은 구간은 버린다.
List<TimeRange> normalizeRanges(List<TimeRange> input, {double? duration}) {
  final rs = <TimeRange>[];
  for (final r in input) {
    var s = r.start < 0 ? 0.0 : r.start;
    var e = r.end;
    if (duration != null && duration > 0 && e > duration) e = duration;
    if (e > s) rs.add(TimeRange(s, e));
  }
  rs.sort((a, b) => a.start.compareTo(b.start));
  final merged = <TimeRange>[];
  for (final r in rs) {
    if (merged.isNotEmpty && r.start <= merged.last.end + 0.001) {
      final last = merged.removeLast();
      merged.add(TimeRange(last.start, r.end > last.end ? r.end : last.end));
    } else {
      merged.add(r);
    }
  }
  return merged.where((r) => r.length >= kMinRangeSec).toList();
}

/// 목록에 올라간 클립 한 개. 실측 스펙 + 사용자 설정.
class ClipItem {
  final String id;
  final VideoSpec spec;

  /// 사용자가 추가로 지정한 회전(0/90/180/270). 컨테이너 회전이 적용된 **화면 기준** 시계방향이다.
  int userRotation;

  ClipEdit edit;

  String? thumbnailPath;

  ClipItem({
    required this.id,
    required this.spec,
    this.userRotation = 0,
    this.edit = ClipEdit.none,
    this.thumbnailPath,
  });

  List<TimeRange> get ranges =>
      edit.keep.isEmpty ? [TimeRange(0, spec.durationSec)] : edit.keep;

  /// 결과물에 들어가는 길이. 진행률·남은 시간·예상 용량의 기준이다.
  double get effectiveDuration =>
      edit.keep.isEmpty
          ? spec.durationSec
          : edit.keep.fold<double>(0, (s, r) => s + r.length);

  bool get needsReencode => userRotation != 0 || !edit.isDefault;

  bool get _userRotSwaps => userRotation == 90 || userRotation == 270;

  /// 사용자 회전까지 반영한 최종 크기.
  int get finalWidth => _userRotSwaps ? spec.displayHeight : spec.displayWidth;
  int get finalHeight => _userRotSwaps ? spec.displayWidth : spec.displayHeight;

  bool get finalIsPortrait => finalHeight > finalWidth;

  double get aspect => finalHeight == 0 ? 0 : finalWidth / finalHeight;

  ClipItem copyWith({
    String? id,
    int? userRotation,
    ClipEdit? edit,
    String? thumbnailPath,
  }) =>
      ClipItem(
        id: id ?? this.id,
        spec: spec,
        userRotation: userRotation ?? this.userRotation,
        edit: edit ?? this.edit,
        thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      );
}

/// 목록 정렬 기준.
enum SortMode {
  name('이름'),

  /// 파일명 속 숫자의 어느 자리가 상위 키인지 추론해 정렬한다. [detectNameKeyOrder] 참고.
  nameSmart('이름 (자동)'),

  createdDate('만든 날짜'),
  modifiedDate('수정한 날짜'),
  duration('길이');

  final String label;
  const SortMode(this.label);
}

/// 파일명 자연 정렬. 단순 문자열 비교면 "영상10.mp4" 가 "영상2.mp4" 앞에 오므로 숫자는 숫자로 비교한다.
int naturalCompare(String a, String b) {
  final la = a.toLowerCase();
  final lb = b.toLowerCase();
  int i = 0, j = 0;

  while (i < la.length && j < lb.length) {
    final ca = la.codeUnitAt(i);
    final cb = lb.codeUnitAt(j);
    final aDigit = ca >= 0x30 && ca <= 0x39;
    final bDigit = cb >= 0x30 && cb <= 0x39;

    if (aDigit && bDigit) {
      int si = i, sj = j;
      while (i < la.length && la.codeUnitAt(i) >= 0x30 && la.codeUnitAt(i) <= 0x39) {
        i++;
      }
      while (j < lb.length && lb.codeUnitAt(j) >= 0x30 && lb.codeUnitAt(j) <= 0x39) {
        j++;
      }
      final na = la.substring(si, i).replaceFirst(RegExp(r'^0+(?=\d)'), '');
      final nb = lb.substring(sj, j).replaceFirst(RegExp(r'^0+(?=\d)'), '');
      if (na.length != nb.length) return na.length - nb.length;
      final c = na.compareTo(nb);
      if (c != 0) return c;
    } else {
      if (ca != cb) return ca - cb;
      i++;
      j++;
    }
  }
  return (la.length - i) - (lb.length - j);
}

/// 파일명에서 "어느 자리가 상위 키인가"를 추론한 결과.
///
/// 뒤에서 [tailDigits] 자리를 먼저 비교하고, 그 다음 앞부분을 비교한다.
/// [tailDigits] 가 0 이면 평범한 자연 정렬과 같다.
class NameKeyOrder {
  final int groupIndex;
  final int digits;
  final int tailDigits;

  const NameKeyOrder({
    required this.groupIndex,
    required this.digits,
    required this.tailDigits,
  });

  bool get isPlain => tailDigits <= 0 || tailDigits >= digits;

  static const NameKeyOrder plain =
      NameKeyOrder(groupIndex: -1, digits: 0, tailDigits: 0);
}

final RegExp _digitRun = RegExp(r'\d+');

/// 파일명 목록을 보고, 숫자의 뒷자리가 실제로는 상위 키인지 추론한다.
///
/// 어떤 카메라는 `E-10463, E-20463, E-30463, E-10464 ...` 처럼 앞 두 자리를 순번,
/// 뒤 세 자리를 날짜로 쓴다. 숫자 전체로 비교하면 날짜가 뒤섞인다.
///
/// 입력 순서에 의존하지 않는다 (탐색기가 이름순으로 넘겨주기도 한다). 숫자를 앞/뒤로
/// 자를 수 있는 모든 지점을 시도해 **평범한 정렬과 결과가 달라지는 첫 분할**을 채택한다.
/// IMG_0001, IMG_0002 같은 단순 증가 이름은 어디서 잘라도 같아 걸러진다.
///
/// 어느 쪽이 맞는지는 파일명만으로 확정할 수 없으므로 후보만 고르고 최종 판단은 사용자가 한다.
NameKeyOrder detectNameKeyOrder(List<String> fileNames) {
  if (fileNames.length < 4) return NameKeyOrder.plain;

  // 분할 후보마다 전체를 정렬하므로 많으면 앞부분 표본만 쓴다.
  final sample =
      fileNames.length > 80 ? fileNames.sublist(0, 80) : fileNames;

  final rows = <List<String>>[];
  for (final name in sample) {
    final stem =
        name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
    final runs = _digitRun.allMatches(stem).map((m) => m.group(0)!).toList();
    if (runs.isEmpty) return NameKeyOrder.plain;
    rows.add(runs);
  }

  // 모든 파일의 숫자 덩어리 개수가 같아야 비교가 성립한다.
  final groupCount = rows.first.length;
  if (rows.any((r) => r.length != groupCount)) return NameKeyOrder.plain;

  final plainSorted = [...sample]..sort(naturalCompare);

  for (var g = 0; g < groupCount; g++) {
    final col = rows.map((r) => r[g]).toList();

    final len = col.first.length;
    if (len < 2 || col.any((s) => s.length != len)) continue;

    if (col.toSet().length < 2) continue;

    for (var tail = 1; tail < len; tail++) {
      final order =
          NameKeyOrder(groupIndex: g, digits: len, tailDigits: tail);
      final smartSorted = [...sample]
        ..sort((a, b) => smartNameCompare(a, b, order));
      if (!_sameOrder(plainSorted, smartSorted)) return order;
    }
  }

  return NameKeyOrder.plain;
}

bool _sameOrder(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int smartNameCompare(String a, String b, NameKeyOrder order) {
  if (order.isPlain) return naturalCompare(a, b);

  final ka = _keyOf(a, order);
  final kb = _keyOf(b, order);
  if (ka == null || kb == null) return naturalCompare(a, b);

  final t = ka.tail.compareTo(kb.tail);
  if (t != 0) return t;
  final h = ka.head.compareTo(kb.head);
  if (h != 0) return h;
  return naturalCompare(a, b);
}

({String head, String tail})? _keyOf(String name, NameKeyOrder order) {
  final stem =
      name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
  final runs = _digitRun.allMatches(stem).map((m) => m.group(0)!).toList();
  if (order.groupIndex >= runs.length) return null;
  final s = runs[order.groupIndex];
  if (s.length != order.digits) return null;
  final cut = order.digits - order.tailDigits;
  return (head: s.substring(0, cut), tail: s.substring(cut));
}

void sortClips(
  List<ClipItem> clips,
  SortMode mode, {
  bool descending = false,
  NameKeyOrder? nameKeyOrder,
}) {
  final order = nameKeyOrder ??
      (mode == SortMode.nameSmart
          ? detectNameKeyOrder(clips.map((c) => c.spec.fileName).toList())
          : NameKeyOrder.plain);

  int cmp(ClipItem a, ClipItem b) {
    switch (mode) {
      case SortMode.name:
        return naturalCompare(a.spec.fileName, b.spec.fileName);
      case SortMode.nameSmart:
        return smartNameCompare(a.spec.fileName, b.spec.fileName, order);
      case SortMode.createdDate:
        return a.spec.createdDate.compareTo(b.spec.createdDate);
      case SortMode.modifiedDate:
        return a.spec.fileModified.compareTo(b.spec.fileModified);
      case SortMode.duration:
        return a.spec.durationSec.compareTo(b.spec.durationSec);
    }
  }

  clips.sort((a, b) => descending ? cmp(b, a) : cmp(a, b));
}

String formatDuration(double seconds) {
  if (seconds <= 0) return '0:00';
  final total = seconds.round();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  return '$m:${s.toString().padLeft(2, '0')}';
}

String formatDurationKorean(double seconds) {
  if (seconds <= 0) return '0초';
  final total = seconds.round();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final parts = <String>[];
  if (h > 0) parts.add('$h시간');
  if (m > 0) parts.add('$m분');
  if (s > 0 && h == 0) parts.add('$s초');
  return parts.isEmpty ? '0초' : parts.join(' ');
}

String formatBytes(int bytes) {
  if (bytes <= 0) return '0 MB';
  const gb = 1024 * 1024 * 1024;
  const mb = 1024 * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
  return '${(bytes / mb).toStringAsFixed(0)} MB';
}

/// 10Mbps 미만은 소수 1자리까지.
String formatBitrate(int bps) {
  if (bps <= 0) return '-';
  final mbps = bps / 1000000;
  if (mbps >= 10) return '${mbps.round()} Mbps';
  if (mbps >= 1) return '${mbps.toStringAsFixed(1)} Mbps';
  return '${(bps / 1000).round()} kbps';
}

/// 해상도 통칭 (Full HD, 4K 등).
String resolutionNickname(int w, int h) {
  final long = w > h ? w : h;
  final short = w > h ? h : w;
  if (long >= 7000) return '8K';
  if (long >= 3800 && short >= 2100) return '4K UHD';
  if (long >= 3800) return '4K';
  if (long >= 2500 && short >= 1400) return 'QHD';
  if (long >= 1900 && short >= 1000) return 'Full HD';
  if (long >= 1250 && short >= 700) return 'HD';
  if (long >= 850) return 'SD';
  return '저해상도';
}
