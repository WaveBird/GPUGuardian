#!/usr/bin/env python3
"""
Generate GPUGuardian.icns from scratch — no third-party dependencies.

Draws a stylized GPU chip: a rounded-square body with a green→orange
gradient (iGPU → dGPU), a circuit-trace border, and a central "G" glyph.
Writes an .iconset, then uses macOS `iconutil` to produce the final .icns.

Usage: ./Assets/generate_icon.sh   (or python3 Assets/generate_icon.py)
"""

import math
import os
import struct
import subprocess
import zlib

OUT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(OUT_DIR)
ICONSET = os.path.join(OUT_DIR, "GPUGuardian.iconset")
ICNS = os.path.join(OUT_DIR, "GPUGuardian.icns")
SIZES = [16, 32, 64, 128, 256, 512, 1024]


def clamp(v, lo=0.0, hi=1.0):
    return max(lo, min(hi, v))


def lerp(a, b, t):
    return a + (b - a) * t


def rounded_rect_sdf(x, y, cx, cy, half, radius, softness):
    """Signed distance to a rounded rect (>0 inside)."""
    dx = abs(x - cx) - (half - radius)
    dy = abs(y - cy) - (half - radius)
    outside = math.hypot(max(dx, 0.0), max(dy, 0.0))
    inside = min(max(dx, dy), 0.0)
    d = outside + inside - radius
    return clamp(0.5 - d / softness)


def seg_dist(px, py, x1, y1, x2, y2):
    dx, dy = x2 - x1, y2 - y1
    if dx == 0 and dy == 0:
        return math.hypot(px - x1, py - y1)
    t = clamp(((px - x1) * dx + (py - y1) * dy) / (dx * dx + dy * dy))
    return math.hypot(px - (x1 + t * dx), py - (y1 + t * dy))


# 7-segment style "G": list of strokes in normalized chip coordinates (-1..1)
G_STROKES = [
    (0.35, 0.55, 0.10, 0.70),   # top-right
    (-0.40, 0.55, 0.10, 0.55),  # top
    (-0.55, 0.45, -0.55, 0.00), # upper-left
    (-0.55, 0.00, -0.50, -0.40),# lower-left
    (-0.45, -0.55, 0.10, -0.55),# bottom
    (0.35, -0.45, 0.35, -0.05), # lower-right
    (0.35, -0.05, 0.02, -0.05), # right mid bar
    (0.02, -0.05, 0.02, -0.40), # inner down
]
PINS = [(-0.72, -0.72), (0, -0.72), (0.72, -0.72),
        (-0.72, 0.72), (0, 0.72), (0.72, 0.72),
        (-0.72, 0), (0.72, 0)]


def render(size):
    """Return RGBA bytes (top-to-bottom) for a size×size icon."""
    s = size
    cx = cy = s / 2.0
    half = s * 0.36          # chip half-size
    radius = s * 0.09
    soft = max(1.0, s / 128.0)
    stroke_w = max(0.9, s * 0.035)
    glow = s * 0.96          # glow radius scale

    rows = bytearray()
    for py in range(s):
        row = bytearray()
        for px in range(s):
            u = (px + 0.5 - cx) / glow   # -0.5..0.5
            v = (py + 0.5 - cy) / glow

            # background: soft radial glow (dark navy center → transparent)
            r = math.hypot(u, v)
            bg_a = clamp(0.35 - r * 0.55) ** 1.5
            bg_r, bg_g, bg_b = 14, 22, 38

            # chip body mask
            body = rounded_rect_sdf(u * 2, v * 2, 0.0, 0.0,
                                    half / glow * 2, radius / glow * 2,
                                    soft / glow * 2)
            # gradient across the chip: green (top-left) → orange-red (bottom-right)
            t = clamp((u + v) * 1.6 + 0.5)
            gr, gg, gb = lerp(48, 255, t), lerp(214, 112, t), lerp(170, 72, t)

            # circuit pins
            pin_a = 0.0
            for (ax, ay) in PINS:
                d = seg_dist(u, v, ax * 0.52, ay * 0.52, ax * 1.05, ay * 1.05)
                pin_a = max(pin_a, clamp((stroke_w / glow * 1.4 - d) / (soft / glow)))
            pin_a *= 1.0 - body  # draw only outside the body

            # "G" glyph carved out of the chip (dark)
            glyph = 0.0
            for (x1, y1, x2, y2) in G_STROKES:
                nx1, ny1 = x1 * 0.46, y1 * 0.46
                nx2, ny2 = x2 * 0.46, y2 * 0.46
                d = seg_dist(u, v, nx1, ny1, nx2, ny2)
                glyph = max(glyph, clamp((stroke_w / glow * 1.5 - d) / (soft / glow)))
            glyph *= body

            # composite: glow → chip → pins → glyph
            a = bg_a
            cr, cg, cb = bg_r, bg_g, bg_b
            a = a + body * (1 - a)
            cr = lerp(cr, gr, body); cg = lerp(cg, gg, body); cb = lerp(cb, gb, body)
            a = a + pin_a * (1 - a)
            cr = lerp(cr, 120, pin_a); cg = lerp(cg, 210, pin_a); cb = lerp(cb, 190, pin_a)
            cr = lerp(cr, 16, glyph); cg = lerp(cg, 26, glyph); cb = lerp(cb, 42, glyph)

            row += bytes((int(clamp(cr / 255) * 255), int(clamp(cg / 255) * 255),
                          int(clamp(cb / 255) * 255), int(clamp(a) * 255)))
        rows += b"\x00" + row  # PNG filter type 0 per scanline
    return bytes(rows)


def png_chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data +
            struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def write_png(path, size):
    raw = render(size)
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)  # 8-bit RGBA
    png = (b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", ihdr) +
           png_chunk(b"IDAT", zlib.compress(raw, 9)) + png_chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


def main():
    os.makedirs(ICONSET, exist_ok=True)
    for s in SIZES:
        write_png(os.path.join(ICONSET, f"icon_{s}x{s}.png"), s)
    subprocess.run(["iconutil", "-c", "icns", ICONSET, "-o", ICNS], check=True)
    print(f"Generated {ICNS} ({os.path.getsize(ICNS)} bytes)")


if __name__ == "__main__":
    main()
