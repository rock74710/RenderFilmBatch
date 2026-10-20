#!/usr/bin/env python3
"""產生 RFCore 內建的 8 個原創底片風格 LUT（33³ .cube，輸入輸出皆為 sRGB 編碼值）。

用法：python3 Scripts/make-film-luts.py Sources/RFCore/Resources/FilmLUTs
每個 LUT 都由下面的公式算出，不取自任何品牌底片或第三方 LUT。
"""
import math
import sys
from pathlib import Path

SIZE = 33


def clamp(x):
    return min(max(x, 0.0), 1.0)


def luma(c):
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


def saturate(c, amount):
    y = luma(c)
    return tuple(y + (v - y) * amount for v in c)


def contrast(c, amount):
    """amount > 1 用 S 曲線加對比（不會硬切），< 1 以中灰為軸線性降低對比。"""
    if amount <= 1:
        return tuple(0.5 + (v - 0.5) * amount for v in c)
    a = 4.0 * (amount - 1) + 1e-6
    lo, hi = 1 / (1 + math.exp(a * 0.5)), 1 / (1 + math.exp(-a * 0.5))
    return tuple((1 / (1 + math.exp(-a * (v - 0.5))) - lo) / (hi - lo) for v in c)


def fade(c, black, white=1.0):
    return tuple(black + v * (white - black) for v in c)


def scale(c, r, g, b, offset=(0.0, 0.0, 0.0)):
    return (c[0] * r + offset[0], c[1] * g + offset[1], c[2] * b + offset[2])


def split_tone(c, shadow, highlight):
    y = clamp(luma(c))
    ws, wh = (1 - y) ** 2, y ** 2
    return tuple(v + shadow[i] * ws + highlight[i] * wh for i, v in enumerate(c))


def mono(c, weights, amount_contrast, black=0.0):
    y = sum(v * w for v, w in zip(c, weights)) / sum(weights)
    out = contrast((y, y, y), amount_contrast)
    return fade(out, black) if black else out


def greens_to_yellow(c, amount):
    r, g, b = c
    excess = max(g - max(r, b), 0.0)
    return (r + excess * amount, g, b - excess * amount * 0.3)


LOOKS = {
    # 暖調正片：偏暖黃、膚色好看、飽和度稍高。
    "warmSlide": lambda c: contrast(saturate(scale(c, 1.05, 1.01, 0.91, (0.015, 0.0, 0.0)), 1.12), 1.08),
    # 冷調正片：偏藍綠、乾淨清爽。
    "coolSlide": lambda c: contrast(saturate(scale(c, 0.94, 1.0, 1.06, (0.0, 0.01, 0.02)), 0.95), 1.05),
    # 褪色底片：黑色變淡灰、顏色變淡。
    "fadedFilm": lambda c: fade(saturate(contrast(c, 0.86), 0.78), 0.08, 0.95),
    # 青橙電影：暗部偏青藍、亮部與膚色偏橙。
    "tealOrange": lambda c: saturate(split_tone(c, (-0.05, 0.02, 0.06), (0.06, 0.015, -0.05)), 1.06),
    # 高反差黑白。
    "highContrastMono": lambda c: mono(c, (0.30, 0.59, 0.11), 1.4),
    # 柔和黑白：對比低、灰階細膩。
    "softMono": lambda c: mono(c, (0.25, 0.65, 0.10), 0.86, black=0.04),
    # 鮮豔正片：飽和與對比都提高。
    "vividSlide": lambda c: contrast(saturate(c, 1.32), 1.15),
    # 復古暖褪：偏暖、輕微褪色、綠色偏黃。
    "retroWarmFade": lambda c: fade(contrast(saturate(greens_to_yellow(
        scale(c, 1.04, 1.0, 0.9, (0.02, 0.005, 0.0)), 0.35), 0.88), 0.92), 0.06, 0.97),
}


def write(name, look, directory):
    lines = [f'TITLE "RFCore {name}"', f"LUT_3D_SIZE {SIZE}"]
    for b in range(SIZE):
        for g in range(SIZE):
            for r in range(SIZE):
                c = look((r / (SIZE - 1), g / (SIZE - 1), b / (SIZE - 1)))
                lines.append(" ".join(f"{clamp(v):.6f}" for v in c))
    (directory / f"{name}.cube").write_text("\n".join(lines) + "\n")


def main():
    directory = Path(sys.argv[1])
    directory.mkdir(parents=True, exist_ok=True)
    for name, look in LOOKS.items():
        write(name, look, directory)


if __name__ == "__main__":
    main()
