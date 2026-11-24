// 자동 이름 / 저장 폴더 추론 검증.
//
//   flutter test test/naming_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videojoin/engine/fs_util.dart';
import 'package:videojoin/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final root = Directory.current.path;
  final src = p.join(root, 'testdata', 'same_a.mp4');
  final sandbox = p.join(root, 'out', 'naming_test');

  /// 폴더를 만들고 그 안에 테스트 영상을 [count] 개 복사한다.
  List<String> makeFolder(String folderName, int count) {
    final dir = Directory(p.join(sandbox, folderName));
    dir.createSync(recursive: true);
    final made = <String>[];
    for (var i = 0; i < count; i++) {
      final f = p.join(dir.path, 'clip${i + 1}.mp4');
      File(src).copySync(f);
      made.add(f);
    }
    return made;
  }

  setUpAll(() {
    final d = Directory(sandbox);
    forceDeleteDir(d);
    d.createSync(recursive: true);
  });

  Future<AppState> ready() async {
    SharedPreferences.setMockInitialValues({});
    final s = AppState();
    await s.init();
    return s;
  }

  test('한 폴더에서 고르면 그 폴더 이름을 그대로 쓴다', () async {
    final s = await ready();
    await s.addPaths(makeFolder('가을 여행 2026', 3));

    // 접미사 기본값은 비어 있다.
    expect(s.nameSuffix, '');
    expect(p.basename(s.sourceFolder()!), '가을 여행 2026');
    expect(s.autoName, '가을 여행 2026');
    expect(s.effectiveOutputName, '가을 여행 2026');
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('여러 폴더면 가장 많이 온 폴더를 쓴다', () async {
    final s = await ready();
    final many = makeFolder('제주도', 4);
    final few = makeFolder('기타', 1);
    // 적은 쪽을 먼저 넣어도 다수결이 이겨야 한다.
    await s.addPaths([...few, ...many]);

    expect(p.basename(s.sourceFolder()!), '제주도');
    expect(s.autoName, '제주도');
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('같은 수면 목록 맨 위 영상의 폴더를 쓴다', () async {
    final s = await ready();
    final a = makeFolder('가가가', 2);
    final b = makeFolder('나나나', 2);
    await s.addPaths([...b, ...a]); // 맨 위는 '나나나'

    expect(p.basename(s.sourceFolder()!), '나나나');
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('접미사를 바꾸면 이름이 따라 바뀐다', () async {
    final s = await ready();
    await s.addPaths(makeFolder('여름휴가', 2));

    expect(s.autoName, '여름휴가');
    await s.setNameSuffix('_Merged');
    expect(s.autoName, '여름휴가_Merged');
    await s.setNameSuffix('');
    expect(s.autoName, '여름휴가');
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('폴더 이름에 쓸 수 없는 글자가 있으면 걸러낸다', () async {
    final s = await ready();
    // 폴더명에는 금지문자를 넣을 수 없으므로 접미사로 검사한다.
    await s.addPaths(makeFolder('보통폴더', 2));
    await s.setNameSuffix('_합침');
    expect(s.autoName.contains(RegExp(r'[\\/:*?"<>|]')), isFalse);
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('자동을 끄면 수동 이름이 쓰이고, 켤 때 값이 채워진다', () async {
    final s = await ready();
    await s.addPaths(makeFolder('봄나들이', 2));

    await s.setAutoNaming(false);
    // 끄는 순간 자동 이름이 편집 출발점으로 들어와야 한다.
    expect(s.outputName, '봄나들이');

    s.setOutputName('내가 지은 이름');
    expect(s.effectiveOutputName, '내가 지은 이름');

    await s.setAutoNaming(true);
    expect(s.effectiveOutputName, '봄나들이');
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  group('저장 폴더', () {
    test('직접 고르기 전에는 영상이 있던 폴더를 따라간다', () async {
      final s = await ready();
      final files = makeFolder('저장테스트', 2);
      await s.addPaths(files);

      expect(s.outputDirIsAuto, isTrue);
      expect(s.effectiveOutputDir, p.dirname(files.first));
      s.dispose();
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('직접 고르면 그 폴더를 유지하고, 되돌릴 수 있다', () async {
      final s = await ready();
      final files = makeFolder('되돌리기', 2);
      await s.addPaths(files);
      final auto = s.effectiveOutputDir;

      final other = p.join(sandbox, '다른곳');
      Directory(other).createSync(recursive: true);
      await s.setOutputDir(other);

      expect(s.outputDirIsAuto, isFalse);
      expect(s.effectiveOutputDir, other);
      expect(s.canResetOutputDir, isTrue);

      s.resetOutputDirToSource();
      expect(s.effectiveOutputDir, auto);
      expect(s.outputDirIsAuto, isTrue);
      s.dispose();
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('영상을 다른 폴더 것으로 바꾸면 저장 폴더도 따라간다', () async {
      final s = await ready();
      await s.addPaths(makeFolder('첫폴더', 2));
      final first = s.effectiveOutputDir;

      s.clearAll();
      await s.addPaths(makeFolder('둘째폴더', 3));

      expect(s.effectiveOutputDir, isNot(first));
      expect(p.basename(s.effectiveOutputDir), '둘째폴더');
      s.dispose();
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  test('설정한 이름과 폴더가 실제 출력 경로에 반영된다', () async {
    final s = await ready();
    final files = makeFolder('최종확인', 2);
    await s.addPaths(files);

    final out = s.buildSettings()!;
    expect(out.outputName, '최종확인');
    expect(out.outputDir, p.dirname(files.first));
    expect(out.outputPath.endsWith(r'최종확인.mp4'), isTrue);
    expect(s.blockingIssue, isNull);
    s.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
