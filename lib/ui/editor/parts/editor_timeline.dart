import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../theme.dart';
import '../editor_controller.dart';
import 'timeline_painters.dart';

/// 시간 막대. 위에서부터 눈금(끌면 이동) · 장면 띠 · 소리 파형.
/// 장면 띠와 파형 위를 끌면 구간이 골라진다.
class EditorTimeline extends StatelessWidget {
  final ClipEditorController c;

  const EditorTimeline(this.c, {super.key});

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final rulerH = d.px(24);
    final stripH = d.px(54);
    final waveH = d.px(38);
    final totalH = rulerH + stripH + waveH;

    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth;
        double xOf(double t) => c.dur <= 0 ? 0 : (t / c.dur * width);
        double tOf(double x) =>
            c.dur <= 0 ? 0 : (x / width * c.dur).clamp(0.0, c.dur);
        final sel = c.sel;
        final dragging = c.dragStart != null;
        final a = c.selA, b = c.selB;

        Widget band(
          double from,
          double to,
          double top,
          double height,
          BoxDecoration deco, [
          Widget? child,
        ]) {
          return Positioned(
            left: xOf(from),
            width: (xOf(to) - xOf(from)).clamp(1.0, width),
            top: top,
            height: height,
            child: Container(
              decoration: deco,
              alignment: Alignment.center,
              child: child,
            ),
          );
        }

        return SizedBox(
          height: totalH,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Column(
                children: [
                  MouseRegion(
                    cursor: SystemMouseCursors.resizeLeftRight,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (e) =>
                          c.seek(tOf(e.localPosition.dx), immediate: true),
                      onHorizontalDragStart: (e) =>
                          c.seek(tOf(e.localPosition.dx)),
                      onHorizontalDragUpdate: (e) =>
                          c.seek(tOf(e.localPosition.dx)),
                      child: Container(
                        height: rulerH,
                        decoration: BoxDecoration(
                          color: const Color(0xFFE4E9EF),
                          borderRadius: BorderRadius.vertical(
                            top: Radius.circular(d.px(6)),
                          ),
                        ),
                        child: CustomPaint(
                          size: Size(width, rulerH),
                          painter: RulerPainter(
                            duration: c.dur,
                            fontSize: d.px(13),
                            color: AppColors.textSub,
                          ),
                        ),
                      ),
                    ),
                  ),
                  MouseRegion(
                    cursor: SystemMouseCursors.precise,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      // 누른 자리부터 고르게 한다. 기본값이면 몇 픽셀 움직인 뒤의
                      // 자리에서 시작돼 앞쪽이 잘린다.
                      dragStartBehavior: DragStartBehavior.down,
                      onTapUp: (e) => c.tapStrip(tOf(e.localPosition.dx)),
                      onHorizontalDragStart: (e) =>
                          c.beginDrag(tOf(e.localPosition.dx)),
                      onHorizontalDragUpdate: (e) =>
                          c.updateDrag(tOf(e.localPosition.dx)),
                      onHorizontalDragEnd: (_) => c.endDrag(),
                      child: Column(
                        key: const ValueKey('clip-editor-strip'),
                        children: [
                          Container(
                            height: stripH,
                            color: const Color(0xFF11151A),
                            child: Row(
                              children: [
                                for (
                                  var i = 0;
                                  i < ClipEditorController.stripCount;
                                  i++
                                )
                                  Expanded(
                                    child:
                                        i < c.strip.length && c.strip[i] != null
                                        ? Image.file(
                                            File(c.strip[i]!),
                                            fit: BoxFit.cover,
                                            height: stripH,
                                            gaplessPlayback: true,
                                          )
                                        : const SizedBox.shrink(),
                                  ),
                              ],
                            ),
                          ),
                          Container(
                            height: waveH,
                            decoration: BoxDecoration(
                              color: const Color(0xFF1B222B),
                              borderRadius: BorderRadius.vertical(
                                bottom: Radius.circular(d.px(6)),
                              ),
                            ),
                            alignment: Alignment.center,
                            child: c.audio != null
                                ? CustomPaint(
                                    size: Size(width, waveH),
                                    painter: WavePainter(c.audio!.peaks),
                                  )
                                : Text(
                                    !c.spec.hasAudio
                                        ? '소리 없는 영상'
                                        : (c.audioLoading
                                              ? '소리 모양을 읽는 중…'
                                              : ''),
                                    style: TextStyle(
                                      color: Colors.white54,
                                      fontSize: d.px(13),
                                    ),
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              // 아래부터는 표시만 한다(마우스는 통과).
              IgnorePointer(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (final p in c.pieces.pieces.where((p) => !p.keep))
                      band(
                        p.start,
                        p.end,
                        rulerH,
                        stripH + waveH,
                        BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.74),
                          border: Border.all(color: AppColors.danger, width: 2),
                        ),
                        (xOf(p.end) - xOf(p.start)) > d.px(46)
                            ? Text(
                                '빠짐',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: d.px(15),
                                  fontWeight: FontWeight.w700,
                                ),
                              )
                            : null,
                      ),
                    // 구간 시작만 찍은 상태: 굵은 노란 선 + '시작' 깃발(가는 선은 눈에 안 띈다).
                    if (a != null && b == null) ...[
                      Positioned(
                        left: xOf(a) - d.px(2.5),
                        top: rulerH,
                        width: d.px(5),
                        height: stripH + waveH,
                        child: Container(color: Colors.amber),
                      ),
                      Positioned(
                        left: xOf(a) - d.px(2.5),
                        top: rulerH,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: d.px(6), vertical: d.px(2)),
                          color: Colors.amber,
                          child: Text(
                            '시작',
                            style: TextStyle(
                              fontSize: d.px(13),
                              fontWeight: FontWeight.w700,
                              color: Colors.black,
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (a != null && b != null && (dragging || sel != null))
                      band(
                        a < b ? a : b,
                        a < b ? b : a,
                        rulerH,
                        stripH + waveH,
                        BoxDecoration(
                          color: Colors.amber.withValues(alpha: 0.30),
                          border: Border.all(color: Colors.amber, width: 2.5),
                        ),
                      ),
                    Positioned(
                      left: xOf(c.pos) - d.px(1.5),
                      top: 0,
                      width: d.px(3),
                      height: totalH,
                      child: Container(color: Colors.redAccent),
                    ),
                    Positioned(
                      left: xOf(c.pos) - d.px(8),
                      top: -d.px(3),
                      child: Container(
                        width: d.px(16),
                        height: d.px(14),
                        decoration: BoxDecoration(
                          color: Colors.redAccent,
                          borderRadius: BorderRadius.vertical(
                            bottom: Radius.circular(d.px(8)),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
