#!/usr/bin/env python3
"""按站点 logo 生成 Android 启动图标。

logo 来源是来源站首页 `<link rel="icon">` 里的内联 SVG（otaku 站点自己的图标）：
    深蓝圆角底 #0A2D42 + 青色四角星 #39C5BB + 右上高光点 #66CCFF

这里不引第三方 SVG 渲染器，直接按那份 SVG 的几何数据画：
- 圆角矩形：PIL 原生支持
- 四角星：四段三次贝塞尔，采样成多边形（24 点/段）
- 高光点：椭圆

产物：
- mipmap-*/ic_launcher.png          完整图标（Android 7.x 及以下，minSdk 24）
- 自适应图标走 XML（见 res/drawable/ic_launcher_foreground.xml），不需要 PNG

用法：python scripts/gen_launcher_icons.py
"""

import os

from PIL import Image, ImageDraw

# 站点 logo 的配色（来自 style.css 里的 --brand-* / --accent-*）
BG = (10, 45, 66, 255)      # #0a2d42
STAR = (57, 197, 187, 255)  # #39c5bb
DOT = (102, 204, 255, 255)  # #66ccff

# 四角星的四段三次贝塞尔（原 SVG viewBox 64x64，path 已展开成绝对坐标）
_SEGMENTS = [
    ((32, 7), (33.7, 21.4), (42.6, 30.3), (57, 32)),
    ((57, 32), (42.6, 33.7), (33.7, 42.6), (32, 57)),
    ((32, 57), (30.3, 42.6), (21.4, 33.7), (7, 32)),
    ((7, 32), (21.4, 30.3), (30.3, 21.4), (32, 7)),
]

# 圆角（原 SVG rx=15 @ 64）
RADIUS = 15 / 64
# 高光点（原 SVG cx=50 cy=48 r=3.6）
DOT_CX, DOT_CY, DOT_R = 50, 48, 3.6

SUPERSAMPLE = 4
SAMPLES_PER_SEGMENT = 24


def _cubic(p0, p1, p2, p3, t):
    mt = 1 - t
    return (
        mt**3 * p0[0] + 3 * mt * mt * t * p1[0] + 3 * mt * t * t * p2[0] + t**3 * p3[0],
        mt**3 * p0[1] + 3 * mt * mt * t * p1[1] + 3 * mt * t * t * p2[1] + t**3 * p3[1],
    )


def _star_points(scale):
    pts = []
    for p0, p1, p2, p3 in _SEGMENTS:
        for i in range(SAMPLES_PER_SEGMENT):
            x, y = _cubic(p0, p1, p2, p3, i / SAMPLES_PER_SEGMENT)
            pts.append((x * scale, y * scale))
    return pts


def render(size: int) -> Image.Image:
    s = size * SUPERSAMPLE
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    scale = s / 64

    d.rounded_rectangle((0, 0, s - 1, s - 1), radius=RADIUS * scale, fill=BG)
    d.polygon(_star_points(scale), fill=STAR)

    r = DOT_R * scale
    d.ellipse(
        (DOT_CX * scale - r, DOT_CY * scale - r, DOT_CX * scale + r, DOT_CY * scale + r),
        fill=DOT,
    )

    return img.resize((size, size), Image.LANCZOS)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    res = os.path.join(here, "..", "app-client", "android", "app", "src", "main", "res")

    targets = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }

    for folder, size in targets.items():
        out_dir = os.path.join(res, folder)
        os.makedirs(out_dir, exist_ok=True)
        out = os.path.join(out_dir, "ic_launcher.png")
        render(size).save(out, "PNG", optimize=True)
        print(f"  {folder}/ic_launcher.png  {size}x{size}")


if __name__ == "__main__":
    main()
