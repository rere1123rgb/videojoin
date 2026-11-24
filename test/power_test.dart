// 절전 방지 검증.
//
//   flutter test test/power_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videojoin/engine/power.dart';
import 'package:videojoin/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('KeepAwake', () {
    tearDown(KeepAwake.release);

    test('붙잡았다가 놓을 수 있다', () {
      expect(KeepAwake.held, isFalse);

      KeepAwake.acquire();
      expect(KeepAwake.held, isTrue, reason: 'kernel32 호출이 실패했다');

      KeepAwake.release();
      expect(KeepAwake.held, isFalse);
    });

    test('두 번 붙잡아도 한 번만 놓으면 된다', () {
      KeepAwake.acquire();
      KeepAwake.acquire();
      KeepAwake.release();
      expect(KeepAwake.held, isFalse);
    });

    test('붙잡지 않은 상태에서 놓아도 터지지 않는다', () {
      expect(KeepAwake.release, returnsNormally);
      expect(KeepAwake.held, isFalse);
    });

    test('apply 로 상태를 맞출 수 있다', () {
      KeepAwake.apply(keep: true);
      expect(KeepAwake.held, isTrue);
      KeepAwake.apply(keep: false);
      expect(KeepAwake.held, isFalse);
    });
  });

  group('설정', () {
    test('기본은 꺼짐이고, 껐다 켜도 기억한다', () async {
      SharedPreferences.setMockInitialValues({});

      final s = AppState();
      await s.init();
      expect(s.preventSleep, isFalse, reason: '기본값은 꺼짐이어야 한다');

      await s.setPreventSleep(true);
      // 아직 만들고 있는 게 없으므로 실제로 붙잡지는 않는다.
      expect(KeepAwake.held, isFalse);
      s.dispose();

      final again = AppState();
      await again.init();
      expect(again.preventSleep, isTrue);
      again.dispose();

      KeepAwake.release();
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
