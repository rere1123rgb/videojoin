// 프로그램이 죽으면 ffmpeg 도 함께 죽는지 검증.
//
// 정리 코드를 거치지 않는 "강제 종료"로 확인한다. 정상 종료만 시험하면
// 비정상 종료 때 ffmpeg 이 남는 문제를 놓친다.
//
//   flutter test test/process_guard_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

bool alive(int pid) {
  final r = Process.runSync('tasklist', ['/FI', 'PID eq $pid', '/NH'],
      stdoutEncoding: latin1, stderrEncoding: latin1);
  return (r.stdout as String).contains(' $pid ');
}

void main() {
  test('주인이 강제로 죽으면 묶어 둔 자식도 사라진다', () async {
    // 테스트 러너는 dart 가 아니라 flutter_tester 라서 보조 프로그램은
    // 따로 띄운다.
    final helper = await Process.start(
      'dart',
      ['run', 'test/helpers/guard_child.dart'],
      runInShell: true,
    );

    int? self;
    int? child;
    var attached = false;
    final ready = helper.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((l) => l.contains('READY'), orElse: () => '');
    helper.stderr.drain<void>();

    final line = await ready.timeout(const Duration(minutes: 3));
    final m = RegExp(r'self=(\d+) child=(\d+) attached=(\w+)').firstMatch(line);
    expect(m, isNotNull, reason: '보조 프로그램이 준비되지 않았다: "$line"');
    self = int.parse(m!.group(1)!);
    child = int.parse(m.group(2)!);
    attached = m.group(3) == 'true';

    addTearDown(() {
      // 실패하더라도 ping 이 남지 않게 한다.
      Process.runSync('taskkill', ['/F', '/PID', '$child']);
      Process.runSync('taskkill', ['/F', '/PID', '$self']);
    });

    expect(attached, isTrue, reason: '작업 개체에 묶지 못했다');
    expect(alive(child), isTrue, reason: '자식이 뜨지 않았다');

    // 정리할 기회를 전혀 주지 않고 죽인다.
    Process.runSync('taskkill', ['/F', '/PID', '$self']);

    var gone = false;
    for (var i = 0; i < 50 && !gone; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      gone = !alive(child);
    }
    expect(gone, isTrue, reason: '주인이 죽었는데 자식이 계속 돌고 있다');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
