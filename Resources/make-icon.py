#!/usr/bin/env python3
"""Draws the app icon and packs it into Sundial.icns.

A placeholder with the right shape and the right metrics: a dial, hour ticks,
a gnomon and the shadow it throws. Replace the drawing, not the packing.

    python3 Resources/make-icon.py
"""
import math, os, shutil, subprocess, sys
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
S = 1024                      # drawn once at 1024 and downsampled
SS = 4                        # supersample factor for clean edges

SAND_TOP, SAND_BOT = (247, 201, 114), (214, 134, 46)   # face gradient
DIAL = (252, 247, 236)
INK = (46, 52, 64)
SHADOW = (46, 52, 64, 64)


def rounded_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius, fill=255)
    return m


def draw(size):
    n = size * SS
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))

    # Background: vertical gradient clipped to the macOS rounded-rect.
    grad = Image.new("RGB", (1, n))
    gd = ImageDraw.Draw(grad)
    for y in range(n):
        t = y / max(n - 1, 1)
        gd.point((0, y), fill=tuple(round(a + (b - a) * t) for a, b in zip(SAND_TOP, SAND_BOT)))
    grad = grad.resize((n, n))
    img.paste(grad, (0, 0), rounded_mask(n, int(n * 0.225)))

    d = ImageDraw.Draw(img, "RGBA")
    bx, by = n / 2, n * 0.655         # the dial's base line, optically centred
    R = n * 0.34

    # A half dial, flat side down. This is what separates a sundial from a
    # clock face at a glance, so it carries the whole silhouette.
    d.pieslice([bx - R, by - R, bx + R, by + R], 180, 360, fill=DIAL)
    d.rounded_rectangle([bx - R, by - n * 0.012, bx + R, by + n * 0.030],
                        n * 0.016, fill=DIAL)

    # Hour lines along the arc, longer at the quarters.
    for i in range(7):
        a = math.radians(180 + i * 30)
        long_tick = i % 3 == 0
        r0 = R * (0.80 if long_tick else 0.87)
        d.line([bx + r0 * math.cos(a), by + r0 * math.sin(a),
                bx + R * 0.95 * math.cos(a), by + R * 0.95 * math.sin(a)],
               fill=INK, width=round(n * (0.016 if long_tick else 0.010)))

    # The shadow, thrown up the dial along one hour line.
    a = math.radians(207)
    tip = (bx + R * 0.88 * math.cos(a), by + R * 0.88 * math.sin(a))
    d.polygon([(bx - R * 0.05, by), (bx + R * 0.07, by), tip], fill=SHADOW)

    # The gnomon: a blade standing on the base line, leaning away from it.
    d.polygon([(bx - R * 0.05, by),
               (bx - R * 0.05, by - R * 0.70),
               (bx + R * 0.40, by)], fill=INK)

    return img.resize((size, size), Image.LANCZOS)


def main():
    iconset = os.path.join(HERE, "Sundial.iconset")
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset)

    base = draw(S)
    base.save(os.path.join(HERE, "icon-1024.png"))          # App Store listing art
    for px in (16, 32, 128, 256, 512):
        draw(px).save(os.path.join(iconset, f"icon_{px}x{px}.png"))
        draw(px * 2).save(os.path.join(iconset, f"icon_{px}x{px}@2x.png"))

    icns = os.path.join(HERE, "Sundial.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
    shutil.rmtree(iconset, ignore_errors=True)
    print(f"wrote {icns} and icon-1024.png")


if __name__ == "__main__":
    sys.exit(main())
