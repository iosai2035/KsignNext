#!/usr/bin/env python3
"""Generate Ksign Next AppIcon PNGs (independent design: gradient + 'K').

Pure standard library — no Pillow needed, so it runs on any CI runner.
Writes truecolour RGBA PNGs with a vertical gradient, a rounded-corner
mask, and a bold 'K' drawn from thick line segments.
"""
import json
import math
import os
import struct
import zlib

OUTDIR = os.path.join(os.path.dirname(__file__), "..",
                      "Resources", "Assets.xcassets", "AppIcon.appiconset")


def _png_chunk(kind, data):
    chunk = struct.pack(">I", len(data)) + kind + data
    return chunk + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def write_png(path, size, pixels):
    """pixels: list of rows, each a list of (r, g, b, a) tuples."""
    raw = b"".join(
        b"\x00" + b"".join(struct.pack("BBBB", *px) for px in row)
        for row in pixels)
    png = (b"\x89PNG\r\n\x1a\n"
           + _png_chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
           + _png_chunk(b"IDAT", zlib.compress(raw, 6))
           + _png_chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


def _thick_line(img, size, x0, y0, x1, y1, width, color):
    steps = int(max(abs(x1 - x0), abs(y1 - y0)) * 2) + 1
    r = width / 2
    for i in range(steps + 1):
        t = i / steps
        cx = x0 + (x1 - x0) * t
        cy = y0 + (y1 - y0) * t
        for dy in range(-int(r) - 1, int(r) + 2):
            for dx in range(-int(r) - 1, int(r) + 2):
                if dx * dx + dy * dy > r * r:
                    continue
                x, y = int(cx + dx), int(cy + dy)
                if 0 <= x < size and 0 <= y < size:
                    img[y][x] = color


def make(size, path):
    img = []
    for y in range(size):
        t = y / max(size - 1, 1)
        r = int(16 + 4 * t)
        g = int(42 + 68 * t)
        b = int(92 + 88 * t)
        # rounded-corner mask: transparent outside the corner radius
        row = []
        rad = size // 5
        for x in range(size):
            dx = max(rad - x, 0, x - (size - 1 - rad))
            dy = max(rad - y, 0, y - (size - 1 - rad))
            a = 0 if dx * dx + dy * dy > rad * rad else 255
            row.append((r, g, b, a))
        img.append(row)
    white = (255, 255, 255, 255)
    w = max(2, size // 12)
    # Bold 'K': vertical bar + upper and lower diagonals.
    _thick_line(img, size, size * 0.30, size * 0.22, size * 0.30, size * 0.78, w, white)
    _thick_line(img, size, size * 0.32, size * 0.52, size * 0.70, size * 0.24, w, white)
    _thick_line(img, size, size * 0.36, size * 0.48, size * 0.72, size * 0.78, w, white)
    write_png(path, size, img)


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    sizes = [("AppIcon-1024.png", 1024), ("AppIcon-180.png", 180),
             ("AppIcon-120.png", 120), ("AppIcon-152.png", 152),
             ("AppIcon-76.png", 76), ("AppIcon-80.png", 80),
             ("AppIcon-40.png", 40), ("AppIcon-58.png", 58),
             ("AppIcon-87.png", 87)]
    for name, size in sizes:
        make(size, os.path.join(OUTDIR, name))
    contents = {"images": [
        {"filename": "AppIcon-40.png", "idiom": "iphone",
         "scale": "2x", "size": "20x20"},
        {"filename": "AppIcon-58.png", "idiom": "iphone",
         "scale": "2x", "size": "29x29"},
        {"filename": "AppIcon-58.png", "idiom": "iphone",
         "scale": "3x", "size": "29x29"},
        {"filename": "AppIcon-80.png", "idiom": "iphone",
         "scale": "2x", "size": "40x40"},
        {"filename": "AppIcon-87.png", "idiom": "iphone",
         "scale": "3x", "size": "40x40"},
        {"filename": "AppIcon-120.png", "idiom": "iphone",
         "scale": "2x", "size": "60x60"},
        {"filename": "AppIcon-180.png", "idiom": "iphone",
         "scale": "3x", "size": "60x60"},
        {"filename": "AppIcon-76.png", "idiom": "ipad",
         "scale": "1x", "size": "76x76"},
        {"filename": "AppIcon-152.png", "idiom": "ipad",
         "scale": "2x", "size": "76x76"},
        {"filename": "AppIcon-1024.png", "idiom": "ios-marketing",
         "scale": "1x", "size": "1024x1024"},
    ], "info": {"author": "xcode", "version": 1}}
    with open(os.path.join(OUTDIR, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)
    print(f"AppIcon PNGs written to {OUTDIR}")


if __name__ == "__main__":
    main()
