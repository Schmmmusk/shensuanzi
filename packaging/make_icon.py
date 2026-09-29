"""生成 `windows/runner/resources/app_icon.ico`（§AG B10）。

一次性资源生成脚本，**不是构建流程的一部分** —— 图标是版本化资产，
只在「要改图标」时手动跑一次。

为什么需要脚本而不是随手画一个：图标要**多分辨率**（16 / 24 / 32 / 48 / 64 / 128 / 256），
手绘 7 个尺寸不现实；而且下一次改配色时，改一行颜色重跑即可。

依赖：`Pillow`（**只在这个脚本里用**，与本项目的 Dart 依赖无关）。
字体：Windows 自带的 **SimHei**（`simhei.ttf`）—— 用系统字体渲染字形**不产生字体授权问题**
（字形被栅格化成像素，不是内嵌字体文件）。

用法：
    python packaging/make_icon.py

设计（§AG B10 裁定：「一个简单的字形 + 一个背景色即可，不追求精致」）：

- 深靛蓝**竖向渐变**底 + 圆角（与 Flutter 默认蓝明确区分）
- 白色「**算**」字居中 —— 比「神」更直接对应「算账 / 算库存」
- 顶部加一层极淡高光，让它在深色任务栏上不糊成一块
"""

from __future__ import annotations

import os

from PIL import Image, ImageDraw, ImageFont

# ---- 设计参数（改配色只需要改这里）----
TOP = (31, 61, 122)      # 深靛蓝（上）
BOTTOM = (18, 96, 122)   # 深青（下）
INK = (255, 255, 255)    # 字色
GLYPH = "算"
FONT_PATH = r"C:\Windows\Fonts\simhei.ttf"

# 先画大图再缩（各尺寸都得到抗锯齿效果）
MASTER = 1024
SIZES = [16, 24, 32, 48, 64, 128, 256]

OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "windows", "runner", "resources", "app_icon.ico",
)


def rounded_mask(size: int, radius_ratio: float = 0.22) -> Image.Image:
    """圆角矩形遮罩（图标用圆角比直角更「是软件」）。"""
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle(
        (0, 0, size - 1, size - 1), radius=int(size * radius_ratio), fill=255
    )
    return mask


def vertical_gradient(size: int) -> Image.Image:
    grad = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / max(size - 1, 1)
        grad.putpixel(
            (0, y),
            tuple(round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3)),
        )
    return grad.resize((size, size))


def main() -> None:
    base = vertical_gradient(MASTER)

    # 顶部高光：让图标在深色任务栏上有轮廓（很淡，不喧宾夺主）
    gloss = Image.new("L", (MASTER, MASTER), 0)
    ImageDraw.Draw(gloss).ellipse(
        (-MASTER * 0.35, -MASTER * 0.95, MASTER * 1.35, MASTER * 0.42), fill=28
    )
    base = Image.composite(Image.new("RGB", (MASTER, MASTER), (255, 255, 255)), base, gloss)

    # 字形：字号按「视觉充满」调，不是按字面 bounding box
    font = ImageFont.truetype(FONT_PATH, int(MASTER * 0.62))
    draw = ImageDraw.Draw(base)
    box = draw.textbbox((0, 0), GLYPH, font=font)
    draw.text(
        ((MASTER - (box[2] - box[0])) / 2 - box[0],
         (MASTER - (box[3] - box[1])) / 2 - box[1] + MASTER * 0.015),
        GLYPH,
        font=font,
        fill=INK,
    )

    base.putalpha(rounded_mask(MASTER))

    # ⚠️ 必须把**原始大图**交给 `save(sizes=...)` —— Pillow 会自己逐个尺寸缩。
    # 传一个已经缩好的小图会导致只写出一帧（真实踩过：16×16 的图存出来 798 字节、只有 1 个尺寸）。
    # `bitmap_format="bmp"`：老式 DIB 条目，`rc.exe` 与所有 Windows 版本都认
    # （PNG 条目虽然 Vista+ 支持，但在资源编译环节没有 BMP 稳）。
    base.save(
        OUT,
        format="ICO",
        sizes=[(s, s) for s in SIZES],
        bitmap_format="bmp",
    )
    print(f"已写出 {OUT}")
    print("尺寸：", ", ".join(str(s) for s in SIZES))
    print("文件大小：", os.path.getsize(OUT), "字节")


if __name__ == "__main__":
    main()
