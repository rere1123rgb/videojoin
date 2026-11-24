import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../engine/frame_grabber.dart';
import '../../engine/models.dart';
import '../../player/audio_track.dart';
import '../../player/clip_player.dart';
import '../../state/app_state.dart';
import 'edit_pieces.dart';

export 'editor_cut_actions.dart';

/// 되돌리기용으로 찍어 두는 한 장면.
class _Snapshot {
  final EditPieces pieces;
  final VolumeLevel volume;
  final BrightnessLevel brightness;
  final int rotation;
  const _Snapshot(this.pieces, this.volume, this.brightness, this.rotation);
}

/// 영상 손보기 창의 화면 밖 상태와 동작 전부.
///
/// 위젯 없이 시험할 수 있도록 [state]·[clip]·[grabber] 는 밖에서 받고, 재생기는
/// [player] 로 바꾸거나 [createPlayer] 를 꺼서 없앨 수 있다.
/// 소리 모양 읽기(ffmpeg)는 [loadAudio] 로 끈다.
class ClipEditorController extends ChangeNotifier {
  /// 장면 띠의 칸 수.
  static const int stripCount = 12;

  final AppState state;
  final ClipItem clip;
  final FrameGrabber grabber;

  EditPieces pieces;
  VolumeLevel volume;
  BrightnessLevel brightness;
  int rotation;
  final List<_Snapshot> _undo = [];

  double pos = 0;

  /// 멈춰 있을 때 보이는 장면.
  String? frame;
  bool frameLoading = false;
  int _frameReq = 0;
  Timer? _frameTimer;
  List<String?> strip = const [];

  String? hint;
  Timer? _hintTimer;

  // 끌어서 고른 구간. 둘 다 null 이면 고른 것이 없다.
  double? selA;
  double? selB;
  double? dragStart;

  ClipPlayer? _player;
  AudioTrack? audio;
  bool audioLoading = false;

  /// 재생이 멈춘 뒤 정지 장면이 준비될 때까지는 재생기의 마지막 화면을 둔다.
  /// 바로 정지 장면으로 바꾸면 한순간 옛 장면이 번쩍인다.
  bool showPlayerFrame = false;

  bool _disposed = false;

  ClipEditorController({
    required this.state,
    required this.clip,
    required this.grabber,
    ClipPlayer? player,
    bool createPlayer = true,
    bool loadAudio = true,
  }) : pieces = EditPieces.fromKeep(clip.spec.durationSec, clip.edit.keep),
       volume = clip.edit.volume,
       brightness = clip.edit.brightness,
       rotation = clip.userRotation {
    final e = clip.edit;
    pos = e.keep.isNotEmpty ? e.keep.first.start : 0;
    frame = clip.thumbnailPath;
    requestFrame(immediate: true);
    unawaited(_loadStrip());

    final p =
        player ??
        (createPlayer ? ClipPlayer(tools: grabber.tools, spec: spec) : null);
    _player = p;
    if (p != null) {
      p.position.addListener(_onPlayerPosition);
      p.playing.addListener(_onPlayerState);
      if (spec.hasAudio && loadAudio) _loadAudio(p);
    }
  }

  VideoSpec get spec => clip.spec;
  double get dur => spec.durationSec;
  bool get canTrim => dur >= kMinRangeSec * 2;
  bool get playing => _player?.playing.value ?? false;
  ClipPlayer? get player => _player;
  bool get canUndo => _undo.isNotEmpty;
  bool get disposed => _disposed;

  ({double lo, double hi})? get sel {
    final a = selA, b = selB;
    if (a == null || b == null) return null;
    final lo = a < b ? a : b;
    final hi = a < b ? b : a;
    if (hi - lo < kMinRangeSec) return null;
    return (lo: lo, hi: hi);
  }

  /// 처음 상태에서 뭔가 바뀌었는가. [처음 상태로] 를 켤지 정한다.
  bool get isEdited =>
      pieces.toKeep().isNotEmpty ||
      volume != VolumeLevel.normal ||
      brightness != BrightnessLevel.normal ||
      rotation != 0;

  /// 전부 뺀 상태. 이대로는 적용할 수 없다.
  bool get nothingLeft =>
      pieces.toKeep().isEmpty && !pieces.pieces.every((p) => p.keep);

  /// 지금 고른 내용을 저장 형태로. 소리·밝기·회전은 [apply] 가 따로 쓴다.
  ClipEdit get currentEdit =>
      ClipEdit(keep: pieces.toKeep(), volume: volume, brightness: brightness);

  /// 화면에 알린다. [ClipEditorCutActions] 확장에서도 쓰므로 공개해 둔다.
  void refresh() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    final p = _player;
    if (p != null) {
      p.position.removeListener(_onPlayerPosition);
      p.playing.removeListener(_onPlayerState);
      p.onEnded = null;
      p.dispose();
    }
    _frameTimer?.cancel();
    _hintTimer?.cancel();
    super.dispose();
  }

  void _loadAudio(ClipPlayer player) {
    audioLoading = true;
    AudioPrep(grabber.tools)
        .prepare(spec)
        .then((t) {
          if (_disposed) return;
          player.audio = t;
          audio = t;
          audioLoading = false;
          refresh();
          // 소리를 읽는 동안 이미 재생을 눌렀으면 소리 없이 돌고 있다.
          // 지금 자리에서 다시 틀어 소리를 붙인다.
          if (t != null && player.playing.value) playFrom(pos);
        })
        .catchError((Object _) {
          if (_disposed) return;
          audioLoading = false;
          refresh();
        });
  }

  Future<void> _loadStrip() async {
    if (dur <= 0) return;
    final list = await grabber.filmstrip(spec, stripCount);
    if (_disposed) return;
    strip = list;
    refresh();
  }

  void _onPlayerPosition() {
    final p = _player;
    if (p == null || !p.playing.value || _disposed) return;
    final v = p.position.value;
    if ((v - pos).abs() < 0.03) return;
    pos = v.clamp(0.0, dur);
    refresh();
  }

  void _onPlayerState() {
    if (_disposed) return;
    if (!playing) {
      requestFrame(immediate: true);
    }
    refresh();
  }

  /// 지금 자리에서 재생한다. 뺀 구간은 건너뛴다 — 결과물 그대로 들린다.
  void play() {
    if (_disposed || _player == null || dur <= 0) return;
    var from = pos;
    if (from >= dur - 0.15) from = 0;
    playFrom(from);
  }

  void playFrom(double from) {
    final p = _player;
    if (p == null || _disposed) return;
    var i = pieces.indexAt(from);
    if (!pieces.pieces[i].keep) {
      final next = _nextKept(i);
      if (next == null) {
        // 뒤에 남은 구간이 없으면 맨 앞의 남은 구간부터.
        final first = _nextKept(-1);
        if (first == null) return;
        i = first;
      } else {
        i = next;
      }
      from = pieces.pieces[i].start;
    }
    final piece = pieces.pieces[i];
    final isLast = i == pieces.pieces.length - 1;
    final index = i;
    p.onEnded = () {
      if (_disposed) return;
      final n = _nextKept(index);
      if (n != null) {
        playFrom(pieces.pieces[n].start);
      } else {
        refresh();
      }
    };
    pos = from;
    showPlayerFrame = true;
    refresh();
    unawaited(
      p.play(
        from,
        untilSec: isLast ? null : piece.end,
        muted: volume == VolumeLevel.mute,
        gain: volume.gain,
      ),
    );
  }

  int? _nextKept(int after) {
    for (var j = after + 1; j < pieces.pieces.length; j++) {
      if (pieces.pieces[j].keep) return j;
    }
    return null;
  }

  void stop() {
    final p = _player;
    if (p == null || !p.playing.value) return;
    p.onEnded = null;
    unawaited(p.stop());
  }

  void togglePlay() => playing ? stop() : play();

  /// 끌고 있는 동안에는 매번 뽑지 않고 손이 멈추면 뽑는다.
  /// 늦게 도착한 옛 장면이 새 장면을 덮지 않도록 요청 번호로 거른다.
  void requestFrame({bool immediate = false}) {
    _frameTimer?.cancel();
    void go() async {
      final req = ++_frameReq;
      final at = pos;
      frameLoading = true;
      refresh();
      final path = await grabber.frameAt(spec, at, waitTurn: false);
      if (_disposed || req != _frameReq) return;
      frameLoading = false;
      if (path != null) {
        frame = path;
        if (!playing) showPlayerFrame = false;
      }
      refresh();
    }

    if (immediate) {
      go();
    } else {
      _frameTimer = Timer(const Duration(milliseconds: 140), go);
    }
  }

  void seek(double t, {bool immediate = false}) {
    stop();
    final max = dur <= 0 ? 0.0 : dur - 0.05;
    pos = t.clamp(0.0, max < 0 ? 0.0 : max);
    refresh();
    requestFrame(immediate: immediate);
  }

  void showHint(String msg) {
    _hintTimer?.cancel();
    hint = msg;
    refresh();
    _hintTimer = Timer(const Duration(seconds: 4), () {
      if (_disposed) return;
      hint = null;
      refresh();
    });
  }

  /// 되돌리기용으로 지금 상태를 찍어 둔다. 바꾸기 직전에 부른다.
  void remember() {
    _undo.add(_Snapshot(pieces.copy(), volume, brightness, rotation));
    if (_undo.length > 50) _undo.removeAt(0);
  }

  void undo() {
    if (_undo.isEmpty) return;
    stop();
    final s = _undo.removeLast();
    pieces = s.pieces;
    volume = s.volume;
    brightness = s.brightness;
    rotation = s.rotation;
    selA = selB = null;
    refresh();
  }

  /// 자른 것·소리·밝기·회전을 모두 처음으로. 되돌리기로 다시 살릴 수 있다.
  void resetAll() {
    stop();
    remember();
    pieces = EditPieces(dur, [EditPiece(0, dur, true)]);
    volume = VolumeLevel.normal;
    brightness = BrightnessLevel.normal;
    rotation = 0;
    selA = selB = null;
    refresh();
  }

  void setVolume(VolumeLevel v) {
    if (volume == v) return;
    stop();
    remember();
    volume = v;
    refresh();
  }

  void setBrightness(BrightnessLevel b) {
    if (brightness == b) return;
    remember();
    brightness = b;
    refresh();
  }

  void rotateBy(int degrees) {
    remember();
    rotation = (rotation + degrees) % 360;
    refresh();
  }

  /// 고른 내용을 영상에 저장한다. 전부 뺀 상태면 안내만 하고 false.
  /// 창을 닫는 일은 부른 쪽이 한다.
  bool apply() {
    stop();
    if (nothingLeft) {
      showHint('남는 것이 없습니다. 뺀 구간을 눌러 [고른 구간 다시 넣기]로 살려 주세요.');
      return false;
    }
    state.setClipEdit(clip.id, currentEdit);
    final delta = rotation - clip.userRotation;
    if (delta != 0) state.rotateClip(clip.id, delta);
    return true;
  }
}
