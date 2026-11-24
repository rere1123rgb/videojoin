import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// 프로그램 버전. 빌드된 날짜를 그대로 쓴다.
///
/// 버전 문자열을 소스에 적어 두면 빌드할 때마다 고쳐야 하고, 고치는 걸
/// 잊으면 틀린 값이 나간다. 빌드 산출물의 날짜를 읽으면 언제나 맞다.
///
/// 실행 파일 하나만 보면 안 된다. Dart 코드만 고친 경우 videojoin.exe 는
/// 다시 만들어지지 않으므로, 코드가 담기는 파일까지 함께 보고 가장 최근 것을 고른다.
/// 시험판 표시. 정식 배포 때는 빈 문자열로 바꾼다.
/// 창 제목과 버전 표시에 함께 붙는다.
const String kReleaseTag = '';

/// 빌드 날짜 대신 쓸 버전(시각 테스트용).
const String kVersionOverride = String.fromEnvironment('VJ_VERSION');

String appVersionLabel() {
  if (kVersionOverride.isNotEmpty) {
    return kReleaseTag.isEmpty
        ? kVersionOverride
        : '$kVersionOverride $kReleaseTag';
  }
  try {
    final exe = Platform.resolvedExecutable;
    final dir = File(exe).parent.path;
    final candidates = [
      exe,
      '$dir\\data\\app.so', // Release: AOT 코드
      '$dir\\data\\flutter_assets\\kernel_blob.bin', // Debug
    ];

    DateTime? newest;
    for (final path in candidates) {
      try {
        final f = File(path);
        if (!f.existsSync()) continue;
        final m = f.statSync().modified;
        if (newest == null || m.isAfter(newest)) newest = m;
      } on Object {
        continue;
      }
    }
    if (newest == null) return '';

    String two(int v) => v.toString().padLeft(2, '0');
    final date = '${newest.year}.${two(newest.month)}.${two(newest.day)}';
    return kReleaseTag.isEmpty ? date : '$date $kReleaseTag';
  } on Object {
    return '';
  }
}

/// 서명·숨은 인사 문구. 소스에 적지 않고 빌드할 때 넣는다.
///
/// 문구는 저장소에 없는 `personal.json` 에 두고 `build_release.ps1` 이
/// `--dart-define-from-file=personal.json` 으로 넘긴다(`-Web` 빌드는 넘기지 않음).
///   {"VJ_AUTHOR": "만든 사람 : ...", "VJ_CHEER": "..."}
/// 값이 없으면 서명 자리에는 버전만 나온다.
const String kAuthorLine = String.fromEnvironment('VJ_AUTHOR');
const String kCheerText = String.fromEnvironment('VJ_CHEER');

/// 화면 맨 아래 구석에 들어가는 버전 표시와 서명.
///
/// 서명은 **눈에 띄면 안 되므로** 배경에 거의 묻히는 색으로 칠한다.
///
/// 서명을 20번 누르면 숨겨둔 인사([cheer])가 나온다.
class Signature extends StatefulWidget {
  final String author;
  final String cheer;

  const Signature({
    super.key,
    this.author = kAuthorLine,
    this.cheer = kCheerText,
  });

  @override
  State<Signature> createState() => _SignatureState();
}

class _SignatureState extends State<Signature> {
  static const int _threshold = 20;
  int _taps = 0;

  void _onTap() {
    setState(() => _taps++);
    if (_taps >= _threshold && widget.cheer.isNotEmpty) {
      _taps = 0; // 다시 볼 수 있게 되돌린다
      _showCheer();
    }
  }

  void _showCheer() {
    final overlay = Overlay.of(context, rootOverlay: true);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _CheerOverlay(
        text: widget.cheer,
        onDone: () {
          if (entry.mounted) entry.remove();
        },
      ),
    );
    overlay.insert(entry);
  }

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    // 배경 대비 아주 낮은 명도차. 다크/라이트 모두에서 겨우 보이는 정도.
    final faint = AppColors.textFaint.withValues(alpha: 0.28);

    final version = appVersionLabel();

    return Padding(
      padding: EdgeInsets.symmetric(vertical: d.px(10), horizontal: d.px(6)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // 버전은 확인할 일이 있는 정보라 서명보다 또렷하게 둔다.
          // 크기는 같게 유지해 화면을 어지럽히지 않는다.
          if (version.isNotEmpty) ...[
            Text(
              '버전 $version',
              style: TextStyle(
                fontSize: d.px(11),
                color: AppColors.textSub,
                letterSpacing: 0.2,
              ),
            ),
            SizedBox(width: d.px(14)),
          ],
          if (widget.author.isNotEmpty)
            GestureDetector(
              onTap: _onTap,
              behavior: HitTestBehavior.opaque,
              child: Text(
                widget.author,
                style: TextStyle(
                  fontSize: d.px(11),
                  color: faint,
                  letterSpacing: 0.2,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 숨은 인사 + 하트가 떠오르는 화면 덮개.
///
/// [IgnorePointer] 로 감싸서 애니메이션 중에도 뒤쪽 조작이 막히지 않게 한다.
/// 인코딩 중에 눌러도 작업에 영향이 없어야 한다.
class _CheerOverlay extends StatefulWidget {
  final String text;
  final VoidCallback onDone;

  const _CheerOverlay({required this.text, required this.onDone});

  @override
  State<_CheerOverlay> createState() => _CheerOverlayState();
}

class _CheerOverlayState extends State<_CheerOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final List<_Heart> _hearts;

  @override
  void initState() {
    super.initState();
    final rnd = math.Random();
    _hearts = List.generate(22, (i) {
      return _Heart(
        x: rnd.nextDouble(),
        delay: rnd.nextDouble() * 0.45,
        speed: 0.75 + rnd.nextDouble() * 0.5,
        size: 16 + rnd.nextDouble() * 26,
        drift: (rnd.nextDouble() - 0.5) * 0.16,
        hue: rnd.nextDouble(),
      );
    });

    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3400),
    )..forward();

    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);

    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          final appear = Curves.easeOutBack.transform(
            (t / 0.28).clamp(0.0, 1.0),
          );
          final fade = t < 0.72 ? 1.0 : 1.0 - ((t - 0.72) / 0.28);

          return Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _HeartPainter(progress: t, hearts: _hearts),
                ),
              ),
              Center(
                child: Opacity(
                  opacity: fade.clamp(0.0, 1.0),
                  child: Transform.scale(
                    scale: 0.6 + appear * 0.4,
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: d.px(34),
                        vertical: d.px(20),
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surface.withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(d.px(18)),
                        border: Border.all(
                          color: const Color(0xFFE8607A),
                          width: d.px(3),
                        ),
                      ),
                      child: Text(
                        widget.text,
                        style: TextStyle(
                          fontSize: d.px(40),
                          fontWeight: FontWeight.w800,
                          color: const Color(0xFFD6455F),
                          letterSpacing: 2,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Heart {
  final double x;
  final double delay;
  final double speed;
  final double size;
  final double drift;
  final double hue;

  const _Heart({
    required this.x,
    required this.delay,
    required this.speed,
    required this.size,
    required this.drift,
    required this.hue,
  });
}

/// 하트를 아래에서 위로 띄운다.
/// SVG 패스를 손으로 적는 대신 두 원 + 삼각형으로 그린다.
class _HeartPainter extends CustomPainter {
  final double progress;
  final List<_Heart> hearts;

  _HeartPainter({required this.progress, required this.hearts});

  static const _palette = [
    Color(0xFFE8607A),
    Color(0xFFF08CA0),
    Color(0xFFD6455F),
    Color(0xFFF5A8B8),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    for (final h in hearts) {
      final local = ((progress - h.delay) * h.speed).clamp(0.0, 1.0);
      if (local <= 0) continue;

      // 아래에서 위로. 끝에서 서서히 사라진다.
      final y = size.height * (1.05 - local * 1.15);
      final x = size.width * (h.x + math.sin(local * math.pi * 2) * h.drift);
      final opacity = local < 0.75 ? 1.0 : (1.0 - (local - 0.75) / 0.25);
      if (opacity <= 0) continue;

      final color =
          _palette[(h.hue * _palette.length).floor() % _palette.length];
      final paint = Paint()
        ..color = color.withValues(alpha: opacity.clamp(0.0, 1.0) * 0.9)
        ..style = PaintingStyle.fill;

      _drawHeart(canvas, Offset(x, y), h.size, paint);
    }
  }

  void _drawHeart(Canvas canvas, Offset c, double s, Paint paint) {
    final r = s / 4;
    canvas.drawCircle(Offset(c.dx - r, c.dy - r * 0.6), r, paint);
    canvas.drawCircle(Offset(c.dx + r, c.dy - r * 0.6), r, paint);
    final path = Path()
      ..moveTo(c.dx - r * 2, c.dy - r * 0.4)
      ..quadraticBezierTo(c.dx - r * 1.9, c.dy + r * 1.1, c.dx, c.dy + r * 2.2)
      ..quadraticBezierTo(
        c.dx + r * 1.9,
        c.dy + r * 1.1,
        c.dx + r * 2,
        c.dy - r * 0.4,
      )
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_HeartPainter old) => old.progress != progress;
}
