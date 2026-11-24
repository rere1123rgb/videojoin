// 바로가기 생성/중복 방지 검증.
//
// 실제로 바탕화면과 시작 메뉴에 .lnk 를 만들어 보고, 끝나면 지운다.
//
//   flutter test test/shortcut_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:videojoin/engine/shortcuts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String desktopLnk() => p.join(
        Platform.environment['USERPROFILE']!,
        'Desktop',
        '${Shortcuts.linkName}.lnk',
      );

  String startMenuLnk() => p.join(
        Platform.environment['APPDATA']!,
        'Microsoft',
        'Windows',
        'Start Menu',
        'Programs',
        '${Shortcuts.linkName}.lnk',
      );

  // 테스트 시작 전 상태를 기억해 두었다가 끝나고 그대로 되돌린다.
  late bool hadDesktop;
  late bool hadStartMenu;

  setUpAll(() {
    hadDesktop = File(desktopLnk()).existsSync();
    hadStartMenu = File(startMenuLnk()).existsSync();
  });

  tearDownAll(() {
    for (final entry in [
      (desktopLnk(), hadDesktop),
      (startMenuLnk(), hadStartMenu),
    ]) {
      final f = File(entry.$1);
      if (!entry.$2 && f.existsSync()) {
        try {
          f.deleteSync();
        } on Object {
          // 무시
        }
      }
    }
  });

  test('시작 메뉴 바로가기를 만들고, 두 번 불러도 중복되지 않는다', () async {
    final path = startMenuLnk();
    if (File(path).existsSync()) File(path).deleteSync();

    expect(await Shortcuts.startMenuExists(), isFalse);

    expect(await Shortcuts.ensureStartMenu(), isTrue);
    expect(File(path).existsSync(), isTrue);
    final firstStamp = File(path).statSync().modified;

    // 두 번째 호출은 이미 있으므로 아무것도 하지 않아야 한다.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(await Shortcuts.ensureStartMenu(), isTrue);
    expect(File(path).statSync().modified, firstStamp,
        reason: '이미 있으면 다시 만들면 안 된다');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('바탕화면 바로가기를 만들 수 있다', () async {
    final path = desktopLnk();
    if (File(path).existsSync()) File(path).deleteSync();

    expect(await Shortcuts.desktopExists(), isFalse);
    expect(await Shortcuts.createDesktop(), isTrue);
    expect(await Shortcuts.desktopExists(), isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
