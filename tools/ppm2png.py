#!/usr/bin/env python3
"""ppm2png.py <in.ppm> [<out.png>] [scale]: a binary PPM (the bench's pictures) as a PNG."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pngio
src = sys.argv[1]
dst = sys.argv[2] if len(sys.argv) > 2 else src[:-4] + '.png'
scale = int(sys.argv[3]) if len(sys.argv) > 3 else 1
d = open(src, 'rb').read()
parts = d.split(b'\n', 3)
w, h = map(int, parts[1].split())
px = bytearray(parts[3])
if scale > 1:
    out = bytearray()
    for y in range(h):
        row = bytearray()
        for x in range(w):
            row += px[(y * w + x) * 3:(y * w + x) * 3 + 3] * scale
        out += row * scale
    px, w, h = out, w * scale, h * scale
pngio.write(dst, w, h, px)
