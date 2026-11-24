// 소리가 정말 스피커(기본 출력 장치)까지 나가는지 확인한다.
//
// 이 프로세스(dart.exe)의 오디오 세션 미터(IAudioMeterInformation)를 읽어
// PlaySoundW 소리가 실제로 나가는지 잰다. 약 1.5초간 소리가 난다.
//
//   dart run tool/play_audio_check.dart
//   dart run tool/play_audio_check.dart --sync   (FramePump 으로 화면과 함께 틀어
//       ffmpeg 첫 프레임 지연, 소리 시작 대비 화면 시계 출발, 실제로 들린 시각을 잰다)

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:videojoin/engine/ffmpeg_tools.dart';
import 'package:videojoin/engine/fs_util.dart';
import 'package:videojoin/engine/prober.dart';
import 'package:videojoin/player/audio_out.dart';
import 'package:videojoin/player/audio_track.dart';
import 'package:videojoin/player/frame_pump.dart';

// 세션 미터를 읽는 C#. PowerShell 5.1 의 Add-Type 으로 컴파일한다.
const _meterPs1 = r'''
param([int]$TargetPid, [int]$Ms)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCo {}
[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
  int EnumAudioEndpoints(int flow, int mask, out IntPtr devs);
  int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice dev);
}
[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
  int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
}
[ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioMeterInformation { int GetPeakValue(out float v); }
[ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionManager2 {
  int GetAudioSessionControl(IntPtr g, int f, out IntPtr c);
  int GetSimpleAudioVolume(IntPtr g, int f, out IntPtr v);
  int GetSessionEnumerator(out IAudioSessionEnumerator e);
}
[ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionEnumerator {
  int GetCount(out int n);
  int GetSession(int i, [MarshalAs(UnmanagedType.IUnknown)] out object s);
}
[ComImport, Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionControl2 {
  int GetState(out int s); int GetDisplayName(out IntPtr n); int SetDisplayName(IntPtr n, IntPtr g);
  int GetIconPath(out IntPtr p); int SetIconPath(IntPtr p, IntPtr g); int GetGroupingParam(out Guid g);
  int SetGroupingParam(IntPtr g, IntPtr c); int RegisterAudioSessionNotification(IntPtr n);
  int UnregisterAudioSessionNotification(IntPtr n); int GetSessionIdentifier(out IntPtr s);
  int GetSessionInstanceIdentifier(out IntPtr s); int GetProcessId(out uint pid);
}
public static class Meter {
  static IMMDevice dev;
  static IAudioMeterInformation ep;
  static IAudioSessionManager2 mgr;
  public static string Init() {
    var en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCo();
    int hr = en.GetDefaultAudioEndpoint(0, 1, out dev);
    if (hr != 0 || dev == null) return "NODEVICE " + hr;
    object o; Guid g = typeof(IAudioMeterInformation).GUID;
    dev.Activate(ref g, 23, IntPtr.Zero, out o); ep = (IAudioMeterInformation)o;
    g = typeof(IAudioSessionManager2).GUID;
    dev.Activate(ref g, 23, IntPtr.Zero, out o); mgr = (IAudioSessionManager2)o;
    return "OK";
  }
  public static float Endpoint() { float v; ep.GetPeakValue(out v); return v; }
  // 그 PID 의 세션 미터 최댓값. 세션이 없으면 -1.
  public static float Session(uint pid) {
    IAudioSessionEnumerator e; mgr.GetSessionEnumerator(out e);
    int n; e.GetCount(out n); float best = -1;
    for (int i = 0; i < n; i++) {
      object s; e.GetSession(i, out s);
      var c2 = s as IAudioSessionControl2; if (c2 == null) continue;
      uint p; c2.GetProcessId(out p); if (p != pid) continue;
      var m = s as IAudioMeterInformation; if (m == null) continue;
      float v; m.GetPeakValue(out v); if (v > best) best = v;
    }
    return best;
  }
}
"@
$r = [Meter]::Init()
if ($r -ne 'OK') { Write-Output $r; exit 2 }
Write-Output 'READY'
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.ElapsedMilliseconds -lt $Ms) {
  $t = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $e = [Meter]::Endpoint()
  $s = [Meter]::Session([uint32]$TargetPid)
  Write-Output ("S {0} {1:F4} {2:F4}" -f $t, $e, $s)
  Start-Sleep -Milliseconds 20
}
Write-Output 'DONE'
''';

Future<void> main(List<String> args) async {
  _long = args.contains('--long');
  _sync = args.contains('--sync');
  final root = Directory.current.path;
  final tools = FFTools(
    ffmpegPath: p.join(root, 'tools', 'ffmpeg.exe'),
    ffprobePath: p.join(root, 'tools', 'ffprobe.exe'),
  );
  final work = Directory(p.join(root, 'out', 'audio_check'));
  forceDeleteDir(work);
  work.createSync(recursive: true);
  var code = 1;
  try {
    code = await _run(tools, root, work);
  } finally {
    AudioOut.stop();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    forceDeleteDir(work);
  }
  exit(code);
}

/// `--long`: 10분짜리 소리에서 최대 크기(10분) 조각을 튼다. 조각이 클 때
/// PlaySoundW 가 파일을 읽느라 소리가 늦게 나는지 보려는 것이다.
var _long = false;

/// `--sync`: ClipPlayer 와 같은 순서(소리 조각 준비 → 첫 프레임 → 소리 시작 →
/// kAudioLeadMs 뒤 화면 시계 출발 → 끝에서 소리 정지 미룸)로 1.5초를 틀어 본다.
var _sync = false;

Future<AudioTrack?> _longTrack(FFTools tools, String root, Directory work) async {
  final out = p.join(work.path, 'long.wav');
  final r = await runCaptured(tools.ffmpegPath, [
    '-hide_banner', '-nostdin', '-v', 'error', '-y',
    '-stream_loop', '160', '-i', p.join(root, 'testdata', 'same_a.mp4'),
    '-vn', '-ac', '1', '-ar', '22050', '-c:a', 'pcm_s16le', '-t', '620',
    '-f', 'wav', out,
  ]);
  if (!r.ok) return null;
  final raf = File(out).openSync();
  final info = AudioPrep.parseHeader(raf);
  raf.closeSync();
  if (info == null) return null;
  return AudioTrack(
    wavPath: out,
    durationSec: info.dataBytes / (info.sampleRate * 2),
    peaks: const [],
    dataOffset: info.dataOffset,
    dataBytes: info.dataBytes,
  );
}

Future<int> _run(FFTools tools, String root, Directory work) async {
  final spec = await Prober(tools).probe(p.join(root, 'testdata', 'same_a.mp4'));
  final track = _long
      ? await _longTrack(tools, root, work)
      : await AudioPrep(tools, cacheDirOverride: work).prepare(spec);
  if (track == null) {
    stdout.writeln('실패: 소리를 준비하지 못했다');
    return 1;
  }
  stdout.writeln('소리 준비: ${track.durationSec.toStringAsFixed(3)}s');

  // BOM 붙은 UTF-8 로 써야 PowerShell 5.1 이 제대로 읽는다.
  final ps1 = File(p.join(work.path, 'meter.ps1'));
  ps1.writeAsBytesSync([0xEF, 0xBB, 0xBF, ...utf8.encode(_meterPs1)]);

  final meter = await Process.start('powershell', [
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ps1.path,
    '-TargetPid', '$pid', '-Ms', '3500',
  ]);
  final samples = <(int, double, double)>[];
  final ready = Completer<String>();
  final lines = meter.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((l) {
    if (!ready.isCompleted &&
        (l.startsWith('READY') || l.startsWith('NODEVICE'))) {
      ready.complete(l);
    }
    final m = RegExp(r'^S (\d+) ([\d.]+) (-?[\d.]+)').firstMatch(l);
    if (m != null) {
      samples.add((int.parse(m.group(1)!), double.parse(m.group(2)!),
          double.parse(m.group(3)!)));
    }
  });
  final err = StringBuffer();
  meter.stderr.transform(utf8.decoder).listen(err.write);

  final r = await ready.future
      .timeout(const Duration(seconds: 30), onTimeout: () => 'TIMEOUT');
  if (r != 'READY') {
    stdout.writeln('미터를 읽을 수 없다: $r $err');
    meter.kill();
    return 2;
  }

  await Future<void>.delayed(const Duration(milliseconds: 500));
  final sw = Stopwatch()..start();
  AudioChunk? chunk;
  var prepMs = 0.0;
  var playAt = 0;
  var ok = false;
  var startMs = 0.0;
  var stopAt = 0;
  var stopMs = 0.0;
  // --sync 전용 측정값.
  int? firstFrameWall;
  int? endWall;
  int? ffmpegFirstFrameMs;
  if (_sync) {
    final pump = FramePump(tools: tools, spec: spec, fromSec: 1.0, untilSec: 2.5);
    final chunkF = AudioOut.prepare(track, 1.0,
        untilSec: 2.5, first: true);
    pump.startGate = chunkF;
    pump.clockLeadSec = kAudioLeadMs / 1000;
    final done = Completer<void>();
    pump.onStarted = () {
      chunkF.then((c) {
        if (c == null) return;
        chunk = c;
        playAt = DateTime.now().millisecondsSinceEpoch;
        ok = AudioOut.start(c);
      });
    };
    pump.onFrame = (b, i) {
      firstFrameWall ??= DateTime.now().millisecondsSinceEpoch;
    };
    pump.onEnded = () {
      endWall = DateTime.now().millisecondsSinceEpoch;
      stopAt = endWall!;
      AudioOut.stopAfter(const Duration(milliseconds: kAudioLeadMs));
      done.complete();
    };
    await pump.start();
    await done.future.timeout(const Duration(seconds: 10));
    ffmpegFirstFrameMs = pump.firstFrameLatency?.inMilliseconds;
    // 미뤄 둔 정지가 실제로 불리는지까지 본 뒤 센다.
    await Future<void>.delayed(const Duration(milliseconds: kAudioLeadMs + 250));
    stopMs = AudioOut.started ? -1 : 0;
  } else {
    chunk = await AudioOut.prepare(track, 1.0, untilSec: _long ? null : 2.5);
    final c = chunk;
    stdout.writeln(
        '조각 길이 ${(c == null ? 0 : c.endSec - c.startSec).toStringAsFixed(1)}s');
    prepMs = sw.elapsedMicroseconds / 1000;
    if (c == null) {
      stdout.writeln('실패: 조각을 쓰지 못했다');
      meter.kill();
      return 1;
    }
    playAt = DateTime.now().millisecondsSinceEpoch;
    sw.reset();
    ok = AudioOut.start(c);
    startMs = sw.elapsedMicroseconds / 1000;
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    stopAt = DateTime.now().millisecondsSinceEpoch;
    sw.reset();
    AudioOut.stop();
    stopMs = sw.elapsedMicroseconds / 1000;
  }
  if (chunk == null) {
    stdout.writeln('실패: 조각을 쓰지 못했다');
    meter.kill();
    return 1;
  }

  await meter.exitCode.timeout(const Duration(seconds: 15), onTimeout: () {
    meter.kill();
    return -1;
  });
  await lines.cancel();

  double maxOf(Iterable<(int, double, double)> xs, bool session) =>
      xs.fold(-1.0, (m, s) => (session ? s.$3 : s.$2) > m ? (session ? s.$3 : s.$2) : m);
  final before = samples.where((s) => s.$1 < playAt);
  final during =
      samples.where((s) => s.$1 >= playAt + 150 && s.$1 <= stopAt);
  final after = samples.where((s) => s.$1 >= stopAt + 250);

  // 소리가 처음 미터에 잡힌 시각(시작 지연의 대략적인 값).
  final firstHeard = samples
      .where((s) => s.$1 >= playAt && s.$3 > 0.001)
      .map((s) => s.$1 - playAt)
      .firstOrNull;

  stdout.writeln('PlaySoundW 반환: $ok, prepare ${prepMs.toStringAsFixed(1)}ms, '
      'start ${startMs.toStringAsFixed(1)}ms, stop ${stopMs.toStringAsFixed(1)}ms');
  stdout.writeln('표본 ${samples.length}개 (전 ${before.length} / 중 ${during.length} / 후 ${after.length})');
  stdout.writeln('장치 전체 최대: 전 ${maxOf(before, false).toStringAsFixed(4)} '
      '중 ${maxOf(during, false).toStringAsFixed(4)} 후 ${maxOf(after, false).toStringAsFixed(4)}');
  stdout.writeln('이 프로세스 세션 최대(-1=세션 없음): 전 ${maxOf(before, true).toStringAsFixed(4)} '
      '중 ${maxOf(during, true).toStringAsFixed(4)} 후 ${maxOf(after, true).toStringAsFixed(4)}');
  if (_sync) {
    final lastHeard = samples
        .where((s) => s.$1 >= playAt && s.$3 > 0.001)
        .map((s) => s.$1 - playAt)
        .lastOrNull;
    stdout.writeln('[sync] ffmpeg 띄운 뒤 첫 프레임 ${ffmpegFirstFrameMs}ms, '
        '소리 시작(AudioOut.start) 대비 첫 화면 +${firstFrameWall == null ? '?' : firstFrameWall! - playAt}ms '
        '(lead ${kAudioLeadMs}ms), 소리가 처음 들린 시각 +${firstHeard ?? '?'}ms, '
        '마지막으로 들린 시각 +${lastHeard ?? '?'}ms, 화면 끝(onEnded) +${endWall == null ? '?' : endWall! - playAt}ms, '
        '정지 후 started=${AudioOut.started}');
  }
  stdout.writeln('처음 소리가 잡힌 시각: ${firstHeard == null ? '없음' : '+${firstHeard}ms'}');

  final heard = maxOf(during, true) > 0.01;
  final silentAfter = maxOf(after, true) < 0.001;
  if (heard && silentAfter && ok) {
    stdout.writeln('결과: 성공 — 재생 중에만 이 프로세스의 소리가 출력 장치에 잡혔다');
    return 0;
  }
  stdout.writeln('결과: 실패 또는 판정 불가 (heard=$heard, silentAfter=$silentAfter)');
  return 1;
}
