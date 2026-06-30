#!/usr/bin/env python3
"""Social-preview / listing banner generator for AddonPulse.

Renders the banner at the recommended Open Graph size:
  - assets/Banner-1280.png  - 1280x640 (GitHub Settings -> Social Preview;
                              CurseForge / Wago header art; README hero)
  - assets/Banner-640.png   -  640x320 (fallback minimum size)

Layout: the graph icon on the left (from assets/Icon-256.png), the addon
name + tagline on the right, in the same teal-on-slate palette as the icon
for visual continuity. Run `python3 tools/make_icon.py` first.
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

REPO_ROOT = Path(__file__).resolve().parent.parent
ASSETS_DIR = REPO_ROOT / "assets"
ICON_SOURCE = ASSETS_DIR / "Icon-256.png"   # produced by make_icon.py

W, H = 1280, 640

# Teal-on-slate palette (matches the icon: BG 16,22,28 / accent #52c7e0).
SLATE = (16, 22, 28)
TEAL = (82, 199, 224)
GLOW = (26, 66, 82)   # deep teal the radial background fades toward


def find_font(candidates):
    for p in candidates:
        if Path(p).exists():
            return p
    raise SystemExit("No usable font found; tried:\n  " + "\n  ".join(candidates))


FONT_BOLD = find_font([
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/Library/Fonts/Arial Bold.ttf",
])
FONT_REG = find_font([
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/Library/Fonts/Arial.ttf",
])


def main():
    if not ICON_SOURCE.exists():
        raise SystemExit(
            f"Missing {ICON_SOURCE.relative_to(REPO_ROOT)}. "
            f"Run `python3 tools/make_icon.py` first."
        )

    img = Image.new("RGBA", (W, H), (*SLATE, 255))
    draw = ImageDraw.Draw(img)

    # Background: a soft teal radial glow over slate (brighter under the icon).
    bg_cx, bg_cy = W * 0.32, H * 0.50
    for i in range(220, 0, -1):
        r = (i / 220) * max(W, H) * 0.95
        t = 1.0 - (i / 220)
        red   = int(SLATE[0] + (GLOW[0] - SLATE[0]) * t)
        green = int(SLATE[1] + (GLOW[1] - SLATE[1]) * t)
        blue  = int(SLATE[2] + (GLOW[2] - SLATE[2]) * t)
        draw.ellipse([bg_cx - r, bg_cy - r, bg_cx + r, bg_cy + r],
                     fill=(red, green, blue))

    # Vignette to settle the edges.
    vmask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(vmask).ellipse(
        [int(-W * 0.10), int(-H * 0.10), int(W * 1.10), int(H * 1.10)], fill=210)
    vmask = vmask.filter(ImageFilter.GaussianBlur(radius=70))
    dark = Image.new("RGBA", (W, H), (0, 0, 0, 140))
    img = Image.alpha_composite(
        img, Image.composite(Image.new("RGBA", (W, H), (0, 0, 0, 0)), dark, vmask))

    # Icon on the left, with a soft teal halo behind it.
    icon = Image.open(ICON_SOURCE).convert("RGBA").resize((380, 380), Image.LANCZOS)
    icon_x, icon_y = 130, (H - 380) // 2

    halo = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    hcx, hcy, hr = icon_x + 190, H // 2, int(380 * 0.62)
    ImageDraw.Draw(halo).ellipse(
        [hcx - hr, hcy - hr, hcx + hr, hcy + hr], fill=(*TEAL, 150))
    halo = halo.filter(ImageFilter.GaussianBlur(radius=75))
    img = Image.alpha_composite(img, halo)
    img.paste(icon, (icon_x, icon_y), icon)

    draw = ImageDraw.Draw(img)
    text_x = icon_x + 380 + 60
    text_avail = (W - 50) - text_x

    # Auto-fit the title to the available column width.
    title = "AddonPulse"
    title_size = 110
    while title_size > 40:
        f = ImageFont.truetype(FONT_BOLD, title_size)
        bbox = draw.textbbox((0, 0), title, font=f, anchor="lt")
        if (bbox[2] - bbox[0]) <= text_avail:
            break
        title_size -= 2
    title_font = ImageFont.truetype(FONT_BOLD, title_size)
    title_bbox = draw.textbbox((0, 0), title, font=title_font, anchor="lt")
    title_h = title_bbox[3] - title_bbox[1]

    sep_pad, sep_h, tag_pad, tag_lh, small_pad = 22, 3, 24, 44, 30
    tag_lines = ["Where your CPU and memory really go —",
                 "a live per-addon monitor with graphs."]
    tag_font = ImageFont.truetype(FONT_BOLD, 31)
    small_font = ImageFont.truetype(FONT_REG, 23)
    small_text = "World of Warcraft Midnight  ·  Patch 12.x"
    small_bbox = draw.textbbox((0, 0), small_text, font=small_font, anchor="lt")
    small_h = small_bbox[3] - small_bbox[1]

    block_h = (title_h + sep_pad + sep_h + tag_pad
               + tag_lh * len(tag_lines) + small_pad + small_h)
    y = (H - block_h) // 2

    sh = max(2, title_size // 28)
    draw.text((text_x + sh, y + sh), title, font=title_font,
              fill=(0, 0, 0, 200), anchor="lt")
    draw.text((text_x, y), title, font=title_font,
              fill=(238, 250, 255, 255), anchor="lt")
    y += title_h + sep_pad
    draw.rectangle([text_x, y, text_x + 380, y + sep_h], fill=(*TEAL, 235))
    y += sep_h + tag_pad
    for line in tag_lines:
        draw.text((text_x, y), line, font=tag_font,
                  fill=(212, 232, 240, 255), anchor="lt")
        y += tag_lh
    y += small_pad
    draw.text((text_x, y), small_text, font=small_font,
              fill=(120, 175, 195, 235), anchor="lt")

    # Border frame.
    draw.rectangle([0, 0, W - 1, H - 1], outline=(8, 14, 16, 255), width=3)
    draw.rectangle([3, 3, W - 4, H - 4], outline=(30, 58, 66, 255), width=1)

    out_full = ASSETS_DIR / "Banner-1280.png"
    out_half = ASSETS_DIR / "Banner-640.png"
    img.convert("RGB").save(out_full, optimize=True, quality=92)
    img.resize((W // 2, H // 2), Image.LANCZOS).convert("RGB").save(
        out_half, optimize=True, quality=92)

    print(f"wrote {out_full.relative_to(REPO_ROOT)}  ({W}x{H})")
    print(f"wrote {out_half.relative_to(REPO_ROOT)}  ({W // 2}x{H // 2})")


if __name__ == "__main__":
    main()
