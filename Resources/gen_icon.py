#!/usr/bin/env python3
"""生成 SoundIn 应用图标（方案一：声波化入光标）→ AppIcon.iconset 全尺寸 PNG"""
from PIL import Image, ImageDraw
import os

S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# ── 对角渐变底板（#2C2C2A → #0A0A0A）──
grad = Image.new("RGBA", (S, S))
top = (44, 44, 42)      # 2C2C2A
bot = (10, 10, 10)      # 0A0A0A
px = grad.load()
for y in range(S):
    for x in range(S):
        t = (x + y) / (2 * S - 2)
        px[x, y] = (
            round(top[0] + (bot[0] - top[0]) * t),
            round(top[1] + (bot[1] - top[1]) * t),
            round(top[2] + (bot[2] - top[2]) * t),
            255,
        )

# macOS squircle 近似圆角矩形蒙版
mask = Image.new("L", (S, S), 0)
mdraw = ImageDraw.Draw(mask)
mdraw.rounded_rectangle([32, 32, 32 + 960, 32 + 960], radius=232, fill=255)
img.paste(grad, (0, 0), mask)

draw = ImageDraw.Draw(img)

def bar(x, y, w, h, color=(255, 255, 255, 255)):
    draw.rounded_rectangle([x, y, x + w, y + h], radius=w // 2, fill=color)

# ── 元素排布：等间距（间距 = 声波条宽 48），整体水平居中 ──
GAP = 48
BAR_W = 48
GREEN_W = 80
CURSOR_W = 40
total_w = BAR_W * 3 + GREEN_W + CURSOR_W + GAP * 4   # 456
start_x = (S - total_w) // 2                          # 284

# ── 左侧白色声波（渐弱）──
x = start_x
bar(x, 432, BAR_W, 160, (255, 255, 255, 255))
x += BAR_W + GAP
bar(x, 368, BAR_W, 288, (255, 255, 255, 204))   # 0.8
x += BAR_W + GAP
bar(x, 304, BAR_W, 416, (255, 255, 255, 140))   # 0.55

# ── 绿色输入块 ──
x += BAR_W + GAP
bar(x, 320, GREEN_W, 384, (151, 196, 89, 255))    # 97C459

# ── 白色 I 型光标 ──
x += GREEN_W + GAP
bar(x, 320, CURSOR_W, 384, (255, 255, 255, 255))

out_dir = os.path.dirname(os.path.abspath(__file__))
master = img

# ── 输出 iconset 全尺寸 ──
iconset = os.path.join(out_dir, "AppIcon.iconset")
os.makedirs(iconset, exist_ok=True)
sizes = [16, 32, 64, 128, 256, 512, 1024]
for size in sizes:
    resized = master.resize((size, size), Image.LANCZOS)
    resized.save(os.path.join(iconset, f"icon_{size}x{size}.png"))
    if size <= 512:
        resized.save(os.path.join(iconset, f"icon_{size}x{size}@2x.png")) if False else None

# 规范命名：16/32/128/256/512 及 @2x
naming = {
    16: ["icon_16x16.png", "icon_16x16@2x.png"],      # 16 与 32
    32: ["icon_32x32.png", "icon_32x32@2x.png"],      # 32 与 64
    128: ["icon_128x128.png", "icon_128x128@2x.png"], # 128 与 256
    256: ["icon_256x256.png", "icon_256x256@2x.png"], # 256 与 512
    512: ["icon_512x512.png", "icon_512x512@2x.png"], # 512 与 1024
}
for size, names in naming.items():
    for name in names:
        master.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, name))

# 清理多余文件（保留规范命名的）
for f in os.listdir(iconset):
    if not any(f == n for names in naming.values() for n in names):
        os.remove(os.path.join(iconset, f))

print("done:", sorted(os.listdir(iconset)))
