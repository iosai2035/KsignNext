#!/usr/bin/env python3
"""Generate Ksign Next AppIcon PNGs (independent design: gradient + 'K').

The PNGs themselves are binary and cannot travel through the text-only
GitHub snapshot push, so they are regenerated here — locally and in CI
before the Xcode archive step. Requires Pillow (pip install pillow).
"""
import json
import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("Pillow is required: pip install pillow", file=sys.stderr)
    sys.exit(1)

OUTDIR = os.path.join(os.path.dirname(__file__), "..",
                      "Resources", "Assets.xcassets", "AppIcon.appiconset")


def make(size, path):
    img = Image.new("RGB", (size, size), (10, 20, 40))
    d = ImageDraw.Draw(img, "RGBA")
    for y in range(size):
        t = y / size
        d.line([(0, y), (size, y)],
               fill=(int(16 + 4 * t), int(42 + 68 * t), int(92 + 88 * t)))
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size, size], radius=size // 5, fill=255)
    img.putalpha(mask)
    d = ImageDraw.Draw(img, "RGBA")
    d.arc([size * 0.2, size * 0.55, size * 0.8, size * 0.85],
          start=200, end=340, fill=(255, 255, 255, 220),
          width=max(2, size // 40))
    try:
        font = ImageFont.truetype(
            "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
            int(size * 0.55))
    except Exception:
        font = ImageFont.load_default()
    d.text((size / 2, size * 0.42), "K", font=font,
           fill=(255, 255, 255, 255), anchor="mm")
    img.save(path)


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
