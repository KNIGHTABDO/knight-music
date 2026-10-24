#!/usr/bin/env python3
"""Builds the alternate app icons from the main knight icon.

Each style reuses the knight + note silhouette (mask from AppIcon.png) in a different material and
scene, then writes Icon-<Name>.appiconset (1024) and IconPreview-<Name>.imageset (256) into the asset
catalog. Run from the repo root: python3 scripts/make-icons.py
"""
import json
import math
import os

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageOps

ASSETS = "KnightMusic/Resources/Assets.xcassets"
SIZE = 1024
SRC = Image.open(f"{ASSETS}/AppIcon.appiconset/AppIcon.png").convert("RGB").resize((SIZE, SIZE))
LUMA = SRC.convert("L")
# Glyph mask: everything brighter than the black background, slightly softened.
MASK = LUMA.point(lambda v: 255 if v > 26 else int(v * 255 / 26)).filter(ImageFilter.GaussianBlur(1.2))
SHADE = ImageOps.autocontrast(LUMA, cutoff=1)  # inner shading of the glass, 0…255


def solid(color):
    return Image.new("RGB", (SIZE, SIZE), color)


def vgradient(top, bottom, size=SIZE):
    img = Image.new("RGB", (size, size))
    px = np.zeros((size, size, 3), dtype=np.float32)
    t = np.linspace(0, 1, size)[:, None]
    for c in range(3):
        px[:, :, c] = top[c] + (bottom[c] - top[c]) * t
    return Image.fromarray(px.clip(0, 255).astype(np.uint8))


def radial(inner, outer, center=(0.5, 0.5), radius=0.75):
    y, x = np.mgrid[0:SIZE, 0:SIZE] / SIZE
    d = np.sqrt((x - center[0]) ** 2 + (y - center[1]) ** 2) / radius
    d = d.clip(0, 1)[:, :, None]
    px = np.array(inner) * (1 - d) + np.array(outer) * d
    return Image.fromarray(px.clip(0, 255).astype(np.uint8))


def ramp(stops):
    """Maps the glass shading through a color ramp: [(0..1, (r,g,b)), …]."""
    lut = []
    for i in range(256):
        t = i / 255
        for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
            if t0 <= t <= t1:
                k = (t - t0) / max(t1 - t0, 1e-6)
                lut.append(tuple(int(c0[j] + (c1[j] - c0[j]) * k) for j in range(3)))
                break
    r = SHADE.point([c[0] for c in lut])
    g = SHADE.point([c[1] for c in lut])
    b = SHADE.point([c[2] for c in lut])
    return Image.merge("RGB", (r, g, b))


def glow(mask, color, radius, strength=1.0):
    blurred = mask.filter(ImageFilter.GaussianBlur(radius)).point(lambda v: min(255, int(v * strength)))
    return solid(color), blurred


def paste_glow(base, mask, color, radius, strength=1.0):
    layer, m = glow(mask, color, radius, strength)
    return Image.composite(layer, base, m)


def edges(mask):
    return ImageChops.subtract(mask.filter(ImageFilter.MaxFilter(9)), mask.filter(ImageFilter.MinFilter(9)))


def transformed_mask(scale=1.0, dx=0, dy=0):
    s = int(SIZE * scale)
    m = MASK.resize((s, s), Image.LANCZOS)
    out = Image.new("L", (SIZE, SIZE), 0)
    out.paste(m, ((SIZE - s) // 2 + dx, (SIZE - s) // 2 + dy))
    return out


def transformed(img, scale=1.0, dx=0, dy=0):
    s = int(SIZE * scale)
    i = img.resize((s, s), Image.LANCZOS)
    out = Image.new("RGB", (SIZE, SIZE), 0)
    out.paste(i, ((SIZE - s) // 2 + dx, (SIZE - s) // 2 + dy))
    return out


# MARK: - Styles

def neon():
    base = radial((22, 8, 40), (4, 2, 10))
    e = edges(MASK)
    base = paste_glow(base, e, (255, 0, 200), 28, 2.2)
    base = paste_glow(base, e, (0, 230, 255), 10, 2.0)
    return Image.composite(solid((235, 255, 255)), base, e.point(lambda v: min(255, v * 2)))


def zellige():
    tile = Image.new("RGB", (SIZE, SIZE), (10, 70, 70))
    d = ImageDraw.Draw(tile)
    step = 128
    colors = [(0, 110, 110), (20, 60, 130), (230, 220, 200)]
    for gy in range(-1, SIZE // step + 2):
        for gx in range(-1, SIZE // step + 2):
            cx, cy = gx * step + (step // 2 if gy % 2 else 0), gy * step
            pts = []
            for k in range(16):
                r = 58 if k % 2 == 0 else 30
                a = math.pi * 2 * k / 16
                pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
            d.polygon(pts, fill=colors[(gx + gy) % 2], outline=(240, 235, 220), width=5)
    tile = Image.blend(tile, solid((5, 30, 35)), 0.35)
    m = transformed_mask(0.86)
    plate = Image.composite(solid((0, 0, 0)), tile, m.filter(ImageFilter.MaxFilter(31)).filter(ImageFilter.GaussianBlur(10)))
    knight = transformed(ramp([(0, (150, 110, 40)), (0.5, (245, 236, 215)), (1, (255, 255, 250))]), 0.86)
    return Image.composite(knight, plate, m)


def vinyl():
    base = solid((12, 12, 14))
    disc = Image.new("RGB", (SIZE, SIZE), (8, 8, 9))
    d = ImageDraw.Draw(disc)
    c = SIZE // 2
    for r in range(470, 180, -7):
        shade = 18 + int(10 * math.sin(r / 9))
        d.ellipse((c - r, c - r, c + r, c + r), outline=(shade, shade, shade + 2), width=3)
    disc_mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(disc_mask).ellipse((c - 480, c - 480, c + 480, c + 480), fill=255)
    base = Image.composite(disc, base, disc_mask)
    # Sheen across the grooves.
    sheen = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(sheen).pieslice((c - 480, c - 480, c + 480, c + 480), 200, 235, fill=60)
    ImageDraw.Draw(sheen).pieslice((c - 480, c - 480, c + 480, c + 480), 20, 55, fill=45)
    base = Image.composite(solid((200, 200, 210)), base, sheen.filter(ImageFilter.GaussianBlur(20)))
    label = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(label).ellipse((c - 175, c - 175, c + 175, c + 175), fill=255)
    base = Image.composite(radial((250, 60, 85), (170, 10, 35), radius=0.2), base, label)
    m = transformed_mask(0.36)
    return Image.composite(solid((255, 245, 235)), base, m)


def gold_rai():
    base = radial((10, 80, 55), (2, 22, 16))
    m = MASK
    base = paste_glow(base, m, (255, 200, 80), 40, 0.8)
    gold = ramp([(0, (90, 55, 10)), (0.45, (210, 160, 50)), (0.8, (255, 225, 130)), (1, (255, 250, 220))])
    return Image.composite(gold, base, m)


def chrome():
    base = vgradient((40, 44, 52), (6, 6, 8))
    bands = ramp([(0, (30, 32, 38)), (0.3, (200, 205, 215)), (0.5, (80, 85, 95)), (0.75, (240, 244, 250)), (1, (255, 255, 255))])
    stripes = vgradient((255, 255, 255), (60, 65, 75))
    metal = Image.blend(bands, stripes, 0.35)
    base = paste_glow(base, MASK, (160, 180, 210), 30, 0.6)
    return Image.composite(metal, base, MASK)


def synthwave():
    base = vgradient((20, 0, 50), (255, 60, 140))
    d = ImageDraw.Draw(base)
    horizon = 700
    d.rectangle((0, horizon, SIZE, SIZE), fill=(15, 0, 35))
    sun = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(sun).ellipse((262, 220, 762, 720), fill=255)
    for i, y in enumerate(range(520, horizon, 34)):
        ImageDraw.Draw(sun).rectangle((0, y, SIZE, y + 6 + i * 3), fill=0)
    base = Image.composite(vgradient((255, 230, 90), (255, 70, 150)), base, sun)
    d = ImageDraw.Draw(base)
    for k in range(-12, 13):
        d.line((SIZE / 2 + k * 30, horizon, SIZE / 2 + k * 160, SIZE), fill=(0, 230, 255), width=3)
    y, gap = horizon, 12
    while y < SIZE:
        d.line((0, y, SIZE, y), fill=(0, 230, 255), width=3)
        y += gap
        gap = int(gap * 1.35) + 4
    m = transformed_mask(0.8, dy=-40)
    base = paste_glow(base, m, (0, 0, 0), 22, 1.5)
    knight = transformed(ramp([(0, (40, 0, 80)), (0.5, (255, 40, 180)), (1, (120, 255, 255))]), 0.8, dy=-40)
    return Image.composite(knight, base, m)


def sahara():
    base = vgradient((255, 180, 90), (230, 90, 40))
    d = ImageDraw.Draw(base)
    d.ellipse((600, 160, 860, 420), fill=(255, 240, 200))
    for i, (y, col) in enumerate([(640, (214, 120, 60)), (730, (190, 95, 45)), (830, (150, 70, 35))]):
        pts = [(0, SIZE)] + [(x, y + 50 * math.sin(x / 170 + i * 1.7)) for x in range(0, SIZE + 1, 16)] + [(SIZE, SIZE)]
        d.polygon(pts, fill=col)
    m = transformed_mask(0.82, dx=-30, dy=10)
    return Image.composite(solid((40, 14, 8)), base, m)


def pixel():
    small = SRC.resize((32, 32), Image.BILINEAR)
    small = ImageOps.posterize(small, 3)
    big = small.resize((SIZE, SIZE), Image.NEAREST)
    m = MASK.resize((32, 32), Image.BILINEAR).point(lambda v: 255 if v > 90 else 0).resize((SIZE, SIZE), Image.NEAREST)
    bg = Image.new("RGB", (SIZE, SIZE), (18, 14, 40))
    d = ImageDraw.Draw(bg)
    for gx in range(0, SIZE, 32):
        d.line((gx, 0, gx, SIZE), fill=(28, 22, 60), width=2)
        d.line((0, gx, SIZE, gx), fill=(28, 22, 60), width=2)
    pal = ramp([(0, (120, 0, 40)), (0.5, (255, 50, 80)), (1, (255, 230, 120))]).resize((32, 32), Image.BILINEAR)
    pal = ImageOps.posterize(pal, 2).resize((SIZE, SIZE), Image.NEAREST)
    return Image.composite(pal, bg, m)


def origami():
    paper = vgradient((245, 238, 225), (225, 215, 198))
    shaded = ramp([(0, (150, 30, 40)), (1, (255, 120, 120))])
    q = shaded.quantize(colors=5, method=Image.Quantize.MEDIANCUT).convert("RGB")
    q = q.filter(ImageFilter.ModeFilter(13))
    m = MASK.point(lambda v: 255 if v > 100 else 0)
    shadow = m.filter(ImageFilter.GaussianBlur(16))
    shadow_off = Image.new("L", (SIZE, SIZE), 0)
    shadow_off.paste(shadow, (18, 22))
    paper = Image.composite(solid((170, 160, 145)), paper, shadow_off.point(lambda v: v // 2))
    out = Image.composite(q, paper, m)
    d = ImageDraw.Draw(out)
    for x in range(-SIZE, SIZE, 96):
        d.line((x, 0, x + SIZE, SIZE), fill=(255, 255, 255), width=1)
    return Image.composite(q, out, m)


def cassette():
    base = vgradient((30, 26, 40), (12, 10, 18))
    d = ImageDraw.Draw(base)
    d.rounded_rectangle((90, 230, 934, 800), radius=40, fill=(230, 225, 210))
    d.rounded_rectangle((130, 270, 894, 600), radius=20, fill=(250, 60, 80))
    d.rectangle((130, 330, 894, 350), fill=(255, 200, 60))
    d.rounded_rectangle((300, 460, 724, 560), radius=50, fill=(40, 34, 44))
    for cx in (390, 634):
        d.ellipse((cx - 38, 472, cx + 38, 548), fill=(240, 240, 240))
        d.ellipse((cx - 16, 494, cx + 16, 526), fill=(40, 34, 44))
    d.polygon([(260, 800), (300, 690), (724, 690), (764, 800)], fill=(200, 194, 180))
    for sx in (360, 664):
        d.ellipse((sx - 14, 730, sx + 14, 758), fill=(90, 85, 80))
    m = transformed_mask(0.25, dx=-250, dy=-75)
    return Image.composite(solid((255, 250, 240)), base, m)


def golden_record():
    base = solid((6, 5, 3))
    d = ImageDraw.Draw(base)
    c = SIZE // 2
    for k in range(36):
        a = math.pi * 2 * k / 36
        d.line((c, c, c + 700 * math.cos(a), c + 700 * math.sin(a)), fill=(60, 45, 10), width=6)
    base = base.filter(ImageFilter.GaussianBlur(6))
    ring = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(ring).ellipse((60, 60, 964, 964), outline=255, width=18)
    base = Image.composite(vgradient((255, 230, 140), (160, 110, 30)), base, ring)
    base = paste_glow(base, MASK, (255, 190, 60), 50, 1.0)
    gold = ramp([(0, (110, 70, 10)), (0.4, (230, 175, 55)), (0.75, (255, 235, 150)), (1, (255, 255, 235))])
    return Image.composite(gold, base, MASK)


def phantom():
    base = radial((40, 20, 70), (3, 2, 8))
    ghost = MASK.filter(ImageFilter.GaussianBlur(3))
    base = paste_glow(base, MASK, (160, 120, 255), 60, 0.9)
    trail = Image.new("L", (SIZE, SIZE), 0)
    for i in range(1, 6):
        t = Image.new("L", (SIZE, SIZE), 0)
        t.paste(MASK.point(lambda v, i=i: v // (i + 2)), (-i * 22, i * 6))
        trail = ImageChops.lighter(trail, t)
    base = Image.composite(solid((150, 130, 230)), base, trail.filter(ImageFilter.GaussianBlur(6)))
    body = ramp([(0, (90, 70, 160)), (1, (245, 240, 255))])
    return Image.composite(body, base, ghost.point(lambda v: int(v * 0.85)))


STYLES = {
    "Neon": neon, "Zellige": zellige, "Vinyl": vinyl, "Emerald": gold_rai, "Chrome": chrome,
    "Synthwave": synthwave, "Sahara": sahara, "Pixel": pixel, "Origami": origami, "Cassette": cassette,
    "Golden": golden_record, "Phantom": phantom,
}


def write_appiconset(name, img):
    folder = f"{ASSETS}/Icon-{name}.appiconset"
    os.makedirs(folder, exist_ok=True)
    img.save(f"{folder}/Icon-{name}.png", optimize=True)
    contents = {
        "images": [{"filename": f"Icon-{name}.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1},
    }
    with open(f"{folder}/Contents.json", "w") as f:
        json.dump(contents, f, indent=2)


def write_preview(asset_id, img):
    folder = f"{ASSETS}/IconPreview-{asset_id}.imageset"
    os.makedirs(folder, exist_ok=True)
    img.resize((256, 256), Image.LANCZOS).save(f"{folder}/IconPreview-{asset_id}.png", optimize=True)
    contents = {
        "images": [{"filename": f"IconPreview-{asset_id}.png", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
    }
    with open(f"{folder}/Contents.json", "w") as f:
        json.dump(contents, f, indent=2)


if __name__ == "__main__":
    write_preview("AppIcon", SRC)
    for name, make in STYLES.items():
        img = make().convert("RGB")
        write_appiconset(name, img)
        write_preview(f"Icon-{name}", img)
        print("made", name)
