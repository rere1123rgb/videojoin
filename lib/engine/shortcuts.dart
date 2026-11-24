import 'dart:io';

import 'ffmpeg_tools.dart';

/// 바탕화면 / 시작 메뉴 바로가기 관리.
///
/// .lnk 는 COM(WScript.Shell)으로만 만들 수 있어 PowerShell 을 잠깐 부른다.
/// `-WindowStyle Hidden` 으로 검은 창이 깜빡이지 않게 한다.
class Shortcuts {
  static const String linkName = '영상 합치기';

  static Future<bool> startMenuExists() => _exists(_startMenuExpr);

  static Future<bool> desktopExists() => _exists(_desktopExpr);

  /// 이미 있으면 아무것도 하지 않는다.
  static Future<bool> ensureStartMenu() async {
    if (await startMenuExists()) return true;
    return _create(_startMenuExpr);
  }

  static Future<bool> createDesktop() => _create(_desktopExpr);

  // 바탕화면이 OneDrive 로 옮겨져 있을 수 있어 USERPROFILE\Desktop 을 가정하지 않고
  // PowerShell 안에서 경로를 구한다.
  static const String _desktopExpr =
      r'(Join-Path ([Environment]::GetFolderPath("Desktop")) "영상 합치기.lnk")';

  static const String _startMenuExpr =
      r'(Join-Path (Join-Path ([Environment]::GetFolderPath("StartMenu")) "Programs") "영상 합치기.lnk")';

  static Future<bool> _exists(String pathExpr) async {
    if (!Platform.isWindows) return false;
    try {
      final r = await runCaptured(
        'powershell',
        [
          '-NoProfile',
          '-NonInteractive',
          '-WindowStyle', 'Hidden',
          '-Command',
          'if (Test-Path $pathExpr) { "yes" } else { "no" }',
        ],
        timeout: const Duration(seconds: 20),
      );
      return r.stdout.trim().toLowerCase().contains('yes');
    } on Object {
      return false;
    }
  }

  static Future<bool> _create(String pathExpr) async {
    if (!Platform.isWindows) return false;
    try {
      final exe = Platform.resolvedExecutable;
      final dir = File(exe).parent.path;

      // 작은따옴표로 감싸고 내부 작은따옴표만 이스케이프 (Windows 경로엔 " 가 없다).
      String q(String s) => "'${s.replaceAll("'", "''")}'";

      final script = [
        r'$ws = New-Object -ComObject WScript.Shell;',
        r'$l = $ws.CreateShortcut(' '$pathExpr);',
        '\$l.TargetPath = ${q(exe)};',
        '\$l.WorkingDirectory = ${q(dir)};',
        '\$l.IconLocation = ${q('$exe,0')};',
        '\$l.Description = ${q(linkName)};',
        r'$l.Save()',
      ].join(' ');

      final r = await runCaptured(
        'powershell',
        [
          '-NoProfile',
          '-NonInteractive',
          '-WindowStyle', 'Hidden',
          '-ExecutionPolicy', 'Bypass',
          '-Command',
          script,
        ],
        timeout: const Duration(seconds: 25),
      );
      if (!r.ok) return false;
      return await _exists(pathExpr);
    } on Object {
      return false;
    }
  }
}
