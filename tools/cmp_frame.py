#!/usr/bin/env python3
"""cmp_frame.py <ours.ppm|png> <mame.png> [diff.png]: pixels that differ between a bench picture and MAME's snapshot (320 x 224).
Prints the count and the bounding box; with diff.png, writes MAME's picture with the differing pixels in magenta."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pngio

def load(p):
    if p.endswith('.ppm'):
        d = open(p, 'rb').read(); parts = d.split(b'\n', 3)
        w, h = map(int, parts[1].split()); return w, h, bytearray(parts[3])
    return pngio.read(p)

w1, h1, a = load(sys.argv[1])
w2, h2, b = load(sys.argv[2])
assert (w1, h1) == (w2, h2), f'sizes differ: {w1}x{h1} vs {w2}x{h2}'
n = 0; x0 = y0 = 10**9; x1 = y1 = -1
out = bytearray(b)
for y in range(h1):
    for x in range(w1):
        i = (y * w1 + x) * 3
        if a[i:i+3] != b[i:i+3]:
            n += 1; x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            out[i:i+3] = b'\xff\x00\xff'
print(f'{n} pixels differ' + (f', box x {x0}-{x1} y {y0}-{y1}' if n else ''))
if len(sys.argv) > 3:
    pngio.write(sys.argv[3], w1, h1, out)
