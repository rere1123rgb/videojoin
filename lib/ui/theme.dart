import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 색상. 글자와 배경의 대비를 충분히 준다.
class AppColors {
  static const bg = Color(0xFFF4F6F8);
  static const surface = Colors.white;

  /// 카드 안에서 한 단계 눌러 앉힌 영역. 읽기 전용 값이나 보조 입력에 쓴다.
  static const surface2 = Color(0xFFF1F4F7);
  static const border = Color(0xFFD6DBE1);
  static const borderStrong = Color(0xFFAAB4BF);

  static const text = Color(0xFF1A1F26);
  static const textSub = Color(0xFF5A646F);
  static const textFaint = Color(0xFF8A939E);

  static const primary = Color(0xFF1565C0);
  static const primaryDark = Color(0xFF0D47A1);
  static const primaryLight = Color(0xFFE3F0FC);

  static const success = Color(0xFF1B7F3B);
  static const successLight = Color(0xFFE6F4EA);
  static const warning = Color(0xFFB35300);
  static const warningLight = Color(0xFFFFF3E5);
  static const danger = Color(0xFFB3261E);
  static const dangerLight = Color(0xFFFCEAE9);
}

/// 4K 대응 배율.
///
/// Flutter 는 논리 픽셀 기준이라 Windows 디스플레이 배율(150%, 200%)이
/// 자동으로 반영된다. 문제는 4K 모니터를 배율 100% 로 쓰는 경우다.
/// 그때는 논리 해상도가 3840 이나 되어서 모든 UI 가 절반 크기로 보인다.
///
/// 그래서 논리 화면 너비를 보고 배율을 역산한다.
///   4K + 100%  → 논리 3840 → 1.5배
///   4K + 150%  → 논리 2560 → 1.15배
///   4K + 200%  → 논리 1920 → 1.0배
///   FHD + 100% → 논리 1920 → 1.0배
/// 어느 환경에서든 실제 눈에 보이는 크기가 비슷해진다.
double autoUiScale() {
  try {
    final view = ui.PlatformDispatcher.instance.views.first;
    final logicalWidth = view.display.size.width / view.display.devicePixelRatio;
    final scale = logicalWidth / 1920.0;
    return scale.clamp(1.0, 1.6);
  } on Object {
    return 1.0;
  }
}

/// 사용자가 설정에서 조절하는 추가 배율과 자동 배율을 합친 값.
class UiScale extends InheritedWidget {
  final double factor;

  const UiScale({super.key, required this.factor, required super.child});

  static double of(BuildContext context) {
    final w = context.dependOnInheritedWidgetOfExactType<UiScale>();
    return w?.factor ?? 1.0;
  }

  @override
  bool updateShouldNotify(UiScale oldWidget) => oldWidget.factor != factor;
}

ThemeData buildAppTheme(double scale) {
  double s(double v) => v * scale;

  const fontFallback = <String>[
    'Malgun Gothic',
    'Segoe UI',
    'Apple SD Gothic Neo',
    'Noto Sans KR',
  ];

  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: Brightness.light,
    ).copyWith(
      primary: AppColors.primary,
      surface: AppColors.surface,
      error: AppColors.danger,
    ),
    fontFamilyFallback: fontFallback,
    visualDensity: VisualDensity.standard,
  );

  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      displayLarge: TextStyle(
        fontSize: s(34),
        fontWeight: FontWeight.w700,
        color: AppColors.text,
        fontFamilyFallback: fontFallback,
      ),
      titleLarge: TextStyle(
        fontSize: s(24),
        fontWeight: FontWeight.w700,
        color: AppColors.text,
        fontFamilyFallback: fontFallback,
      ),
      titleMedium: TextStyle(
        fontSize: s(20),
        fontWeight: FontWeight.w600,
        color: AppColors.text,
        fontFamilyFallback: fontFallback,
      ),
      bodyLarge: TextStyle(
        fontSize: s(18),
        color: AppColors.text,
        fontFamilyFallback: fontFallback,
      ),
      bodyMedium: TextStyle(
        fontSize: s(16),
        color: AppColors.text,
        fontFamilyFallback: fontFallback,
      ),
      bodySmall: TextStyle(
        fontSize: s(14),
        color: AppColors.textSub,
        fontFamilyFallback: fontFallback,
      ),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.border, thickness: 1),
  );
}

class Dim {
  final double scale;
  const Dim(this.scale);

  factory Dim.of(BuildContext context) => Dim(UiScale.of(context));

  double px(double v) => v * scale;

  /// 클릭 대상 최소 높이. 손이 떨려도 누를 수 있게 넉넉히 잡는다.
  double get tapMin => px(52);
  double get buttonHeight => px(58);
  double get bigButtonHeight => px(84);
  double get gap => px(16);
  double get gapSm => px(8);
  double get gapLg => px(28);
  double get radius => px(12);
  double get sectionPad => px(24);
}
