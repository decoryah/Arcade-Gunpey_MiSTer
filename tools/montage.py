#!/usr/bin/env python3
"""montage.py <out.png> <cols> <a.png|ppm> ...: the pictures side by side, cols to a row, each with a 2-pixel gap (the benches' and
MAME's 320 x 240 frames)."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pngio

def load(p):
    if p.endswith('.ppm'):
        d = open(p, 'rb').read()
        parts = d.split(b'\n', 3)
        w, h = map(int, parts[1].split())
        return w, h, bytearray(parts[3][:w * h * 3])
    return pngio.read(p)

out, cols = sys.argv[1], int(sys.argv[2])
pics = [load(p) for p in sys.argv[3:]]
w = max(p[0] for p in pics); h = max(p[1] for p in pics)
rows = (len(pics) + cols - 1) // cols
W, H = cols * (w + 2), rows * (h + 2)
img = bytearray(W * H * 3)
for i, (pw, ph, px) in enumerate(pics):
    ox, oy = (i % cols) * (w + 2), (i // cols) * (h + 2)
    for y in range(ph):
        o = ((oy + y) * W + ox) * 3
        img[o:o + pw * 3] = px[y * pw * 3:(y + 1) * pw * 3]
pngio.write(out, W, H, img)
