import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 작업 로그. 실행한 ffmpeg 명령을 그대로 남겨 같은 명령으로 재현할 수 있게 한다.
///
/// 한글 파일명이 들어가므로 항상 **BOM 없는 UTF-8** 로 쓴다 (기본 CP949 는 깨진다).
class JobLog {
  final File file;
  final _buffer = StringBuffer();
  IOSink? _sink;

  JobLog(this.file);

  /// %LOCALAPPDATA%\videojoin\logs\ 아래. 엔진이 Flutter 없이도 돌도록 path_provider 대신 환경변수를 쓴다.
  static Directory logDirectory() {
    final base = Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.systemTemp.path;
    final dir = Directory(p.join(base, 'videojoin', 'logs'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static JobLog create() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final name = '${now.year}${two(now.month)}${two(now.day)}'
        '_${two(now.hour)}${two(now.minute)}${two(now.second)}.log';
    final f = File(p.join(logDirectory().path, name));
    final log = JobLog(f);
    log.line('videojoin 작업 로그  ${now.toIso8601String()}');
    log.line('OS: ${Platform.operatingSystemVersion}');
    return log;
  }

  void line(String s) {
    _buffer.writeln(s);
    _flushIfBig();
  }

  void section(String title) {
    _buffer.writeln('');
    _buffer.writeln('=== $title ===');
    _flushIfBig();
  }

  void command(String exe, List<String> args, {String? cwd}) {
    final quoted = args.map((a) => a.contains(' ') ? '"$a"' : a).join(' ');
    if (cwd != null) _buffer.writeln('[cwd] $cwd');
    _buffer.writeln('[cmd] "$exe" $quoted');
    _flushIfBig();
  }

  /// 오류는 대개 stderr 끝에 있으므로 마지막 부분만 남긴다.
  void ffmpegOutput(String stderr, {int tailLines = 40}) {
    final lines = stderr.trimRight().split('\n');
    final tail = lines.length <= tailLines
        ? lines
        : lines.sublist(lines.length - tailLines);
    for (final l in tail) {
      _buffer.writeln('  | ${l.trimRight()}');
    }
    _flushIfBig();
  }

  void _flushIfBig() {
    if (_buffer.length > 16384) flush();
  }

  void flush() {
    if (_buffer.isEmpty) return;
    try {
      _sink ??= file.openWrite(mode: FileMode.append, encoding: utf8);
      _sink!.write(_buffer.toString());
      _buffer.clear();
    } on Object {
      // 로그를 못 써도 인코딩 작업 자체는 계속되어야 한다.
    }
  }

  Future<void> close() async {
    flush();
    try {
      await _sink?.flush();
      await _sink?.close();
    } on Object {
      // 무시
    }
    _sink = null;
  }

  static void prune({int keep = 30}) {
    try {
      final dir = logDirectory();
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.log'))
          .toList()
        ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      for (final f in files.skip(keep)) {
        try {
          f.deleteSync();
        } on Object {
          // 무시
        }
      }
    } on Object {
      // 무시
    }
  }
}
