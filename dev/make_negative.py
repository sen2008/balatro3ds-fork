#!/usr/bin/env python3
"""Make the Negative version of a texture.

The PC game draws Negative cards through a shader. The 3DS has no fragment shaders, so the
port ships a separate negative image for every Joker (`resources/textures/1x/Jokers/
Jokers1_negative_*.png`), and a mod does the same with `negative_sprite`. This makes that image
from the normal one, with the transform the shader applies:

  1. RGB -> HSL; lightness inverted (L' = 1 - L), hue mirrored and offset (H' = 0.2 - H, wrapped)
  2. HSL -> RGB, then the fixed tint (79, 99, 103) added and clamped
  3. alpha below 0.7 is divided by 3; colour channels are untouched by that step

Fully transparent pixels are left alone. This is the same transform as
`dev/aseprite/hsl_invert_transform.lua`, for anyone without Aseprite.

    python3 dev/make_negative.py plus_four.png               -> plus_four_negative.png
    python3 dev/make_negative.py a.png b.png --t3x           -> also a_negative.t3x, b_negative.t3x
    python3 dev/make_negative.py in.png -o out.png           -> out.png

`--t3x` runs `tex3ds -f rgba` on each result (devkitPro's `3ds-dev` must be on PATH), since the
3DS loads the `.t3x` beside the `.png` it is asked for.
"""

import argparse
import math
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from png_io import read_rgba, write_rgba  # noqa: E402

TINT = (79 / 255, 99 / 255, 103 / 255)


def rgb_to_hsl(r, g, b):
    """r, g, b in 0..255 -> h, s, l in 0..1."""
    r, g, b = r / 255, g / 255, b / 255
    maxc, minc = max(r, g, b), min(r, g, b)
    l = (maxc + minc) / 2
    if maxc == minc:
        return 0.0, 0.0, l
    d = maxc - minc
    s = d / (2 - maxc - minc) if l > 0.5 else d / (maxc + minc)
    if maxc == r:
        h = (g - b) / d + (6 if g < b else 0)
    elif maxc == g:
        h = (b - r) / d + 2
    else:
        h = (r - g) / d + 4
    return h / 6, s, l


def hue_to_rgb(p, q, t):
    if t < 0:
        t += 1
    if t > 1:
        t -= 1
    if t < 1 / 6:
        return p + (q - p) * 6 * t
    if t < 1 / 2:
        return q
    if t < 2 / 3:
        return p + (q - p) * (2 / 3 - t) * 6
    return p


def hsl_to_rgb(h, s, l):
    """h, s, l in 0..1 -> r, g, b in 0..1."""
    if s == 0:
        return l, l, l
    q = l * (1 + s) if l < 0.5 else l + s - l * s
    p = 2 * l - q
    return hue_to_rgb(p, q, h + 1 / 3), hue_to_rgb(p, q, h), hue_to_rgb(p, q, h - 1 / 3)


def clamp01(v):
    return 0.0 if v < 0 else 1.0 if v > 1 else v


def round_half_up(v):
    # Lua's math.floor(x + 0.5), not Python's banker's rounding, so results match the script.
    return int(math.floor(v + 0.5))


def negative_pixel(r, g, b, a):
    h, s, l = rgb_to_hsl(r, g, b)
    l = 1 - l
    h = -h + 0.2
    h = h - math.floor(h)
    nr, ng, nb = hsl_to_rgb(h, s, l)
    nr, ng, nb = (clamp01(c + t) * 255 for c, t in zip((nr, ng, nb), TINT))
    na = a / 3 if a / 255 < 0.7 else a
    return round_half_up(nr), round_half_up(ng), round_half_up(nb), round_half_up(na)


def make_negative(src, dst):
    width, height, rgba = read_rgba(src)
    out = bytearray(rgba)
    for i in range(0, len(out), 4):
        a = out[i + 3]
        if a > 0:
            out[i:i + 4] = bytes(negative_pixel(out[i], out[i + 1], out[i + 2], a))
    write_rgba(dst, width, height, out)


def default_output(src):
    root, ext = os.path.splitext(src)
    return root + "_negative" + (ext or ".png")


def main(argv):
    parser = argparse.ArgumentParser(description="Make the Negative version of PNG textures.")
    parser.add_argument("inputs", nargs="+", help="PNG files to convert")
    parser.add_argument("-o", "--output", help="output file (only with a single input); "
                        "default: <name>_negative.png beside the input")
    parser.add_argument("--t3x", action="store_true", help="also build the .t3x with tex3ds")
    args = parser.parse_args(argv[1:])

    if args.output and len(args.inputs) != 1:
        parser.error("-o/--output takes exactly one input")
    tex3ds = shutil.which("tex3ds") if args.t3x else None
    if args.t3x and not tex3ds:
        parser.error("--t3x needs tex3ds on PATH (devkitPro 3ds-dev)")

    for src in args.inputs:
        # `*.png` sweeps up the negatives a previous run wrote; never make a negative of one.
        if not args.output and os.path.splitext(src)[0].endswith("_negative"):
            print("skipped " + src + " (already a negative)")
            continue
        dst = args.output or default_output(src)
        make_negative(src, dst)
        print("wrote " + dst)
        if tex3ds:
            t3x = os.path.splitext(dst)[0] + ".t3x"
            subprocess.run([tex3ds, "-f", "rgba", dst, "-o", t3x], check=True,
                           stdout=subprocess.DEVNULL)
            print("wrote " + t3x)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
