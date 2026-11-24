"""전환 효과 맛보기 그림 묶음을 만든다.

설정 화면의 효과 카드에서 두 장면이 그 효과로 넘어가는 모습을 반복해 보여 준다.
실행 중에 영상을 만들지 않도록, 미리 ffmpeg 로 그려서 앱 자산(assets)으로 넣는다.
실제 결과물과 같은 ffmpeg 필터(xfade·fade)로 그리므로 보이는 그대로 나온다.

결과: assets/transitions/<효과>.jpg — 한 장에 프레임 36개(6×6 격자, 320×180).
시간이 아니라 전환 진행 정도(0%→100%)를 36단계로 담는다. 앱이 고른 '길이'에
맞춰 이 단계를 빠르게/천천히 넘기므로 맛보기 속도가 실제 결과물과 같다.

    python -u tool/make_transition_previews.py
"""
import math
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
FFMPEG = ROOT / 'tools' / 'ffmpeg.exe'
OUT = ROOT / 'assets' / 'transitions'

W, H = 320, 180          # 프레임 하나 크기
COLS, ROWS = 6, 6        # 격자 → 36 프레임
FRAMES = COLS * ROWS
RATE = FRAMES - 1        # 1초를 35칸으로 → 진행 0%부터 100%까지 36장

# Dart 쪽 TransitionStyle 이름과 같아야 한다.
XFADE = {
    'dissolve': 'fade',
    'push': 'slideleft',
    'wipe': 'smoothleft',
    'zoom': 'zoomin',
    'blur': 'hblur',
    'grays': 'fadegrays',
}
DIPS = {'dipBlack': 'black', 'dipWhite': 'white'}


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def vgrad(draw, box, top, bottom):
    x0, y0, x1, y1 = box
    for y in range(y0, y1):
        t = (y - y0) / max(1, y1 - y0 - 1)
        draw.line([(x0, y), (x1, y)], fill=lerp(top, bottom, t))


def scene_lake(w, h):
    """한낮의 호수와 산. 파랑·초록 위주."""
    im = Image.new('RGB', (w, h))
    d = ImageDraw.Draw(im)
    horizon = int(h * 0.58)
    vgrad(d, (0, 0, w, horizon), (70, 140, 220), (175, 215, 245))
    # 구름
    for cx, cy, r in [(0.22, 0.18, 0.07), (0.30, 0.16, 0.09), (0.38, 0.19, 0.06),
                      (0.70, 0.26, 0.06), (0.77, 0.24, 0.08)]:
        X, Y, R = cx * w, cy * h, r * w
        d.ellipse([X - R, Y - R * 0.6, X + R, Y + R * 0.6], fill=(250, 252, 255))
    # 먼 산·가까운 산
    d.polygon([(0, horizon), (w * 0.18, h * 0.30), (w * 0.38, horizon)], fill=(110, 140, 170))
    d.polygon([(w * 0.25, horizon), (w * 0.52, h * 0.22), (w * 0.80, horizon)], fill=(95, 125, 160))
    d.polygon([(w * 0.62, horizon), (w * 0.85, h * 0.34), (w, h * 0.45), (w, horizon)], fill=(105, 135, 165))
    d.polygon([(w * 0.47, h * 0.29), (w * 0.52, h * 0.22), (w * 0.57, h * 0.29)], fill=(240, 245, 250))
    # 호수
    vgrad(d, (0, horizon, w, h), (60, 120, 170), (30, 70, 110))
    # 화면 한가운데 호숫가 오두막. '다가가며 넘기기'는 가운데로 확대되므로
    # 가운데가 빈 하늘이면 맛보기가 밋밋한 파란 화면이 된다.
    cx, cy = w * 0.5, h * 0.5
    bw, bh = w * 0.09, h * 0.09
    d.rectangle([cx - bw / 2, cy, cx + bw / 2, cy + bh], fill=(190, 140, 90))
    d.polygon([(cx - bw * 0.65, cy), (cx, cy - bh * 0.8), (cx + bw * 0.65, cy)], fill=(180, 50, 45))
    d.rectangle([cx - bw * 0.12, cy + bh * 0.4, cx + bw * 0.12, cy + bh], fill=(90, 60, 40))
    d.rectangle([cx + bw * 0.2, cy + bh * 0.2, cx + bw * 0.38, cy + bh * 0.45], fill=(255, 230, 150))
    for i in range(14):
        y = horizon + 6 + i * (h - horizon) / 14
        d.line([(w * 0.1 + (i % 3) * 30, y), (w * 0.35 + (i % 4) * 25, y)], fill=(120, 170, 210), width=1)
    # 앞쪽 풀밭
    d.polygon([(0, h), (0, h * 0.86), (w * 0.3, h * 0.92), (w * 0.55, h)], fill=(70, 120, 60))
    d.polygon([(w, h), (w, h * 0.83), (w * 0.7, h * 0.93), (w * 0.5, h)], fill=(60, 110, 55))
    return im.filter(ImageFilter.SMOOTH)


def scene_sunset(w, h):
    """해 질 녘 들판. 주황·보라 위주(앞 장면과 색이 확실히 다르게)."""
    im = Image.new('RGB', (w, h))
    d = ImageDraw.Draw(im)
    horizon = int(h * 0.66)
    vgrad(d, (0, 0, w, horizon), (70, 40, 110), (250, 150, 70))
    # 해 (오른쪽 — 밀어내기·닦아내기 방향이 잘 보이도록 한쪽에 둔다)
    sx, sy, sr = w * 0.72, h * 0.55, w * 0.09
    for k in range(6, 0, -1):
        rr = sr * (1 + k * 0.25)
        a = 0.10 * (7 - k)
        col = lerp((250, 150, 70), (255, 220, 140), a)
        d.ellipse([sx - rr, sy - rr, sx + rr, sy + rr], fill=col)
    d.ellipse([sx - sr, sy - sr, sx + sr, sy + sr], fill=(255, 236, 170))
    # 언덕 실루엣
    pts = [(0, h)]
    for i in range(0, 41):
        x = w * i / 40
        y = horizon - 10 + 10 * math.sin(i / 3.0) + 6 * math.sin(i / 1.3)
        pts.append((x, y))
    pts.append((w, h))
    d.polygon(pts, fill=(60, 35, 60))
    # 나무 한 그루(왼쪽)
    tx, ty = w * 0.18, horizon - 6
    d.rectangle([tx - 2, ty - 30, tx + 2, ty], fill=(35, 20, 35))
    d.ellipse([tx - 16, ty - 52, tx + 16, ty - 22], fill=(35, 20, 35))
    # 들판 줄무늬
    vgrad(d, (0, int(h * 0.80), w, h), (95, 55, 60), (60, 35, 45))
    return im.filter(ImageFilter.SMOOTH)


def run(args):
    r = subprocess.run([str(FFMPEG), '-hide_banner', '-loglevel', 'error', '-y', *args],
                       capture_output=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.decode('utf-8', 'replace'))


def render(name, a_png, b_png, work: Path):
    frames_dir = work / name
    frames_dir.mkdir()
    # 1초짜리 전환을 RATE fps 로 그려 1.0~2.0초 구간(36장)만 남긴다.
    # 1장째 = 앞 장면 그대로, 36장째 = 뒤 장면 그대로.
    pick = f"trim=start_frame={RATE}:end_frame={RATE + FRAMES},setpts=PTS-STARTPTS"
    if name in XFADE:
        fc = (f"[0:v]fps={RATE},format=yuv420p[a];[1:v]fps={RATE},format=yuv420p[b];"
              f"[a][b]xfade=transition={XFADE[name]}:duration=1.0:offset=1.0,"
              f"{pick},format=rgb24[v]")
        a_len, b_len = '2.0', '2.0'
    else:
        color = DIPS[name]
        # 실제 결과물과 같은 방식: 앞 조각 끝이 어두워지고, 뒤 조각 처음이 밝아진다.
        fc = (f"[0:v]fps={RATE},format=yuv420p,fade=t=out:st=1.0:d=0.5:color={color}[a];"
              f"[1:v]fps={RATE},format=yuv420p,fade=t=in:st=0:d=0.47:color={color}[b];"
              f"[a][b]concat=n=2:v=1:a=0,{pick},format=rgb24[v]")
        a_len, b_len = '1.5', '1.5'
    run(['-loop', '1', '-t', a_len, '-i', str(a_png),
         '-loop', '1', '-t', b_len, '-i', str(b_png),
         '-filter_complex', fc, '-map', '[v]', '-frames:v', str(FRAMES),
         str(frames_dir / 'f%02d.png')])
    files = sorted(frames_dir.glob('f*.png'))
    if len(files) != FRAMES:
        raise RuntimeError(f'{name}: {len(files)} frames')
    sheet = Image.new('RGB', (W * COLS, H * ROWS))
    for i, f in enumerate(files):
        im = Image.open(f).convert('RGB').resize((W, H), Image.LANCZOS)
        sheet.paste(im, ((i % COLS) * W, (i // COLS) * H))
    out = OUT / f'{name}.jpg'
    sheet.save(out, quality=82, optimize=True)
    return out


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as td:
        work = Path(td)
        # 크게 그린 뒤 줄여서 계단 현상을 없앤다.
        a = scene_lake(W * 3, H * 3).resize((W * 2, H * 2), Image.LANCZOS)
        b = scene_sunset(W * 3, H * 3).resize((W * 2, H * 2), Image.LANCZOS)
        a_png, b_png = work / 'a.png', work / 'b.png'
        a.save(a_png)
        b.save(b_png)
        total = 0
        for name in [*DIPS, *XFADE]:
            out = render(name, a_png, b_png, work)
            size = out.stat().st_size
            total += size
            print(f'{name}: {out.name} {size // 1024} KB', flush=True)
        print(f'합계 {total // 1024} KB', flush=True)


if __name__ == '__main__':
    sys.exit(main())
