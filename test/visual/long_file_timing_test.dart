// 긴 영상(수 분 이상)에서 편집 창이 얼마나 빨리 반응하는지 잰다.
// 큰 파일이 필요해서 평소에는 건너뛴다.
//
//   $env:VJ_LONG_FILE = 'D:\long4k.mp4'; flutter test test/visual/long_file_timing_test.dart
//
// VJ_LONG_LOAD=1 이면 다른 인코딩을 같이 돌리면서 잰다(대기열 작업 중 편집).

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:videojoin/engine/ffmpeg_tools.dart';
import 'package:videojoin/engine/frame_grabber.dart';
import 'package:videojoin/engine/fs_util.dart';
import 'package:videojoin/engine/prober.dart';
import 'package:videojoin/player/audio_track.dart';
import 'package:videojoin/player/frame_pump.dart';

final _root = Directory.current.path;
final _tools = FFTools(
  ffmpegPath: p.join(_root, 'tools', 'ffmpeg.exe'),
  ffprobePath: p.join(_root, 'tools', 'ffprobe.exe'),
);
final _file = Platform.environment['VJ_LONG_FILE'];
final _load = Platform.environment['VJ_LONG_LOAD'] == '1';

void main() {
  test('긴 영상 반응 시간', () async {
    final spec = await Prober(_tools).probe(_file!);
    expect(spec.ok, isTrue);
    final work = Directory.systemTemp.createTempSync('vj_long_');
    Process? load;
    if (_load) {
      // 대기열에서 4K 를 다시 만들고 있는 상황을 흉내 낸다.
      load = await Process.start(_tools.ffmpegPath, [
        '-hide_banner', '-nostdin', '-y', '-i', _file!,
        '-vf', 'scale=1920:1080', '-c:v', 'libx264', '-preset', 'medium',
        '-f', 'mpegts', p.join(work.path, 'load.ts'),
      ]);
      await Future<void>.delayed(const Duration(seconds: 2));
    }

    final out = StringBuffer('파일 ${spec.durationSec.toStringAsFixed(0)}초 '
        '${spec.displayWidth}x${spec.displayHeight} 부하=${_load ? "있음" : "없음"}\n');
    try {
      // 1) 파형(소리 읽기) — 처음 열 때
      final cacheDir = Directory(p.join(work.path, 'audio'))..createSync();
      var sw = Stopwatch()..start();
      final track =
          await AudioPrep(_tools, cacheDirOverride: cacheDir).prepare(spec);
      out.writeln('파형 준비(첫 열기): ${sw.elapsedMilliseconds}ms '
          '(${track == null ? "실패" : "${track.peaks.length}칸"})');
      sw = Stopwatch()..start();
      await AudioPrep(_tools, cacheDirOverride: cacheDir).prepare(spec);
      out.writeln('파형 준비(두 번째): ${sw.elapsedMilliseconds}ms');

      // 2) 정지 장면: 90% 지점, 그리고 그 근처로 옮기기
      final g = FrameGrabber(_tools);
      for (final frac in [0.9, 0.5, 0.1234]) {
        sw = Stopwatch()..start();
        await g.frameAt(spec, spec.durationSec * frac + 0.0731, waitTurn: false);
        out.writeln('정지 장면 ${(frac * 100).round()}%: ${sw.elapsedMilliseconds}ms');
      }

      // 3) 장면 띠 12장
      sw = Stopwatch()..start();
      await g.filmstrip(spec, 12);
      out.writeln('장면 띠 12장: ${sw.elapsedMilliseconds}ms');

      // 4) 재생 시작(첫 그림까지): 90% 지점
      for (final frac in [0.9, 0.3]) {
        final done = Completer<void>();
        final pump = FramePump(
          tools: _tools,
          spec: spec,
          fromSec: spec.durationSec * frac,
          untilSec: spec.durationSec * frac + 1.0,
        )..onEnded = () {
            if (!done.isCompleted) done.complete();
          };
        await pump.start();
        await done.future.timeout(const Duration(seconds: 20));
        await pump.exitCode.timeout(const Duration(seconds: 3));
        out.writeln('재생 ${(frac * 100).round()}% 첫 그림: '
            '${pump.firstFrameLatency?.inMilliseconds}ms, '
            '1초에 보임 ${pump.framesShown} 버림 ${pump.framesDropped}');
      }
    } finally {
      load?.kill();
      await load?.exitCode;
      forceDeleteDir(work);
      // ignore: avoid_print
      print(out);
    }
  }, skip: _file == null, timeout: const Timeout(Duration(minutes: 10)));
}
