// process_guard_test.dart 가 띄우는 보조 프로그램.
//
// 오래 도는 자식 프로세스를 하나 띄워 ProcessGuard 로 묶고, 두 pid 를
// 알려 준 뒤 가만히 기다린다. 테스트가 이 프로그램을 강제로 죽였을 때
// 자식도 함께 사라지는지 본다.

import 'dart:io';

import 'package:videojoin/engine/suspend.dart';

Future<void> main() async {
  final child = await Process.start(
    'ping',
    ['-n', '120', '127.0.0.1'],
    runInShell: false,
  );
  final attached = ProcessGuard.attach(child.pid);
  stdout.writeln('READY self=$pid child=${child.pid} attached=$attached');
  await stdout.flush();
  await Future<void>.delayed(const Duration(minutes: 5));
}
