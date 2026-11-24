import 'dart:ffi';
import 'dart:io';

/// 영상을 만드는 동안 컴퓨터가 절전으로 빠지지 않게 붙잡아 둔다.
///
/// 오래 걸리는 작업 중 사용자 입력이 없어 윈도우가 절전으로 들어가는 것을 막는다.
///
/// 화면은 그대로 꺼지게 둔다 — `ES_DISPLAY_REQUIRED` 는 일부러 쓰지 않는다.
/// 사용자가 켰을 때만, 대기열이 도는 동안에만 붙잡는다.
class KeepAwake {
  /// 요청을 계속 유지. 빼면 타이머를 한 번만 미루고 끝난다.
  static const int _esContinuous = 0x80000000;

  static const int _esSystemRequired = 0x00000001;

  static int Function(int)? _setState;
  static bool _looked = false;
  static bool _held = false;

  static bool get held => _held;

  static int Function(int)? _resolve() {
    if (_looked) return _setState;
    _looked = true;
    if (!Platform.isWindows) return null;
    try {
      _setState = DynamicLibrary.open('kernel32.dll').lookupFunction<
          Uint32 Function(Uint32),
          int Function(int)>('SetThreadExecutionState');
    } on Object {
      // 절전 방지만 포기하고 인코딩은 계속한다.
      _setState = null;
    }
    return _setState;
  }

  /// 이 설정은 **부른 스레드**에 걸린다. Dart 코드는 항상 UI 스레드에서 돌므로
  /// [release] 때까지 유지된다.
  static void acquire() {
    if (_held) return;
    final f = _resolve();
    if (f == null) return;
    if (f(_esContinuous | _esSystemRequired) != 0) _held = true;
  }

  static void release() {
    if (!_held) return;
    _held = false;
    final f = _resolve();
    if (f == null) return;
    f(_esContinuous);
  }

  static void apply({required bool keep}) {
    if (keep) {
      acquire();
    } else {
      release();
    }
  }
}
