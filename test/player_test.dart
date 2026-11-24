// 편집 화면 재생기 검증. 실제 ffmpeg 과 실제 시간으로 돈다.
//
// ui.decodeImageFromPixels 는 Flutter 엔진이 있어야 해서 여기서는 그 아래층인
// FramePump(프레임 조립·속도 맞추기·끝 판정)를 직접 시험한다. testWidgets 는
// 가짜 시간이라 진짜 프로세스를 기다리면 멈추므로 쓰지 않는다.
//
// 소리가 실제로 스피커까지 나가는지는 tool/play_audio_check.dart 가 본다.
//
//   flutter test test/player_test.dart

// 실시간 속도를 재는 테스트라, 전체 테스트가 동시에 인코딩을 돌려 CPU 가
// 바쁠 때는 시계가 늦게 끝날 수 있다. 그럴 때만 다시 잰다.
@Retry(2)
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:videojoin/engine/ffmpeg_tools.dart';
import 'package:videojoin/engine/fs_util.dart';
import 'package:videojoin/engine/models.dart';
import 'package:videojoin/engine/prober.dart';
import 'package:videojoin/player/audio_out.dart';
import 'package:videojoin/player/audio_track.dart';
import 'package:videojoin/player/clip_player.dart';
import 'package:videojoin/player/frame_pump.dart';

final _root = Directory.current.path;
final _tools = FFTools(
  ffmpegPath: p.join(_root, 'tools', 'ffmpeg.exe'),
  ffprobePath: p.join(_root, 'tools', 'ffprobe.exe'),
);

Future<VideoSpec> _spec(String name) =>
    Prober(_tools).probe(p.join(_root, 'testdata', name));

/// 그 PID 의 프로세스가 아직 살아 있는가. 다른 프로그램의 ffmpeg 과 헷갈리지
/// 않도록 이름으로 세지 않고 우리가 띄운 PID 로만 본다.
Future<bool> _alive(int pid) async {
  final r = await Process.run('tasklist', ['/FI', 'PID eq $pid', '/NH']);
  return (r.stdout as String).toLowerCase().contains('ffmpeg');
}

/// 이 테스트 프로세스가 띄운 ffmpeg 수.
Future<int> _childFfmpegCount() async {
  final r = await Process.run('powershell', [
    '-NoProfile',
    '-Command',
    "@(Get-CimInstance Win32_Process -Filter \"ParentProcessId=$pid AND Name='ffmpeg.exe'\").Count",
  ]);
  return int.tryParse((r.stdout as String).trim()) ?? -1;
}

class _Run {
  final FramePump pump;
  final Completer<void> ended = Completer<void>();
  final List<int> indexes = [];
  final List<double> shownAt = [];
  _Run(this.pump) {
    pump.onFrame = (bytes, i) {
      expect(bytes.length, pump.geometry.frameBytes);
      indexes.add(i);
      shownAt.add(pump.clockSec);
    };
    pump.onEnded = () {
      if (!ended.isCompleted) ended.complete();
    };
  }
}

Future<_Run> _play(VideoSpec spec, double from,
    {double? until, bool hwaccel = false, Duration limit = const Duration(seconds: 20)}) async {
  final run = _Run(FramePump(
      tools: _tools,
      spec: spec,
      fromSec: from,
      untilSec: until,
      hwaccel: hwaccel));
  await run.pump.start();
  await run.ended.future.timeout(limit);
  await run.pump.exitCode.timeout(const Duration(seconds: 3));
  return run;
}

void main() {
  late Directory cache;

  setUpAll(() {
    cache = Directory(p.join(_root, 'out', 'player_test'));
    forceDeleteDir(cache);
    cache.createSync(recursive: true);
  });

  tearDownAll(() {
    AudioOut.stop();
    forceDeleteDir(cache);
  });

  group('AudioPrep', () {
    test('소리 길이·파형이 맞고, 두 번째는 캐시를 쓴다', () async {
      final spec = await _spec('same_a.mp4');
      final prep = AudioPrep(_tools, cacheDirOverride: cache);
      final before = AudioPrep.extractCount;
      final sw = Stopwatch()..start();
      final t = await prep.prepare(spec, buckets: 800);
      final firstMs = sw.elapsedMilliseconds;
      expect(t, isNotNull);
      expect(AudioPrep.extractCount, before + 1);
      expect((t!.durationSec - spec.durationSec).abs(), lessThan(0.1),
          reason: 'wav ${t.durationSec} vs 원본 ${spec.durationSec}');
      expect(t.peaks.length, 800);
      expect(t.peaks.reduce((a, b) => a > b ? a : b), 1.0);
      expect(t.peaks.every((v) => v >= 0 && v <= 1), isTrue);
      expect(t.sampleRate, 22050);

      sw.reset();
      final t2 = await prep.prepare(spec, buckets: 800);
      final secondMs = sw.elapsedMilliseconds;
      expect(t2, isNotNull);
      expect(AudioPrep.extractCount, before + 1, reason: '두 번째는 다시 뽑으면 안 된다');
      expect(t2!.peaks, t.peaks);
      // ignore: avoid_print
      print('AudioPrep same_a: 처음 ${firstMs}ms, 캐시 ${secondMs}ms, '
          'dur ${t.durationSec.toStringAsFixed(3)} / ${spec.durationSec}');
    });

    test('동시에 두 번 불러도 한 번만 뽑는다', () async {
      final spec = await _spec('same_b.mp4');
      final prep = AudioPrep(_tools, cacheDirOverride: cache);
      final before = AudioPrep.extractCount;
      final r = await Future.wait([prep.prepare(spec), prep.prepare(spec)]);
      expect(r[0], isNotNull);
      expect(r[1], isNotNull);
      expect(AudioPrep.extractCount, before + 1);
    });

    test('소리 있는 모든 형식에서 길이가 맞게 뽑힌다', () async {
      final prep = AudioPrep(_tools, cacheDirOverride: cache);
      final lines = <String>[];
      for (final name in const [
        'legacy.avi',
        'vfr_phone.mp4',
        'hdr_4k.mp4',
        'uhd_4k.mp4',
        'portrait_rot90.mp4',
        'audio_51.mp4',
        'anamorphic.mp4',
        'ntsc_2997.mp4',
      ]) {
        final spec = await _spec(name);
        if (!spec.hasAudio) {
          lines.add('$name: 소리 없음');
          continue;
        }
        final t = await prep.prepare(spec);
        expect(t, isNotNull, reason: name);
        lines.add('$name: wav ${t!.durationSec.toStringAsFixed(3)} / '
            '원본 ${spec.durationSec.toStringAsFixed(3)}');
        expect((t.durationSec - spec.durationSec).abs(), lessThan(0.15),
            reason: name);
      }
      // ignore: avoid_print
      print(lines.join('\n'));
    });

    test('소리 없는 영상은 null', () async {
      final spec = await _spec('no_audio.mp4');
      expect(spec.hasAudio, isFalse);
      expect(await AudioPrep(_tools, cacheDirOverride: cache).prepare(spec),
          isNull);
    });

    test('한글 경로', () async {
      final spec = await _spec('한글 영상 테스트.mp4');
      final t = await AudioPrep(_tools, cacheDirOverride: cache).prepare(spec);
      expect(t, isNotNull);
      expect((t!.durationSec - spec.durationSec).abs(), lessThan(0.1));
    });

    test('data 앞에 LIST·홀수 크기 조각이 있어도 머리말을 맞게 읽는다', () {
      final f = File(p.join(cache.path, 'list_test.wav'));
      final b = BytesBuilder();
      void tag(String s) => b.add(s.codeUnits);
      void u32(int v) =>
          b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
      void u16(int v) =>
          b.add((ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List());
      tag('RIFF');
      u32(0); // 크기는 엉터리여도 된다
      tag('WAVE');
      tag('fmt ');
      u32(16);
      u16(1);
      u16(1);
      u32(22050);
      u32(44100);
      u16(2);
      u16(16);
      tag('LIST');
      u32(5); // 홀수 → 1바이트 채움
      b.add([1, 2, 3, 4, 5, 0]);
      tag('data');
      u32(0xFFFFFFFF); // 크기를 못 채운 스트리밍 WAV
      b.add(List.filled(200, 7));
      f.writeAsBytesSync(b.toBytes());
      final raf = f.openSync();
      final info = AudioPrep.parseHeader(raf);
      raf.closeSync();
      expect(info, isNotNull);
      expect(info!.dataOffset, 12 + 24 + 8 + 6 + 8);
      expect(info.dataBytes, 200);
      expect(info.sampleRate, 22050);
    });

    test('AudioOut.prepare 는 지정 구간만 짝수 바이트로 잘라 쓴다', () async {
      final spec = await _spec('same_a.mp4');
      final t = (await AudioPrep(_tools, cacheDirOverride: cache).prepare(spec))!;
      final sw = Stopwatch()..start();
      final c = await AudioOut.prepare(t, 1.0, untilSec: 2.5);
      final ms = sw.elapsedMilliseconds;
      expect(c, isNotNull);
      final len = File(c!.path).lengthSync();
      expect(len, 44 + 1.5 * 22050 * 2);
      expect(c.startSec, closeTo(1.0, 1e-4));
      expect(c.endSec, closeTo(2.5, 1e-4));
      final raf = File(c.path).openSync();
      final info = AudioPrep.parseHeader(raf)!;
      raf.closeSync();
      expect(info.dataBytes, 1.5 * 22050 * 2);
      // 원본의 같은 위치 바이트와 같아야 한다.
      final src = File(t.wavPath).readAsBytesSync();
      final out = File(c.path).readAsBytesSync();
      final at = t.dataOffset + 22050 * 2;
      expect(out.sublist(44, 44 + 4000), src.sublist(at, at + 4000));
      // ignore: avoid_print
      print('AudioOut.prepare 1.5s: ${ms}ms');
    });
  });

  group('FramePump', () {
    test('크기 계산: 화면 크기(회전 반영)를 긴 변 960 에 맞추고 짝수, 30fps 이하', () async {
      final land = PlayGeometry.of(await _spec('uhd_4k.mp4'));
      expect(land.width, 960);
      expect(land.height, 540);
      expect(land.fps.toDouble(), lessThanOrEqualTo(30));
      final rot = await _spec('portrait_rot90.mp4');
      final g = PlayGeometry.of(rot);
      expect(g.height, rot.displayHeight < 960 ? rot.displayHeight & ~1 : 960);
      expect(g.width < g.height, isTrue, reason: '세로 영상은 세로로');
      expect(g.width.isEven && g.height.isEven, isTrue);
    });

    test('2초 구간: 장수와 속도가 실제 시간과 맞고 untilSec 에서 멈춘다', () async {
      final spec = await _spec('same_a.mp4');
      final run = await _play(spec, 0.5, until: 2.5);
      final g = run.pump.geometry;
      final expected = 2.0 * g.fps.toDouble();
      final got = run.pump.framesShown + run.pump.framesDropped;
      final span = run.pump.lastFrameAt!.inMicroseconds / 1e6;
      // ignore: avoid_print
      print('same_a 0.5~2.5: ${g.width}x${g.height}@${g.fps} '
          '첫 프레임 ${run.pump.firstFrameLatency!.inMilliseconds}ms, '
          '보임 ${run.pump.framesShown} 버림 ${run.pump.framesDropped} '
          '(기대 ${expected.toStringAsFixed(1)}), 마지막 프레임 ${span.toStringAsFixed(3)}s, '
          '끝 시계 ${run.pump.clockSec.toStringAsFixed(3)}s');
      expect(got, closeTo(expected, expected * 0.25));
      // 마지막 프레임은 (장수-1)/F 시점에 나와야 한다.
      final idealLast = g.ptsOf(got - 1);
      expect(span, closeTo(idealLast, idealLast * 0.25));
      expect(run.pump.clockSec, closeTo(2.0, 0.5));
      expect(run.indexes, orderedEquals([...run.indexes]..sort()));
      expect(await _alive(run.pump.pid!), isFalse);
    });

    test('파일 끝까지 틀면 끝을 알린다', () async {
      final spec = await _spec('same_a.mp4');
      final run = await _play(spec, spec.durationSec - 1.0);
      expect(run.pump.framesShown, greaterThan(10));
      expect(run.pump.clockSec, closeTo(1.0, 0.4));
    });

    test('끝을 넘은 시각이면 바로 끝난다(멈춰 있지 않는다)', () async {
      final spec = await _spec('same_a.mp4');
      final run = await _play(spec, spec.durationSec + 5,
          limit: const Duration(seconds: 10));
      expect(run.pump.framesShown, 0);
    });

    test('재생 중 stop() 하면 ffmpeg 이 남지 않고 onEnded 도 안 부른다', () async {
      final spec = await _spec('uhd_4k.mp4');
      final run = _Run(FramePump(tools: _tools, spec: spec, fromSec: 0));
      await run.pump.start();
      // 고정 시간만 기다리면 CPU 가 바쁠 때 4K 첫 프레임이 늦어 indexes 가
      // 비므로, 첫 프레임이 보일 때까지 기다린다(최대 20초).
      final waitSw = Stopwatch()..start();
      while (run.indexes.isEmpty && waitSw.elapsedMilliseconds < 20000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(run.indexes, isNotEmpty);
      final pid = run.pump.pid!;
      expect(await _alive(pid), isTrue);
      await run.pump.stop();
      expect(await _alive(pid), isFalse);
      final shown = run.indexes.length;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(run.indexes.length, shown, reason: '멈춘 뒤에 프레임이 오면 안 된다');
      expect(run.ended.isCompleted, isFalse);
    });

    test('끝이 시작 이하인 구간: 첫 틱에서 끝나도 8ms 타이머·ffmpeg 이 남지 않는다', () async {
      final spec = await _spec('same_a.mp4');
      final run = await _play(spec, 1.0, until: 1.0);
      expect(run.pump.timerActive, isFalse, reason: '끝나자마자 타이머가 없어야 한다');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(run.pump.timerActive, isFalse, reason: '끝난 뒤 새로 생기면 안 된다');
      expect(await _alive(run.pump.pid!), isFalse);
      expect(run.pump.isRunning, isFalse);
    });

    test('ClipPlayer: 시작과 거의 같은 끝은 ffmpeg 을 띄우지 않고 바로 끝난다', () async {
      final spec = await _spec('same_a.mp4');
      final player = ClipPlayer(tools: _tools, spec: spec);
      var ended = 0;
      player.onEnded = () => ended++;
      await player.play(1.0, untilSec: 1.03, muted: true);
      expect(ended, 1);
      expect(player.playing.value, isFalse);
      expect(player.position.value, closeTo(1.03, 1e-6));
      expect(await _childFfmpegCount(), 0);
      player.dispose();
    });

    test('재생·멈춤을 빠르게 10번 반복해도 남는 프로세스가 없다', () async {
      final spec = await _spec('same_a.mp4');
      final pumps = <FramePump>[];
      for (var i = 0; i < 10; i++) {
        final pump = FramePump(tools: _tools, spec: spec, fromSec: i * 0.3);
        pumps.add(pump);
        unawaited(pump.start());
        // 띄우는 중, 첫 프레임 직후 등 여러 순간에 멈춘다.
        await Future<void>.delayed(Duration(milliseconds: (i % 4) * 60));
        await pump.stop();
      }
      // 마지막은 끝까지 틀어 정상 동작 확인.
      final last = await _play(spec, 0, until: 0.6);
      expect(last.pump.framesShown, greaterThan(5));
      for (final pump in pumps) {
        final pid = pump.pid;
        if (pid != null) expect(await _alive(pid), isFalse, reason: 'pid $pid');
      }
    });

    test('한글 경로', () async {
      final spec = await _spec('한글 영상 테스트.mp4');
      final run = await _play(spec, 0, until: 1.0);
      expect(run.pump.framesShown, greaterThan(5));
    });

    test('ClipPlayer: 그림이 실제로 만들어지고 끝에서 멈춘다(소리 없이)', () async {
      final spec = await _spec('same_a.mp4');
      final player = ClipPlayer(tools: _tools, spec: spec);
      final ended = Completer<void>();
      player.onEnded = ended.complete;
      var frames = 0;
      player.frame.addListener(() => frames++);
      await player.play(1.0, untilSec: 2.0, muted: true);
      expect(player.playing.value, isTrue);
      await ended.future.timeout(const Duration(seconds: 10));
      expect(player.playing.value, isFalse);
      final img = player.frame.value;
      expect(img, isNotNull);
      expect(img!.width, player.geometry.width);
      expect(img.height, player.geometry.height);
      expect(player.position.value, closeTo(2.0, 0.15));
      // ignore: avoid_print
      print('ClipPlayer 1s: 그림 $frames장 바뀜, 끝 위치 ${player.position.value.toStringAsFixed(3)}');
      expect(frames, greaterThan(20));

      // 재생 중 다시 play → 앞 재생은 조용히 끝나고(onEnded 없음) 새로 돈다.
      var endedCount = 0;
      player.onEnded = () => endedCount++;
      await player.play(0, untilSec: 3.0, muted: true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await player.play(2.0, untilSec: 2.5, muted: true);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(endedCount, 1);
      expect(player.position.value, closeTo(2.5, 0.15));
      player.dispose();
    });

    test('ClipPlayer: 소리가 있으면 첫 그림과 함께 소리를 틀고 끝에서 끈다(0.5초 소리)',
        () async {
      final spec = await _spec('same_a.mp4');
      final player = ClipPlayer(tools: _tools, spec: spec);
      player.audio =
          await AudioPrep(_tools, cacheDirOverride: cache).prepare(spec);
      expect(player.audio, isNotNull);
      final ended = Completer<void>();
      player.onEnded = ended.complete;
      var startedWithFrame = false;
      player.frame.addListener(() {
        startedWithFrame = startedWithFrame || AudioOut.started;
      });
      await player.play(1.0, untilSec: 1.5);
      await ended.future.timeout(const Duration(seconds: 10));
      expect(startedWithFrame, isTrue, reason: '그림이 나올 때 소리도 나고 있어야 한다');
      // 끝에서 소리 끄기를 kAudioLeadMs 미룬다(마지막 소리가 잘리지 않게).
      expect(AudioOut.stopPending || !AudioOut.started, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: kAudioLeadMs + 150));
      expect(AudioOut.started, isFalse, reason: '끝나면 소리를 꺼야 한다');
      player.dispose();
    });

    test('ClipPlayer: 소리 조각이 끝나면 다음 조각을 이어 튼다(조각 0.6초로 줄여서, 1.5초 소리)',
        () async {
      final spec = await _spec('same_a.mp4');
      final player = ClipPlayer(tools: _tools, spec: spec);
      player.audio =
          await AudioPrep(_tools, cacheDirOverride: cache).prepare(spec);
      final ended = Completer<void>();
      player.onEnded = ended.complete;
      final saved = AudioOut.maxChunkSec;
      AudioOut.maxChunkSec = 0.6;
      final before = AudioOut.startCount;
      try {
        await player.play(1.0, untilSec: 2.5);
        await ended.future.timeout(const Duration(seconds: 10));
      } finally {
        AudioOut.maxChunkSec = saved;
      }
      // 1.0~1.6, 1.6~2.2, 2.2~2.5 세 조각.
      expect(AudioOut.startCount - before, 3);
      await Future<void>.delayed(const Duration(milliseconds: kAudioLeadMs + 150));
      expect(AudioOut.started, isFalse);
      player.dispose();
    });

    test('ClipPlayer: 기다리지 않고 play 를 연달아 부르고 stop 해도 남는 재생·프로세스가 없다',
        () async {
      final spec = await _spec('same_a.mp4');
      final player = ClipPlayer(tools: _tools, spec: spec);
      var endedCount = 0;
      player.onEnded = () => endedCount++;

      // 연타 10번 후 멈춤.
      for (var i = 0; i < 10; i++) {
        unawaited(player.play(i * 0.2, untilSec: 3.5, muted: true));
        await Future<void>.delayed(Duration(milliseconds: (i % 3) * 30));
      }
      final sw = Stopwatch()..start();
      await player.stop();
      final stopMs = sw.elapsedMilliseconds;
      expect(player.playing.value, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(player.playing.value, isFalse, reason: '멈춘 뒤 다시 재생되면 안 된다');
      expect(await _childFfmpegCount(), 0);

      // play 직후 곧바로 stop.
      unawaited(player.play(0.5, untilSec: 3.5, muted: true));
      await player.stop();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(player.playing.value, isFalse);
      expect(await _childFfmpegCount(), 0);

      // 재생 중 stop 이 걸리는 시간(다시 찾아가기 체감 지연에 더해진다).
      await player.play(0.5, untilSec: 3.5, muted: true);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      // 세는 방법이 맞는지 확인: 재생 중에는 정확히 1개.
      expect(await _childFfmpegCount(), 1);
      sw.reset();
      await player.stop();
      final stopMs2 = sw.elapsedMilliseconds;
      expect(await _childFfmpegCount(), 0);
      expect(endedCount, 0);
      // ignore: avoid_print
      print('ClipPlayer stop(): 연타 직후 ${stopMs}ms, 재생 중 ${stopMs2}ms');
      player.dispose();
    });

    test('ClipPlayer: 디코딩이 느리면 소리는 두고 화면만 줄여 다시 띄워 시계를 따라잡는다',
        () async {
      // 12초짜리를 만든다(4초 원본을 3번 이어 붙임).
      final long = p.join(cache.path, 'long12.mp4');
      final r = await runCaptured(_tools.ffmpegPath, [
        '-hide_banner', '-nostdin', '-v', 'error', '-y',
        '-stream_loop', '2', '-i', p.join(_root, 'testdata', 'same_a.mp4'),
        '-c', 'copy', long,
      ]);
      expect(r.ok, isTrue, reason: r.stderr);
      final spec = await Prober(_tools).probe(long);
      expect(spec.durationSec, greaterThan(11));
      final player = ClipPlayer(tools: _tools, spec: spec);
      // 처음 ffmpeg 만 0.35배속으로 입력을 읽게 해서 느린 PC 를 흉내.
      player.debugFirstPumpInputArgs = const ['-readrate', '0.35'];
      var ended = false;
      player.onEnded = () => ended = true;
      await player.play(0, untilSec: 10, muted: true);

      final sw = Stopwatch()..start();
      double? lagAtDetect;
      var maxLagBefore = 0.0;
      while (!player.lagging.value && sw.elapsedMilliseconds < 8000) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (player.debugLagSec > maxLagBefore) maxLagBefore = player.debugLagSec;
      }
      expect(player.lagging.value, isTrue, reason: '느림을 알아채야 한다');
      lagAtDetect = maxLagBefore;
      final posAtDetect = player.position.value;
      final detectedAt = sw.elapsedMilliseconds;

      // 다시 띄운 직후 첫 그림이 나올 시간을 주고, 그 뒤 3초 동안 늦음을 잰다.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      var maxLagAfter = 0.0;
      final until = sw.elapsedMilliseconds + 3000;
      while (sw.elapsedMilliseconds < until) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (player.debugLagSec > maxLagAfter) maxLagAfter = player.debugLagSec;
      }
      // ignore: avoid_print
      print('느린 디코더 복구: ${detectedAt}ms 에 감지(그때까지 최대 늦음 '
          '${lagAtDetect.toStringAsFixed(2)}s), 복구 후 최대 늦음 '
          '${maxLagAfter.toStringAsFixed(2)}s, 위치 ${player.position.value.toStringAsFixed(2)}');
      expect(maxLagBefore, greaterThan(0.7));
      expect(maxLagAfter, lessThan(0.5), reason: '다시 띄운 뒤에는 시계에 붙어야 한다');
      // 위치는 시계를 따라 앞으로 갔다(늦은 프레임 시각이 아니라).
      expect(player.position.value, greaterThan(posAtDetect + 1.0));
      expect(ended, isFalse);
      await player.stop();
      expect(player.lagging.value, isFalse);
      expect(await _childFfmpegCount(), 0);
      player.dispose();
    });

    for (final name in const [
      'uhd_4k.mp4',
      'hdr_4k.mp4',
      'portrait_rot90.mp4',
      'legacy.avi',
      'vfr_phone.mp4',
      'anamorphic.mp4',
    ]) {
      test('형식별 실시간 재생: $name', () async {
        final spec = await _spec(name);
        expect(spec.ok, isTrue);
        final from = spec.durationSec > 3 ? 1.0 : 0.0;
        final len = spec.durationSec - from < 2 ? spec.durationSec - from : 2.0;
        final res = <String>[];
        for (final hw in const [false, true]) {
          final run = await _play(spec, from, until: from + len, hwaccel: hw);
          final g = run.pump.geometry;
          final got = run.pump.framesShown + run.pump.framesDropped;
          final expected = len * g.fps.toDouble();
          res.add('${hw ? 'hw' : 'sw'}: 첫 ${run.pump.firstFrameLatency!.inMilliseconds}ms '
              '보임 ${run.pump.framesShown} 버림 ${run.pump.framesDropped}/${expected.toStringAsFixed(0)}');
          expect(got, closeTo(expected, expected * 0.25), reason: '$name hw=$hw');
          // 늦어서 버린 장이 많으면 실시간을 못 따라간 것이다.
          expect(run.pump.framesDropped, lessThan(expected * 0.25),
              reason: '$name hw=$hw 실시간을 못 따라감');
          if (!hw) {
            res.insert(0, '${g.width}x${g.height}@${g.fps}');
          }
        }
        // ignore: avoid_print
        print('$name: ${res.join(' | ')}');
      });
    }
  });
}
