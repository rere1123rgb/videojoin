import 'dart:ffi';
import 'dart:io';

/// 작업이 끝났을 때 소리로 알린다.
///
/// user32.dll 의 MessageBeep 을 직접 불러 오디오 패키지나 소리 파일 없이 처리한다.
class Notify {
  static const int _mbIconAsterisk = 0x00000040;
  static const int _mbIconHand = 0x00000010;

  static int Function(int)? _beep;
  static bool _tried = false;

  static void _load() {
    if (_tried) return;
    _tried = true;
    if (!Platform.isWindows) return;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      _beep = user32.lookupFunction<Uint32 Function(Uint32), int Function(int)>(
        'MessageBeep',
      );
    } on Object {
      _beep = null;
    }
  }

  static void success() {
    _load();
    try {
      _beep?.call(_mbIconAsterisk);
    } on Object {
      // 부가 기능이므로 실패해도 무시.
    }
  }

  static void failure() {
    _load();
    try {
      _beep?.call(_mbIconHand);
    } on Object {
      // 무시
    }
  }
}
