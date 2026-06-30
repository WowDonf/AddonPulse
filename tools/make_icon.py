#!/usr/bin/env python3
"""Generate AddonPulse's addon icon and the marketing icon set with Pillow.

Draws a "pulse" motif — a filled usage graph with a brighter trace line and a
peak marker — in the addon's teal on a dark rounded square. Rendered at 4x
supersample then downscaled with LANCZOS for clean antialiased edges. Writes:

  - Icon.png             the in-game icon at the repo root (128 px); the TOC
                         `## IconTexture: Interface\\AddOns\\AddonPulse\\Icon.png`
                         and the minimap button both pick this up at runtime.
  - assets/Icon-64.png   reference / archival
  - assets/Icon-128.png  documentation embeds
  - assets/Icon-256.png  CurseForge / Wago listing avatar

The whole design is authored against a 128 px reference grid and scaled by
ratio, so every size is the same image. `assets/` and `tools/` are excluded
from the packaged zip (see .pkgmeta); only the root Icon.png ships.

Re-run:  python3 tools/make_icon.py
"""

import os
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SS = 4                          # supersample factor
REPO_ROOT = Path(__file__).resolve().parent.parent
ASSETS_DIR = REPO_ROOT / "assets"
ASSETS_DIR.mkdir(exist_ok=True)

BG = (16, 22, 28, 235)          # dark slate
BORDER = (82, 199, 224, 90)     # faint teal rim
TEAL = (82, 199, 224, 255)      # accent #52c7e0
TEAL_DIM = (82, 199, 224, 70)   # area fill

# The usage trace, on the 128 px grid (y grows downward). Two peaks so it reads
# as a live graph rather than a single spike.
TRACE = [(18, 78), (32, 58), (44, 70), (58, 38), (70, 62), (84, 48), (100, 70), (110, 60)]
BASELINE = 92


def create_icon(size):
    """Render the graph icon at `size` px (square, RGBA)."""
    s = size * SS

    def px(v):                  # design authored on a 128 px grid
        return v / 128.0 * s

    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    pad, radius = px(6), px(26)
    # Rounded-square background + faint rim.
    d.rounded_rectangle([pad, pad, s - pad, s - pad], radius=radius, fill=BG)
    d.rounded_rectangle([pad, pad, s - pad, s - pad], radius=radius,
                        outline=BORDER, width=max(1, int(px(2))))

    pts = [(px(x), px(y)) for (x, y) in TRACE]

    # Faint grid: baseline + one midline.
    grid = (82, 199, 224, 38)
    d.line([(px(16), px(BASELINE)), (px(112), px(BASELINE))], fill=grid, width=max(1, int(px(1.5))))
    d.line([(px(16), px((BASELINE + 38) / 2)), (px(112), px((BASELINE + 38) / 2))],
           fill=(82, 199, 224, 22), width=max(1, int(px(1))))

    # Area fill under the trace.
    poly = pts + [(px(110), px(BASELINE)), (px(18), px(BASELINE))]
    d.polygon(poly, fill=TEAL_DIM)

    # The trace line (rounded joints) + soft round caps at the ends.
    d.line(pts, fill=TEAL, width=max(1, int(px(5))), joint="curve")
    cap = px(2.6)
    for (x, y) in (pts[0], pts[-1]):
        d.ellipse([x - cap, y - cap, x + cap, y + cap], fill=TEAL)

    # Highlight the tallest peak with a ringed dot.
    peak = min(pts, key=lambda p: p[1])
    pr = px(5.5)
    d.ellipse([peak[0] - pr, peak[1] - pr, peak[0] + pr, peak[1] + pr],
              outline=TEAL, width=max(1, int(px(2))))
    d.ellipse([peak[0] - px(2.4), peak[1] - px(2.4), peak[0] + px(2.4), peak[1] + px(2.4)],
              fill=(235, 250, 255, 255))

    # Soft glow: a blurred copy of the teal elements under the crisp ones.
    glow = img.filter(ImageFilter.GaussianBlur(px(2.5)))
    out = Image.alpha_composite(glow, img)

    return out.resize((size, size), Image.LANCZOS)


def main():
    # Marketing icon set.
    for size in (64, 128, 256):
        out = ASSETS_DIR / f"Icon-{size}.png"
        create_icon(size).save(out, optimize=True)
        print("wrote", os.path.relpath(out, REPO_ROOT), "(%dx%d)" % (size, size))

    # In-game icon at the repo root (referenced by the TOC IconTexture).
    create_icon(128).save(REPO_ROOT / "Icon.png", optimize=True)
    print("wrote Icon.png (128x128, in-game)")


if __name__ == "__main__":
    main()
