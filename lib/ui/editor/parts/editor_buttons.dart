import 'package:flutter/material.dart';

import '../../theme.dart';

class PlayButton extends StatelessWidget {
  final bool playing;
  final VoidCallback onTap;

  const PlayButton({super.key, required this.playing, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    return Material(
      color: playing ? AppColors.textSub : AppColors.primary,
      borderRadius: BorderRadius.circular(d.px(10)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(d.px(10)),
        child: SizedBox(
          height: d.px(48),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                playing ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
                size: d.px(28),
              ),
              SizedBox(width: d.px(6)),
              Text(
                playing ? '멈춤' : '재생',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: d.px(19),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  final bool enabled;
  final VoidCallback onTap;

  const ActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final c = enabled ? (color ?? AppColors.primary) : AppColors.textFaint;
    return Material(
      color: c.withValues(alpha: enabled ? 0.08 : 0.04),
      borderRadius: BorderRadius.circular(d.px(10)),
      child: InkWell(
        // 꺼진 상태에서도 누르면 안내를 띄우기 위해 onTap 은 살려 둔다.
        onTap: onTap,
        borderRadius: BorderRadius.circular(d.px(10)),
        child: Container(
          height: d.px(52),
          padding: EdgeInsets.symmetric(horizontal: d.px(16)),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(d.px(10)),
            border: Border.all(
              color: c.withValues(alpha: enabled ? 0.6 : 0.35),
              width: 1.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: c, size: d.px(26)),
              SizedBox(width: d.px(8)),
              Text(
                label,
                style: TextStyle(
                  fontSize: d.px(18),
                  fontWeight: FontWeight.w700,
                  color: c,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SmallButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const SmallButton({super.key, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    return Material(
      color: const Color(0xFFEDF1F5),
      borderRadius: BorderRadius.circular(d.px(8)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(d.px(8)),
        child: Container(
          height: d.px(44),
          padding: EdgeInsets.symmetric(horizontal: d.px(12)),
          // widthFactor 를 줘야 Wrap 안에서 줄 전체를 먹지 않고 글자 폭만 차지한다.
          child: Center(
            widthFactor: 1,
            child: Text(
              label,
              style: TextStyle(fontSize: d.px(16), fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ),
    );
  }
}

class Pill extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  const Pill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final d = Dim.of(context);
    final fg = selected ? Colors.white : AppColors.text;
    return Material(
      color: selected ? AppColors.primary : const Color(0xFFEDF1F5),
      borderRadius: BorderRadius.circular(d.px(22)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(d.px(22)),
        child: Container(
          height: d.px(42),
          padding: EdgeInsets.symmetric(horizontal: d.px(16)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: d.px(20), color: fg),
                SizedBox(width: d.px(6)),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: d.px(16),
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
