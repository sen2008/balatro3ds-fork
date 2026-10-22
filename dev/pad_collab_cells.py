#!/usr/bin/env python3
"""Widen the collab face-card sheets from 71px cells to the deck's 72px cells.

Each sheet under resources/textures/1x/collabs/<suit>/ is one row of three cells, J, Q
and K left to right. They come in at 71x95 per cell, the reference game's card size,
but `8BitDeck.png` lays its cards out on a 72x95 grid: every cell is the same 71px art
with one fully transparent column on its right. So this pads, it does not scale. A
71->72 resample would duplicate a column of pixel art somewhere in the middle of the
face, while padding lands each card on exactly the pixels the deck's own faces use.

Sheets that are already 72px per cell are skipped, so it is safe to re-run after new
art is dropped in. Anything that is not a whole number of 71px or 72px cells raises.

Run from the repo root:  python3 dev/pad_collab_cells.py [sheet.png ...]
With no arguments it processes every PNG under the collabs folder.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from png_io import read_rgba, write_rgba  # noqa: E402

COLLABS_DIR = os.path.join("resources", "textures", "1x", "collabs")
SRC_CELL_W = 71
DST_CELL_W = 72
CELL_H = 95
CELLS = 3


def pad_sheet(path):
    """Pad one sheet in place. Returns True if it was rewritten, False if already done."""
    width, height, rgba = read_rgba(path)

    if (width, height) == (DST_CELL_W * CELLS, CELL_H):
        return False
    if (width, height) != (SRC_CELL_W * CELLS, CELL_H):
        raise ValueError(
            "%s: %dx%d, expected %dx%d (or already %dx%d)"
            % (path, width, height, SRC_CELL_W * CELLS, CELL_H, DST_CELL_W * CELLS, CELL_H)
        )

    out_w = DST_CELL_W * CELLS
    out = bytearray(out_w * height * 4)  # zeroed, so the new columns are transparent
    for y in range(height):
        for cell in range(CELLS):
            src = (y * width + cell * SRC_CELL_W) * 4
            dst = (y * out_w + cell * DST_CELL_W) * 4
            out[dst : dst + SRC_CELL_W * 4] = rgba[src : src + SRC_CELL_W * 4]

    write_rgba(path, out_w, height, out)
    return True


def main(argv):
    paths = argv[1:]
    if not paths:
        for root, _, files in os.walk(COLLABS_DIR):
            paths += [os.path.join(root, f) for f in files if f.lower().endswith(".png")]
        if not paths:
            print("no PNGs found under %s (run from the repo root)" % COLLABS_DIR)
            return 1

    padded = skipped = 0
    for path in sorted(paths):
        if pad_sheet(path):
            padded += 1
            print("padded:  %s" % path)
        else:
            skipped += 1
    print("%d padded, %d already %dpx per cell" % (padded, skipped, DST_CELL_W))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
