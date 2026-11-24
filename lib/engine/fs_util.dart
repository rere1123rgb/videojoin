import 'dart:io';

/// 폴더를 내용째로 지운다. 지워졌으면 true.
///
/// 폴더에 '읽기 전용' 속성이 붙어 있으면 Dart 의 삭제가 "액세스가 거부되었습니다"
/// 로 실패하는 경우가 있다. `rd` 는 그 속성을 무시하므로 실패했을 때만 한 번 더 시도한다.
bool forceDeleteDir(Directory dir, {bool recursive = true}) {
  if (!dir.existsSync()) return true;
  try {
    dir.deleteSync(recursive: recursive);
    return true;
  } on Object {
    // rd 로 재시도.
  }
  try {
    Process.runSync(
      'cmd',
      ['/c', 'rd', if (recursive) '/s', '/q', dir.path],
      runInShell: false,
    );
  } on Object {
    // 반환값으로 판단한다.
  }
  return !dir.existsSync();
}
