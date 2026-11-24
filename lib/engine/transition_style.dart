/// 영상과 영상 사이를 넘기는 방식.
///  - 거치기(dip): 앞 장면이 한 색으로 사라졌다가 다음 장면이 나타난다.
///    조각 안의 페이드로 처리하므로 전체 길이가 줄지 않는다.
///  - 겹치기(overlap): 끝과 시작을 겹쳐 ffmpeg xfade 로 섞는다. 겹친 만큼 전체 길이가 짧아진다.
enum TransitionStyle {
  dipBlack('검은 화면 거치기', '앞 장면이 검게 어두워졌다가 다음 장면이 밝아지며 나타납니다.',
      dipColor: 'black'),
  dipWhite('흰 화면 거치기', '앞 장면이 하얗게 바래졌다가 다음 장면이 나타납니다.',
      dipColor: 'white'),
  dissolve('겹쳐 넘기기 (디졸브)',
      '앞 장면이 서서히 사라지면서 다음 장면이 겹쳐 나타납니다. 프리미어의 \'교차 디졸브\'와 같습니다.',
      xfade: 'fade'),
  push('밀어내기', '다음 장면이 오른쪽에서 들어오며 앞 장면을 왼쪽으로 밀어냅니다.',
      xfade: 'slideleft'),
  wipe('부드럽게 닦아내기', '경계가 부드러운 선이 화면을 가로지르며 다음 장면으로 바뀝니다.',
      xfade: 'smoothleft'),
  zoom('다가가며 넘기기', '앞 장면이 앞으로 다가오듯 커지면서 다음 장면으로 바뀝니다.',
      xfade: 'zoomin'),
  blur('흐려지며 넘기기', '앞 장면이 옆으로 번지듯 흐려지고, 다음 장면이 또렷해지며 나타납니다.',
      xfade: 'hblur'),
  grays('흑백으로 바래며 넘기기',
      '앞 장면의 색이 빠져 흑백이 됐다가 다음 장면의 색이 살아납니다. 지난 일을 떠올리는 느낌.',
      xfade: 'fadegrays');

  final String label;
  final String description;

  /// 거치기 방식이면 거치는 색(ffmpeg fade 의 color 값).
  final String? dipColor;

  /// 겹치기 방식이면 ffmpeg xfade 의 transition 이름.
  final String? xfade;

  const TransitionStyle(this.label, this.description,
      {this.dipColor, this.xfade});

  bool get isOverlap => xfade != null;

  /// 겹치기 방식은 검은색으로 본다 (맨 처음·끝 서서히가 어떤 방식에서도 같아야 한다).
  String get ffmpegName => dipColor ?? 'black';

  /// 맨 처음·끝 서서히에 쓰는 거치기 방식. 흰 화면만 흰색, 나머지는 검은색.
  TransitionStyle get endsDip =>
      this == TransitionStyle.dipWhite
          ? TransitionStyle.dipWhite
          : TransitionStyle.dipBlack;
}

/// 넘길 때 걸리는 시간.
///
/// 거치기는 한쪽(어두워지는 쪽, 밝아지는 쪽)이 이만큼 걸리고, 겹치기는
/// 눈에 보이는 길이가 같도록 두 배를 겹친다.
enum TransitionLength {
  short('짧게', 0.3),
  normal('보통', 0.5),
  long('길게', 1.0);

  final String label;
  final double seconds;
  const TransitionLength(this.label, this.seconds);
}
