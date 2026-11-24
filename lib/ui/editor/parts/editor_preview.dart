import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../engine/models.dart';
import '../../format.dart';
import '../../theme.dart';
import '../editor_controller.dart';

/// 미리보기 칸: 장면(밝기·회전 반영) + 빠지는 구간 덮개 + 시각 + 안내 문구.
class EditorPreview extends StatelessWidget {
  final ClipEditorController c;

  const EditorPreview(this.c, {super.key});

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final removed = c.canTrim && !c.pieces.pieces[c.pieces.indexAt(c.pos)].keep;
    final turns = (c.rotation ~/ 90) % 4;
    final player = c.player;

    Widget still() {
      final f = c.frame;
      return f != null && File(f).existsSync()
          ? Image.file(File(f), fit: BoxFit.contain, gaplessPlayback: true)
          : const SizedBox.shrink();
    }

    Widget img;
    if (player != null && c.showPlayerFrame) {
      img = ValueListenableBuilder<ui.Image?>(
        valueListenable: player.frame,
        builder: (context, image, _) => image == null
            ? still()
            : RawImage(image: image, fit: BoxFit.contain),
      );
    } else {
      img = still();
    }
    img = RotatedBox(quarterTurns: turns, child: img);
    img = ColorFiltered(
      colorFilter: brightnessFilter(c.brightness),
      child: img,
    );

    return GestureDetector(
      onTap: c.canTrim ? c.togglePlay : null,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF11151A),
          borderRadius: BorderRadius.circular(d.px(10)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(child: img),
            if (removed && !c.playing)
              Container(
                color: Colors.black.withValues(alpha: 0.62),
                alignment: Alignment.center,
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: d.px(20),
                    vertical: d.px(10),
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.danger,
                    borderRadius: BorderRadius.circular(d.px(8)),
                  ),
                  child: Text(
                    '이 부분은 빠집니다',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: d.px(22),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            // 화면이 소리를 못 따라가면 플레이어가 작은 화면으로 다시 띄우므로
            // 흐려진 이유를 알려 준다.
            if (c.player != null)
              Positioned(
                right: d.px(12),
                bottom: d.px(12),
                child: ValueListenableBuilder<bool>(
                  valueListenable: c.player!.lagging,
                  builder: (context, lag, _) => !lag || !c.playing
                      ? const SizedBox.shrink()
                      : Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: d.px(10), vertical: d.px(5)),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(d.px(6)),
                          ),
                          child: Text(
                            '영상이 무거워 화면을 작게 보여 줍니다 (결과물은 그대로)',
                            style: TextStyle(
                                color: Colors.white, fontSize: d.px(14)),
                          ),
                        ),
                ),
              ),
            if (c.frameLoading && !c.playing)
              Positioned(
                right: d.px(12),
                top: d.px(12),
                child: SizedBox(
                  width: d.px(22),
                  height: d.px(22),
                  child: const CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: Colors.white70,
                  ),
                ),
              ),
            Positioned(
              left: d.px(12),
              bottom: d.px(12),
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: d.px(12),
                  vertical: d.px(6),
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(d.px(6)),
                ),
                child: Text(
                  '${formatClock(c.pos, precise: true)}  /  ${formatClock(c.dur)}',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: d.px(20),
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            if (c.hint != null)
              Positioned(
                top: d.px(12),
                left: d.px(12),
                right: d.px(60),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: d.px(14),
                      vertical: d.px(8),
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.primaryDark.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(d.px(8)),
                    ),
                    child: Text(
                      c.hint!,
                      style: TextStyle(color: Colors.white, fontSize: d.px(17)),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 밝기 미리보기. 실제 결과는 감마로 바꾸지만 화면에서는 근사치로 보여준다.
ColorFilter brightnessFilter(BrightnessLevel b) {
  final k = 1 + (b.gamma - 1) * 0.55;
  final o = (b.gamma - 1) * 18;
  return ColorFilter.matrix(<double>[
    k, 0, 0, 0, o, //
    0, k, 0, 0, o, //
    0, 0, k, 0, o, //
    0, 0, 0, 1, 0, //
  ]);
}
