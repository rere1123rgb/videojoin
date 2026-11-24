import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// ffmpeg / ffprobe 실행 파일 위치를 찾고, 프로세스를 안전하게 실행한다.
///
/// ## 한글 인코딩 주의
/// 1. `Process.run` 을 쓰지 않는다. stdout/stderr 를 `systemEncoding`(한국어
///    Windows 에서는 CP949)으로 디코딩하는데 ffmpeg 은 UTF-8 로 출력하므로 한글이
///    깨진다. `Process.start` 로 raw 바이트를 받아 UTF-8 로 직접 디코딩한다.
/// 2. `runInShell: false` 를 유지한다. cmd.exe 를 거치면 인자가 콘솔 코드페이지로
///    변환돼 한글 경로가 깨진다. false 면 CreateProcessW 로 UTF-16 그대로 넘어간다.
/// 3. concat 목록 파일은 BOM 없는 UTF-8 로 쓰고, 목록 안에는 ASCII 임시 파일명만 넣는다.
class FFTools {
  final String ffmpegPath;
  final String ffprobePath;

  const FFTools({required this.ffmpegPath, required this.ffprobePath});

  static FFTools? _cached;

  /// 실행 환경에 따라 ffmpeg 을 찾는다.
  /// - 배포본: videojoin.exe 와 같은 폴더 (또는 그 아래 tools/)
  /// - 개발 중(flutter run): 프로젝트 루트의 tools/
  static FFTools? locate() {
    if (_cached != null) return _cached;

    final exeDir = p.dirname(Platform.resolvedExecutable);
    final cwd = Directory.current.path;

    final roots = <String>[
      exeDir,
      p.join(exeDir, 'tools'),
      p.join(exeDir, 'ffmpeg'),
      cwd,
      p.join(cwd, 'tools'),
      // flutter run: build/windows/x64/runner/Debug 에서 프로젝트 루트로 거슬러 올라간다.
      p.normalize(p.join(exeDir, '..', '..', '..', '..', '..', 'tools')),
      p.normalize(p.join(exeDir, '..', '..', '..', '..', 'tools')),
    ];

    for (final r in roots) {
      final ff = p.join(r, 'ffmpeg.exe');
      final fp = p.join(r, 'ffprobe.exe');
      if (File(ff).existsSync() && File(fp).existsSync()) {
        _cached = FFTools(ffmpegPath: ff, ffprobePath: fp);
        return _cached;
      }
    }
    return null;
  }

  /// 테스트/CLI 에서 명시 경로를 주입할 때 사용.
  static void override(FFTools tools) => _cached = tools;

  static List<String> searchedRoots() {
    final exeDir = p.dirname(Platform.resolvedExecutable);
    return [exeDir, p.join(exeDir, 'tools'), p.join(Directory.current.path, 'tools')];
  }
}

/// 프로세스 실행 결과. 문자열은 항상 UTF-8 로 디코딩된 것.
class RunResult {
  final int exitCode;
  final String stdout;
  final String stderr;

  const RunResult(this.exitCode, this.stdout, this.stderr);

  bool get ok => exitCode == 0;
}

/// 프로세스를 실행하고 stdout/stderr 를 UTF-8 로 모아서 돌려준다.
///
/// [onStarted] 는 프로세스가 뜬 직후 pid 와 함께 불린다 (ProcessGuard 에 묶는 용도).
///
/// `allowMalformed: true`: ffmpeg 이 깨진 메타데이터 등 UTF-8 이 아닌 바이트를
/// 뱉을 수 있어, 예외 대신 U+FFFD 로 대체하고 진행한다.
Future<RunResult> runCaptured(
  String exe,
  List<String> args, {
  Duration? timeout,
  void Function(int pid)? onStarted,
}) async {
  final proc = await Process.start(exe, args, runInShell: false);
  try {
    onStarted?.call(proc.pid);
  } on Object {
    // 콜백 실패는 실행에 영향 없음.
  }

  final outBytes = <int>[];
  final errBytes = <int>[];

  final collecting = Future.wait([
    proc.stdout.forEach(outBytes.addAll),
    proc.stderr.forEach(errBytes.addAll),
  ]);

  int code;
  if (timeout != null) {
    try {
      code = await proc.exitCode.timeout(timeout);
    } on Object {
      proc.kill(ProcessSignal.sigkill);
      code = -1;
    }
  } else {
    code = await proc.exitCode;
  }

  await collecting;

  return RunResult(
    code,
    utf8.decode(outBytes, allowMalformed: true),
    utf8.decode(errBytes, allowMalformed: true),
  );
}
