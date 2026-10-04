#!/usr/bin/env python3
"""Overlock itch.io page decoration assets (docs/promo/itch/).

Draws the still images that go into the itch.io theme editor and the page body:
banner (transparent + Deep Plum), seamless background tiles, a running-stitch
divider, the CONTROLS keycap block, six 48x48 feature icons and two section
headings. Optional reference previews (never uploaded) go to docs/promo/itch/preview/.

Reuses the key visual helpers (tools/promo/keyvisual/make_keyvisual.py): colour
tokens, logo(), tagline_plate(), dashed_polyline(), paste_with_shadow() and the
deterministic sRGB save(). Every element is drawn at 2x (icons at 4x) and
Lanczos-downsampled, so the same inputs always give the same bytes.

Usage:
    python make_itch_assets.py              # deliverables + previews
    python make_itch_assets.py --no-preview # deliverables only
    python make_itch_assets.py --out <dir>  # write somewhere else (hash checks)
"""

import argparse
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "keyvisual"))
import make_keyvisual as kv  # noqa: E402

ROOT = kv.ROOT
GFX = kv.GFX
PROMO = kv.PROMO
SHOTS = os.path.join(PROMO, "screenshots")
OUT_DEFAULT = os.path.join(PROMO, "itch")

PURPLE = kv.THREAD_PURPLE
PLUM = kv.DEEP_PLUM
CREAM = kv.FABRIC_CREAM
RED = kv.STITCH_RED
YELLOW = kv.STAR_YELLOW
INK = (0x47, 0x34, 0x2A)        # onepager body ink
SUB = (0x6A, 0x56, 0x48)        # onepager secondary ink
CARD = (0xF8, 0xEF, 0xDA)       # onepager card fill
CARD_EDGE = (0xD9, 0xC8, 0xA6)
PAGE_TEXT = (0x3B, 0x2A, 0x2E)  # itch theme Text colour (README)
PURPLE_INK = (0x74, 0x4E, 0x9E)  # darker Thread Purple for small text: 5.5:1 on CARD

SUBTITLE = "~재봉틀 레이싱~"
BLURB = "원단 위 손떨리는 레이싱, 삐끗하면 아야해요"

CONTROLS = [
    (["<", ">"], ["A", "D"], "조향"),
    (["^", "v"], ["W", "S"], "속도 단계"),
    (["Shift"], [], "피벗 드리프트 (홀드)"),
    (["Space"], [], "아이템 사용"),
    (["R"], [], "재시작"),
    (["Esc"], [], "일시정지"),
]
MOBILE = "모바일: 화면의 터치 버튼으로 조작"

HEADINGS = {"features": "게임 특징", "controls": "조작 방법"}


# ---------------------------------------------------------------- shared drawing

def pinked_polygon(w, h, zig, edges="tblr"):
    """Zigzag (pinking shear) outline of a w x h box; `edges` picks which sides zigzag."""
    pts = []
    n = max(2, round(w / (zig * 2)))
    m = max(2, round(h / (zig * 2)))
    for i in range(n + 1):
        pts.append((w * i / n, (zig if i % 2 else 0) if "t" in edges else 0))
    for i in range(1, m + 1):
        pts.append((w - ((zig if i % 2 else 0) if "r" in edges else 0), h * i / m))
    for i in range(1, n + 1):
        pts.append((w - w * i / n, h - ((zig if i % 2 else 0) if "b" in edges else 0)))
    for i in range(1, m):
        pts.append((((zig if i % 2 else 0) if "l" in edges else 0), h - h * i / m))
    return pts


def pinked_mask(w, h, zig, edges="tblr", ss=4):
    lay = Image.new("L", (w * ss, h * ss), 0)
    ImageDraw.Draw(lay).polygon(pinked_polygon(w * ss, h * ss, zig * ss, edges), fill=255)
    return lay.resize((w, h), Image.LANCZOS)


def running_stitch(size, y, x0, x1, dash, gap, width, color, ss=4, shadow=None):
    """Horizontal running stitch (rounded dashes) centred inside [x0, x1] on row y."""
    w, h = size
    lay = Image.new("RGBA", (w * ss, h * ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    period = dash + gap
    n = int((x1 - x0 + gap) // period)
    start = x0 + ((x1 - x0) - (n * period - gap)) / 2
    r = width / 2
    for i in range(n):
        a = start + i * period
        for col, dy in ((shadow, 0.9), (color, 0.0)):
            if col is None:
                continue
            cy = (y + dy) * ss
            d.rounded_rectangle((a * ss, cy - r * ss, (a + dash) * ss, cy + r * ss), r * ss, fill=col)
    return lay.resize((w, h), Image.LANCZOS)


def drop_shadow(lay, radius, offset, opacity, color=(40, 24, 20)):
    return kv.shadow_of(lay, radius, offset, opacity, color)


def on_bg(im, color):
    bg = Image.new("RGBA", im.size, color + (255,))
    bg.alpha_composite(im)
    return bg


def save(im, path, size=None):
    kv.save(im, path, size)


# ---------------------------------------------------------------- 1. banner

BW, BH = 1920, 600  # 2x master


def fabric_strip(w, h):
    """Wide crop of the clean key visual's fabric (red stitch + fingertips) for the band."""
    kvc = Image.open(os.path.join(PROMO, "overlock_key_visual_16x9_3840_clean.png")).convert("RGB")
    # below every fingertip: only purple fabric, the white edge stripe and red stitches
    ch = 360
    cw = round(ch * w / h)
    cx, top = 1920, 1800
    crop = kvc.crop((cx - cw // 2, top, cx - cw // 2 + cw, top + ch))
    return crop.resize((w, h), Image.LANCZOS)


def banner(plum_bg):
    cv = Image.new("RGBA", (BW, BH), (PLUM + (255,)) if plum_bg else (0, 0, 0, 0))
    # faint fabric band behind everything, pinked top and bottom edges
    band_h = 360
    by = (BH - band_h) // 2
    strip = fabric_strip(BW, band_h).convert("RGBA")
    mask = pinked_mask(BW, band_h, 12, edges="tb")
    strip.putalpha(mask.point(lambda v: v * 35 // 100))
    cv.alpha_composite(strip, (0, by))
    stitch = Image.new("RGBA", (BW, BH), (0, 0, 0, 0))
    for yy in (by + 30, by + band_h - 30):
        stitch.alpha_composite(running_stitch((BW, BH), yy, 24, BW - 24, 26, 18, 6, RED + (110,)))
    cv.alpha_composite(stitch)
    # logo left (840 px at 2x = 420 px at 1x)
    lg = kv.logo(840)
    lx, ly = 64, (BH - lg.height) // 2
    kv.paste_with_shadow(cv, lg, (lx, ly), radius=16, offset=(0, 10), opacity=0.55)
    # tagline ribbon + blurb in the right half
    rx0, rx1 = lx + lg.width + 40, BW - 56
    rcx = (rx0 + rx1) // 2
    tp = kv.tagline_plate(SUBTITLE, 84, pad=(54, 18))
    tp = tp.rotate(1, resample=Image.BICUBIC, expand=True)
    ty = 150
    kv.paste_with_shadow(cv, tp, (rcx - tp.width // 2, ty), radius=12, offset=(0, 8), opacity=0.5)
    if plum_bg:
        bl = kv.text_layer(BLURB, kv.font("Bold", 42), CREAM + (255,))
        cv.alpha_composite(bl, (rcx - bl.width // 2, ty + tp.height + 36))
    else:
        # transparent banner: the blurb sits on a plum pill (the key visual's URL tag) so it
        # reads on both light and dark page backgrounds
        bl = kv.text_layer(BLURB, kv.font("Bold", 40), CREAM + (255,))
        bl_pad = (40, 22)
        pill = kv.pinked_patch(bl.width + bl_pad[0] * 2, bl.height + bl_pad[1] * 2, PLUM + (215,),
                               PURPLE + (230,), zig=7, inset=10, stitch_w=4, dash=16, gap=10)
        pill.alpha_composite(bl, bl_pad)
        bl = pill
        cv.alpha_composite(bl, (rcx - bl.width // 2, ty + tp.height + 22))
    assert bl.width <= rx1 - rx0, bl.width
    return cv


# ---------------------------------------------------------------- 2. background tiles

T = 256


def tile_from(fabric, out=T):
    """Seamless out x out tile: resize the (already seamless) 1024 fabric with wrap
    padding so the Lanczos kernel never sees a clamped edge, then remap its luminance
    around Deep Plum."""
    src = Image.open(os.path.join(GFX, "fabrics", f"fabric_{fabric}.png")).convert("RGB")
    s = src.width
    big = Image.new("RGB", (s * 3, s * 3))
    for i in range(3):
        for j in range(3):
            big.paste(src, (i * s, j * s))
    big = big.resize((out * 3, out * 3), Image.LANCZOS)
    small = big.crop((out, out, out * 2, out * 2))
    a = np.asarray(small, dtype=np.float32) / 255.0
    lum = (a * [0.2126, 0.7152, 0.0722]).sum(-1)
    t = (lum - lum.mean()) / (lum.std() + 1e-6)
    plum = np.array(PLUM, dtype=np.float32) / 255.0
    rgb = plum[None, None, :] * (1.0 + 0.22 * np.clip(t, -2.5, 2.5))[..., None]
    return Image.fromarray(np.clip(rgb * 255 + 0.5, 0, 255).astype(np.uint8)).convert("RGBA")


def stitch_tile(base):
    """Base tile with two faint rows of red running stitch, drawn on a 3x3 canvas and
    cut from the centre so every dash that crosses an edge wraps around."""
    big = Image.new("RGBA", (T * 3, T * 3), (0, 0, 0, 0))
    for y in (64, 192):
        off = 0 if y == 64 else 16
        for k in range(3):
            row = running_stitch((T * 3, T * 3), y + k * T, -off, T * 3 - off, 18, 14, 4,
                                 RED + (80,), shadow=(10, 4, 14, 60))
            big.alpha_composite(row)
    out = base.copy()
    out.alpha_composite(big.crop((T, T, T * 2, T * 2)))
    return out


def repeat3(tile):
    out = Image.new("RGBA", (tile.width * 3, tile.height * 3))
    for i in range(3):
        for j in range(3):
            out.paste(tile, (i * tile.width, j * tile.height))
    return out


def stitch_period_check():
    # the stitch period (18 + 14) must divide the tile so rows wrap without a seam
    assert T % 32 == 0


# ---------------------------------------------------------------- 3. divider

def divider():
    w, h = 960, 12
    return running_stitch((w, h), 6, 6, w - 6, 18, 10, 4.5, RED + (255,), shadow=(90, 20, 30, 90))


# ---------------------------------------------------------------- 4. controls block

S = 2  # controls drawn at 2x


def keycap(cv, x, y, label, h=50):
    """Onepager keycap (tools/promo/onepager/make_onepager.py) scaled to the block; 1x units."""
    d = ImageDraw.Draw(cv)
    f = kv.font("Medium", (22 if len(label) > 1 else 26) * S)
    if label in ("<", ">", "^", "v"):
        w = h
    else:
        w = max(h, int(d.textlength(label, font=f) / S) + 34)
    X, Y, Wd, Hd = x * S, y * S, w * S, h * S
    d.rounded_rectangle((X, Y + 4 * S, X + Wd, Y + Hd + 4 * S), 10 * S, fill=(0x9C, 0x86, 0x68))
    d.rounded_rectangle((X, Y, X + Wd, Y + Hd), 10 * S, fill=(0xFB, 0xF5, 0xE6),
                        outline=(0x5A, 0x48, 0x3A), width=3 * S)
    cx, cy = X + Wd / 2, Y + Hd / 2
    a, b = 11 * S, 9 * S
    tri = {"<": [(cx + b, cy - a), (cx + b, cy + a), (cx - a, cy)],
           ">": [(cx - b, cy - a), (cx - b, cy + a), (cx + a, cy)],
           "^": [(cx - a, cy + b), (cx + a, cy + b), (cx, cy - a)],
           "v": [(cx - a, cy - b), (cx + a, cy - b), (cx, cy + a)]}
    if label in tri:
        d.polygon(tri[label], fill=(0x3A, 0x2C, 0x24))
    else:
        bb = d.textbbox((0, 0), label, font=f)
        d.text((cx - (bb[2] - bb[0]) / 2 - bb[0], cy - (bb[3] - bb[1]) / 2 - bb[1]), label,
               font=f, fill=(0x3A, 0x2C, 0x24))
    return w


def dashed_rrect(d, box, r, color, width, dash, gap):
    x0, y0, x1, y1 = box
    kv.dashed_polyline(d, kv.rounded_rect_pts(x0, y0, x1, y1, r), dash, gap, width, color, closed=True)


def controls():
    W1 = 960
    row_h = 62
    top = 84
    H1 = top + len(CONTROLS) * row_h + 74
    cv = Image.new("RGBA", (W1 * S, H1 * S), (0, 0, 0, 0))
    box = (8, 6, W1 - 8, H1 - 14)
    card = Image.new("RGBA", cv.size, (0, 0, 0, 0))
    ImageDraw.Draw(card).rounded_rectangle([v * S for v in box], 24 * S, fill=CARD + (255,),
                                           outline=CARD_EDGE + (255,), width=2 * S)
    sh = Image.new("RGBA", cv.size, (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle([v * S for v in (box[0] + 2, box[1] + 6, box[2] + 2,
                                                          box[3] + 6)], 24 * S,
                                         fill=(60, 36, 20, 70))
    cv.alpha_composite(sh.filter(ImageFilter.GaussianBlur(5 * S)))
    cv.alpha_composite(card)
    d = ImageDraw.Draw(cv)
    dashed_rrect(d, [(v + o) * S for v, o in zip(box, (10, 10, -10, -10))], 16 * S,
                 PURPLE + (255,), 3 * S, 13 * S, 9 * S)
    # title, letter-spaced like the onepager section titles
    ft = kv.font("SemiBold", 22 * S)
    title = " ".join("CONTROLS")
    d.text(((W1 * S - d.textlength(title, font=ft)) / 2, 30 * S), title, font=ft, fill=PURPLE_INK)
    fo = kv.font("Medium", 19 * S)
    fl = kv.font("Medium", 26 * S)
    for r, (keys, alt, label) in enumerate(CONTROLS):
        ry = top + r * row_h
        x = 190
        for k in keys:
            x += keycap(cv, x, ry, k) + 10
        d = ImageDraw.Draw(cv)
        if alt:
            d.text(((x + 6) * S, (ry + 13) * S), "또는", font=fo, fill=SUB)
            x += 60
            for k in alt:
                x += keycap(cv, x, ry, k) + 10
            d = ImageDraw.Draw(cv)
        d.text((560 * S, (ry + 9) * S), label, font=fl, fill=INK)
    fm = kv.font("Medium", 21 * S)
    my = top + len(CONTROLS) * row_h + 10
    d.text(((W1 * S - d.textlength(MOBILE, font=fm)) / 2, my * S), MOBILE, font=fm, fill=PURPLE_INK)
    return cv.resize((W1, H1), Image.LANCZOS)


# ---------------------------------------------------------------- 5. icons

I4 = 192  # icons drawn at 4x, saved at 48x48


def fit_box(im, box):
    s = min(box / im.width, box / im.height)
    return im.resize((max(1, round(im.width * s)), max(1, round(im.height * s))), Image.LANCZOS)


def centered_on(cv, sp, dx=0, dy=0):
    cv.alpha_composite(sp, ((cv.width - sp.width) // 2 + dx, (cv.height - sp.height) // 2 + dy))


def mini_key(d, x, y, s, label):
    d.rounded_rectangle((x, y + 8, x + s, y + s + 8), 12, fill=(0x9C, 0x86, 0x68, 255))
    d.rounded_rectangle((x, y, x + s, y + s), 12, fill=(0xFB, 0xF5, 0xE6, 255),
                        outline=(0x5A, 0x48, 0x3A, 255), width=6)
    cx, cy = x + s / 2, y + s / 2
    a, b = 14, 11
    tri = {"<": [(cx + b, cy - a), (cx + b, cy + a), (cx - a, cy)],
           ">": [(cx - b, cy - a), (cx - b, cy + a), (cx + a, cy)],
           "^": [(cx - a, cy + b), (cx + a, cy + b), (cx, cy - a)],
           "v": [(cx - a, cy - b), (cx + a, cy - b), (cx, cy + a)]}
    d.polygon(tri[label], fill=(0x3A, 0x2C, 0x24, 255))


def icon_controls():
    cv = Image.new("RGBA", (I4, I4), (0, 0, 0, 0))
    d = ImageDraw.Draw(cv)
    s, g = 56, 6
    x0 = (I4 - (3 * s + 2 * g)) // 2
    y0 = (I4 - (2 * s + g + 8)) // 2
    mini_key(d, x0 + s + g, y0, s, "^")
    for i, lab in enumerate(("<", "v", ">")):
        mini_key(d, x0 + i * (s + g), y0 + s + g, s, lab)
    return cv


def icon_rank():
    cv = Image.new("RGBA", (I4, I4), (0, 0, 0, 0))
    d = ImageDraw.Draw(cv)
    c, n = I4 / 2, 28
    r0, r1 = 88, 78
    pts = []
    for i in range(n * 2):
        a = math.pi * i / n - math.pi / 2
        r = r0 if i % 2 == 0 else r1
        pts.append((c + r * math.cos(a), c + r * math.sin(a)))
    d.polygon(pts, fill=PURPLE + (255,))
    ring = [(c + 64 * math.cos(2 * math.pi * k / 48), c + 64 * math.sin(2 * math.pi * k / 48))
            for k in range(48)]
    kv.dashed_polyline(d, ring, 12, 8, 5, CREAM + (255,), closed=True)
    t = kv.text_layer("S", kv.font("Black", 112), YELLOW + (255,), stroke=6, stroke_fill=PLUM + (255,))
    centered_on(cv, t, dx=1, dy=2)
    return cv


def icon_item():
    cv = Image.new("RGBA", (I4, I4), (0, 0, 0, 0))
    centered_on(cv, fit_box(kv.asset("item_thimble.png"), 188))
    return cv


def swatch(fabric, size, crop_xy, rot, stitch=True):
    src = Image.open(os.path.join(GFX, "fabrics", f"fabric_{fabric}.png")).convert("RGB")
    x, y = crop_xy
    tex = src.crop((x, y, x + 512, y + 512)).resize((size, size), Image.LANCZOS).convert("RGBA")
    tex.putalpha(pinked_mask(size, size, 7))
    d = ImageDraw.Draw(tex)
    if stitch:
        kv.dashed_polyline(d, kv.rounded_rect_pts(18, 18, size - 18, size - 18, 8), 12, 8, 5,
                           CREAM + (255,), closed=True)
    # thin dark edge so the swatch reads on cream
    edge = tex.getchannel("A").filter(ImageFilter.MaxFilter(5))
    out = Image.new("RGBA", tex.size, (40, 24, 20, 0))
    out.putalpha(edge.point(lambda v: v * 120 // 255))
    out.alpha_composite(tex)
    return out.rotate(rot, resample=Image.BICUBIC, expand=True)


def icon_fabric():
    cv = Image.new("RGBA", (I4, I4), (0, 0, 0, 0))
    back = swatch("felt", 118, (256, 256), 14, stitch=False)
    front = swatch("denim", 124, (200, 300), -8)
    cv.alpha_composite(back, (4, 0))
    cv.alpha_composite(front, (I4 - front.width - 2, I4 - front.height - 2))
    return cv


def icon_ghost():
    cv = Image.new("RGBA", (I4, I4), (0, 0, 0, 0))
    foot = fit_box(kv.asset("presser_foot.png"), 140)
    ghost = foot.copy()
    a = np.asarray(ghost, dtype=np.float32)
    lav = np.array(PURPLE, dtype=np.float32)
    a[..., :3] = a[..., :3] * 0.3 + lav * 0.7
    a[..., 3] *= 0.6
    ghost = Image.fromarray(a.astype(np.uint8), "RGBA")
    cv.alpha_composite(ghost, (0, 2))
    cv.alpha_composite(foot, (I4 - foot.width, I4 - foot.height - 6))
    return cv


def icon_editor():
    cv = Image.new("RGBA", (I4, I4), (0, 0, 0, 0))
    d = ImageDraw.Draw(cv)
    outline = (0x3A, 0x2C, 0x24, 255)
    # thread spool (left, upright)
    sx, sy, sw, sh = 16, 34, 74, 124
    d.rounded_rectangle((sx + 10, sy + 14, sx + sw - 10, sy + sh - 14), 6, fill=RED + (255,),
                        outline=outline, width=4)
    for k in range(5):
        yy = sy + 30 + k * 18
        d.line((sx + 14, yy, sx + sw - 14, yy + 6), fill=(0xB8, 0x24, 0x38, 255), width=3)
    for yy in (sy, sy + sh - 16):
        d.rounded_rectangle((sx, yy, sx + sw, yy + 16), 5, fill=(0xD9, 0xB0, 0x7A, 255),
                            outline=outline, width=4)
    # pencil (right, diagonal)
    pen = Image.new("RGBA", (I4, I4), (0, 0, 0, 0))
    p = ImageDraw.Draw(pen)
    L, Wp = 150, 30
    x0, y0 = (I4 - L) // 2, (I4 - Wp) // 2
    p.rectangle((x0 + 30, y0, x0 + L - 36, y0 + Wp), fill=YELLOW + (255,), outline=outline, width=4)
    p.line((x0 + 30, y0 + Wp // 2, x0 + L - 36, y0 + Wp // 2), fill=(0xE0, 0xA8, 0x20, 255), width=3)
    p.rounded_rectangle((x0, y0, x0 + 30, y0 + Wp), 8, fill=(0xF2, 0x8C, 0xA8, 255), outline=outline,
                        width=4)
    p.rectangle((x0 + 22, y0, x0 + 34, y0 + Wp), fill=(0xB8, 0xB8, 0xC4, 255), outline=outline, width=4)
    tip = [(x0 + L - 36, y0), (x0 + L, y0 + Wp / 2), (x0 + L - 36, y0 + Wp)]
    p.polygon(tip, fill=(0xF0, 0xD2, 0xA8, 255), outline=outline)
    p.line(tip + [tip[0]], fill=outline, width=4)
    p.polygon([(x0 + L - 12, y0 + Wp / 2 - 5), (x0 + L, y0 + Wp / 2), (x0 + L - 12, y0 + Wp / 2 + 5)],
              fill=outline)
    pen = pen.rotate(40, resample=Image.BICUBIC, center=(I4 / 2, I4 / 2))
    cv.alpha_composite(pen, (26, 4))
    return cv


ICONS = {
    "controls": icon_controls,
    "rank": icon_rank,
    "item": icon_item,
    "fabric": icon_fabric,
    "ghost": icon_ghost,
    "editor": icon_editor,
}


# ---------------------------------------------------------------- 7. headings

def heading(txt):
    w, h = 1920, 120  # 2x of 960x60
    cv = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    tl = kv.text_layer(txt, kv.font("ExtraBold", 54), CREAM + (255,))
    pw, ph = tl.width + 120, 104
    plate = kv.pinked_patch(pw, ph, PLUM + (255,), RED + (255,), zig=6, inset=14, stitch_w=4,
                            dash=20, gap=12)
    plate.alpha_composite(tl, ((pw - tl.width) // 2, (ph - tl.height) // 2))
    px = (w - pw) // 2
    side_gap = 28
    cv.alpha_composite(running_stitch((w, h), h // 2, 16, px - side_gap, 26, 16, 7, PURPLE + (255,)))
    cv.alpha_composite(running_stitch((w, h), h // 2, px + pw + side_gap, w - 16, 26, 16, 7,
                                      PURPLE + (255,)))
    cv.alpha_composite(drop_shadow(plate, 4, (0, 3), 0.35), (px, (h - ph) // 2))
    cv.alpha_composite(plate, (px, (h - ph) // 2))
    return cv


# ---------------------------------------------------------------- previews

def cover(im, w, h):
    s = max(w / im.width, h / im.height)
    im = im.resize((round(im.width * s), round(im.height * s)), Image.LANCZOS)
    x, y = (im.width - w) // 2, (im.height - h) // 2
    return im.crop((x, y, x + w, y + h))


def page_mock(out):
    """Reference composite of an itch.io page with these assets (not an upload)."""
    tile = Image.open(os.path.join(out, "bg_tile_256.png")).convert("RGBA")
    ban = Image.open(os.path.join(out, "banner_960x300.png")).convert("RGBA")
    hf = Image.open(os.path.join(out, "heading_features_960x60.png")).convert("RGBA")
    hc = Image.open(os.path.join(out, "heading_controls_960x60.png")).convert("RGBA")
    dv = Image.open(os.path.join(out, "divider_960x12.png")).convert("RGBA")
    ctl = Image.open(os.path.join(out, "controls_960.png")).convert("RGBA")
    icons = [Image.open(os.path.join(out, f"icon_{k}.png")).convert("RGBA") for k in ICONS]
    margin, col = 100, 960
    W = col + margin * 2
    H = 30 + 300 + 20 + 1500
    page = Image.new("RGBA", (W, H))
    for x in range(0, W, T):
        for y in range(0, H, T):
            page.paste(tile, (x, y))
    page.alpha_composite(ban, (margin, 30))
    y0 = 30 + 300 + 20
    d = ImageDraw.Draw(page)
    d.rectangle((margin, y0, margin + col, H), fill=CREAM + (255,))
    pad = 32
    y = y0 + 28
    page.alpha_composite(hf, (margin, y))
    y += 60 + 20
    feats = ["조작은 두 가지, 꼭짓점은 드리프트", "정직하게 박을수록 높은 등급",
             "골무·엄마 찬스 아이템 슬롯", "원단 8종, 원단마다 다른 주행감",
             "내 최고 기록과 달리는 개인 고스트", "트랙 에디터와 공유 허브"]
    fb = kv.font("Medium", 22)
    for i, (ic, txt) in enumerate(zip(icons, feats)):
        cx = margin + pad + (i % 2) * (col // 2)
        cy = y + (i // 2) * 64
        page.alpha_composite(ic, (cx, cy))
        d.text((cx + 62, cy + 10), txt, font=fb, fill=PAGE_TEXT)
    y += 3 * 64 + 16
    page.alpha_composite(dv, (margin, y))
    y += 12 + 24
    tw = (col - pad * 2 - 20) // 2
    th = round(tw * 9 / 16)
    for i, fn in enumerate(("gameplay_fold.png", "gameplay_ghost.png")):
        shot = cover(Image.open(os.path.join(SHOTS, fn)).convert("RGB"), tw, th)
        page.paste(shot, (margin + pad + i * (tw + 20), y))
    y += th + 24
    page.alpha_composite(dv, (margin, y))
    y += 12 + 24
    page.alpha_composite(hc, (margin, y))
    y += 60 + 16
    page.alpha_composite(ctl, (margin, y))
    y += ctl.height + 30
    return page.crop((0, 0, W, y)).convert("RGB")


def previews(out):
    pv = os.path.join(out, "preview")
    ban = Image.open(os.path.join(out, "banner_960x300.png")).convert("RGBA")
    banp = Image.open(os.path.join(out, "banner_960x300_plum.png")).convert("RGBA")
    save(on_bg(ban, CREAM).convert("RGB"), os.path.join(pv, "preview_banner_on_cream.png"))
    on_plum = Image.new("RGBA", (960, 640), PLUM + (255,))
    on_plum.alpha_composite(ban, (0, 10))
    on_plum.alpha_composite(banp, (0, 330))
    save(on_plum.convert("RGB"), os.path.join(pv, "preview_banner_on_plum.png"))
    for name in ("bg_tile_256", "bg_tile_stitch_256"):
        t = Image.open(os.path.join(out, f"{name}.png")).convert("RGBA")
        save(repeat3(t).convert("RGB"), os.path.join(pv, f"preview_{name}_3x3.png"))
    dv = Image.open(os.path.join(out, "divider_960x12.png")).convert("RGBA")
    dprev = Image.new("RGBA", (960, 80), CREAM + (255,))
    dprev.alpha_composite(dv, (0, 20))
    dprev.alpha_composite(on_bg(dv, PLUM), (0, 50))
    save(dprev.convert("RGB"), os.path.join(pv, "preview_divider_on_cream.png"))
    ctl = Image.open(os.path.join(out, "controls_960.png")).convert("RGBA")
    save(on_bg(ctl, CREAM).convert("RGB"), os.path.join(pv, "preview_controls_on_cream.png"))
    # icons at 1x and 3x on cream and plum
    keys = list(ICONS)
    ip = Image.new("RGBA", (len(keys) * 160, 300), CREAM + (255,))
    ImageDraw.Draw(ip).rectangle((0, 150, ip.width, 300), fill=PLUM + (255,))
    for i, k in enumerate(keys):
        ic = Image.open(os.path.join(out, f"icon_{k}.png")).convert("RGBA")
        for row, y in ((0, 0), (1, 150)):
            ip.alpha_composite(ic, (i * 160 + 8, y + 50))
            ip.alpha_composite(ic.resize((96, 96), Image.NEAREST), (i * 160 + 60, y + 26))
    save(ip.convert("RGB"), os.path.join(pv, "preview_icons.png"))
    hp = Image.new("RGBA", (960, 160), CREAM + (255,))
    hp.alpha_composite(Image.open(os.path.join(out, "heading_features_960x60.png")), (0, 10))
    hp.alpha_composite(Image.open(os.path.join(out, "heading_controls_960x60.png")), (0, 90))
    save(hp.convert("RGB"), os.path.join(pv, "preview_headings_on_cream.png"))
    save(page_mock(out), os.path.join(pv, "preview_page_mock.png"))


# ---------------------------------------------------------------- main

def build(out, with_preview=True):
    os.makedirs(out, exist_ok=True)
    for plum_bg, name in ((False, "banner_960x300.png"), (True, "banner_960x300_plum.png")):
        m = banner(plum_bg)
        if not plum_bg:
            save(m, os.path.join(out, "banner_1920x600.png"))
        save(m.convert("RGB") if plum_bg else m, os.path.join(out, name), (960, 300))
    stitch_period_check()
    base = tile_from("denim")
    save(base.convert("RGB"), os.path.join(out, "bg_tile_256.png"))
    save(stitch_tile(base).convert("RGB"), os.path.join(out, "bg_tile_stitch_256.png"))
    save(divider(), os.path.join(out, "divider_960x12.png"))
    save(controls(), os.path.join(out, "controls_960.png"))
    for k, fn in ICONS.items():
        save(fn(), os.path.join(out, f"icon_{k}.png"), (48, 48))
    for k, txt in HEADINGS.items():
        save(heading(txt), os.path.join(out, f"heading_{k}_960x60.png"), (960, 60))
    if with_preview:
        previews(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=OUT_DEFAULT, help="output folder (default docs/promo/itch)")
    ap.add_argument("--no-preview", action="store_true", help="skip the reference previews")
    a = ap.parse_args()
    build(a.out, not a.no_preview)


if __name__ == "__main__":
    main()
