#!/usr/bin/env python3
"""从选定的冰蓝版字标导出 Android 启动图标。

源图：app-client/assets/branding/otaku_app_icon.png。
导出时按蓝色字标与浅底的色差提取透明前景，去掉展示边框和圆角；
字形直接取自原图，不重新绘制。

用法：python scripts/gen_launcher_icons.py
产物仅写 Android res：五档旧版图标、432px 自适应前景及纯色背景 XML。
自适应字标宽 64dp，位于 108dp 画布中心的 66dp 安全区内。
"""

from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "app-client/assets/branding/otaku_app_icon.png"
RES = ROOT / "app-client/android/app/src/main/res"

BACKGROUND = (234, 246, 255, 255)  # #EAF6FF
INK = (42, 154, 224, 255)         # #2A9AE0
LEGACY_WORD_WIDTH = 0.81
ADAPTIVE_SIZE = 432
ADAPTIVE_WORD_WIDTH = 64 / 108
TARGETS = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}


def wordmark() -> Image.Image:
    """按蓝色色差恢复抗锯齿透明度，保留猫 a、杯 u 的原始轮廓。"""
    with Image.open(SOURCE) as source:
        source = source.convert("RGB")
    colors = source.getcolors(source.width * source.height)
    background = max(colors, key=lambda item: item[0])[1]
    ink_colors = [item for item in colors if item[1][2] - item[1][0] > 100]
    if not ink_colors:
        raise ValueError(f"源图中未找到蓝色字标：{SOURCE}")
    ink = max(ink_colors, key=lambda item: item[0])[1]
    bg_delta = background[2] - background[0]
    ink_delta = ink[2] - ink[0]
    red, _, blue = source.split()
    delta = ImageChops.subtract(blue, red)
    # 消除浅底的少量位图噪声，其余边缘保留原图的半透明过渡。
    lookup = [
        0 if value <= bg_delta + 4 else
        max(0, min(255, round(255 * (value - bg_delta) / (ink_delta - bg_delta))))
        for value in range(256)
    ]
    alpha = delta.point(lookup)
    bounds = alpha.getbbox()
    if bounds is None:
        raise ValueError("字标提取结果为空")
    artwork = Image.new("RGBA", source.size, INK)
    artwork.putalpha(alpha)
    return artwork.crop(bounds)


def centered(artwork: Image.Image, size: int, width: float) -> Image.Image:
    result = Image.new("RGBA", (size, size))
    target_width = round(size * width)
    target_height = round(artwork.height * target_width / artwork.width)
    scaled = artwork.resize((target_width, target_height), Image.Resampling.LANCZOS)
    result.alpha_composite(scaled, ((size - target_width) // 2, (size - target_height) // 2))
    return result


def render(artwork: Image.Image, size: int) -> Image.Image:
    # 旧系统没有自适应裁切，导出透明圆角；先大图合成再缩小以保留边缘。
    canvas_size = size * 4
    image = Image.new("RGBA", (canvas_size, canvas_size), BACKGROUND)
    image.alpha_composite(centered(artwork, canvas_size, LEGACY_WORD_WIDTH))
    mask = Image.new("L", image.size)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, canvas_size - 1, canvas_size - 1),
        radius=canvas_size * 0.2,
        fill=255,
    )
    image.putalpha(mask)
    return image.resize((size, size), Image.Resampling.LANCZOS)


def save(image: Image.Image, relative: str) -> None:
    path = RES / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, "PNG", optimize=True)
    print(f"  {relative}  {image.width}x{image.height}")


def main() -> None:
    artwork = wordmark()
    for folder, size in TARGETS.items():
        save(render(artwork, size), f"{folder}/ic_launcher.png")
    save(
        centered(artwork, ADAPTIVE_SIZE, ADAPTIVE_WORD_WIDTH),
        "drawable-nodpi/ic_launcher_artwork.png",
    )
    background = RES / "drawable/ic_launcher_background.xml"
    background.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<!-- 冰蓝色满底；自适应图标的形状由 Android Launcher 决定。 -->\n'
        '<shape xmlns:android="http://schemas.android.com/apk/res/android"\n'
        '    android:shape="rectangle">\n'
        '    <solid android:color="#EAF6FF" />\n'
        '</shape>\n',
        encoding="utf-8",
    )
    print("  drawable/ic_launcher_background.xml  #EAF6FF")


if __name__ == "__main__":
    main()
