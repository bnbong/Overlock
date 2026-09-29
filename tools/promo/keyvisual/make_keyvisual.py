#!/usr/bin/env python3
"""Overlock 16:9 key visual compositor.

Builds the key visual from real in-game stills (docs/promo/video/footage/stills)
and existing brand assets (game/assets/gfx). Everything is drawn on a
3840x2160 master canvas; smaller outputs are Lanczos downsamples of it.

Usage:
    python make_keyvisual.py --variant A --out out.png [--clean] [--size 1920]
    python make_keyvisual.py --final            # writes all deliverables

All coordinates below are in master (3840x2160) pixels.
"""

import argparse
import math
import os

import numpy as np
from PIL import Image, ImageCms, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
STILLS = os.path.join(ROOT, "docs", "promo", "video", "footage", "stills")
GFX = os.path.join(ROOT, "game", "assets", "gfx")
FONTS = os.path.join(ROOT, "tools", "promo", "fonts")
PROMO = os.path.join(ROOT, "docs", "promo")

W, H = 3840, 2160

# Shared promo colour tokens.
THREAD_PURPLE = (0x8D, 0x62, 0xB9)
DEEP_PLUM = (0x2A, 0x18, 0x38)
FABRIC_CREAM = (0xF3, 0xE7, 0xC9)
STITCH_RED = (0xE5, 0x36, 0x4B)
STAR_YELLOW = (0xFF, 0xD4, 0x3B)
INK_BROWN = (0x47, 0x34, 0x2A)

TAGLINE = "원단 위를 달리는 재봉틀 레이싱"
URL = "overlock.bnbong.com"
SCOLD = "이녀석, 제대로 해야지!"


# ---------------------------------------------------------------- helpers

def font(weight, size):
    return ImageFont.truetype(os.path.join(FONTS, f"Pretendard-{weight}.otf"), size)


def still(name):
    return Image.open(os.path.join(STILLS, name)).convert("RGB")


def asset(rel, crop_alpha=True):
    im = Image.open(os.path.join(GFX, rel)).convert("RGBA")
    if crop_alpha:
        bbox = im.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox()
        im = im.crop(bbox)
    return im


def fit_width(im, w):
    h = round(im.height * w / im.width)
    return im.resize((w, h), Image.LANCZOS)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def tilt_fill(im, deg):
    """Rotate and scale up just enough that no empty corner shows."""
    th = math.radians(abs(deg))
    s = math.cos(th) + max(W / H, H / W) * math.sin(th)
    big = im.resize((round(W * s), round(H * s)), Image.LANCZOS)
    rot = big.rotate(deg, resample=Image.BICUBIC, expand=False)
    l = (rot.width - W) // 2
    t = (rot.height - H) // 2
    # recover the little acuity lost to the ~6% upscale + bicubic rotation
    return rot.crop((l, t, l + W, t + H)).filter(ImageFilter.UnsharpMask(radius=2.2, percent=45, threshold=2))


def zoom_blur(im, center, max_scale, steps, inner, outer):
    """Radial zoom blur that fades in from `inner` to `outer` (fractions of the
    half diagonal measured from `center`). The centre stays untouched."""
    base = np.asarray(im, dtype=np.float32)
    acc = np.zeros_like(base)
    cx, cy = center
    for i in range(steps):
        s = 1.0 + max_scale * i / max(1, steps - 1)
        big = im.resize((round(im.width * s), round(im.height * s)), Image.BILINEAR)
        l = round(cx * s - cx)
        t = round(cy * s - cy)
        acc += np.asarray(big.crop((l, t, l + im.width, t + im.height)), dtype=np.float32)
    acc /= steps
    yy, xx = np.mgrid[0:im.height, 0:im.width].astype(np.float32)
    d = np.hypot(xx - cx, yy - cy) / math.hypot(W / 2, H / 2)
    m = smoothstep(inner, outer, d)[..., None]
    out = base * (1 - m) + acc * m
    return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8))


def grade(im, contrast=1.05, sat=1.06, tint=0.06, vignette=0.42, vcenter=(0.5, 0.45)):
    """Mild contrast/saturation lift, plum tint in the shadows, plum vignette."""
    a = np.asarray(im, dtype=np.float32) / 255.0
    lum = (a * [0.2126, 0.7152, 0.0722]).sum(-1, keepdims=True)
    a = lum + (a - lum) * sat
    a = (a - 0.5) * contrast + 0.5
    plum = np.array(DEEP_PLUM, dtype=np.float32) / 255.0
    shadow = (1 - np.clip(lum * 1.6, 0, 1)) * tint
    a = a * (1 - shadow) + plum * shadow
    yy, xx = np.mgrid[0:im.height, 0:im.width].astype(np.float32)
    nx = (xx / im.width - vcenter[0]) * 1.0
    ny = (yy / im.height - vcenter[1]) * (im.height / im.width) * 1.25
    d = np.sqrt(nx * nx + ny * ny) / 0.62
    v = smoothstep(0.55, 1.15, d)[..., None] * vignette
    a = a * (1 - v) + plum * v
    return Image.fromarray(np.clip(a * 255, 0, 255).astype(np.uint8))


def gradient_band(y0, y1, color, a0, a1, width=W):
    """Vertical alpha gradient layer (RGBA, full canvas)."""
    lay = np.zeros((H, width, 4), dtype=np.float32)
    lay[..., :3] = color
    t = smoothstep(y0, y1, np.arange(H, dtype=np.float32))
    lay[..., 3] = (a0 + (a1 - a0) * t)[:, None] * 255
    return Image.fromarray(lay.astype(np.uint8), "RGBA")


def shadow_of(layer, radius, offset, opacity, color=(20, 10, 28)):
    a = layer.getchannel("A").filter(ImageFilter.GaussianBlur(radius))
    a = a.point(lambda v: int(v * opacity))
    sh = Image.new("RGBA", layer.size, color + (0,))
    sh.putalpha(a)
    out = Image.new("RGBA", layer.size, (0, 0, 0, 0))
    out.alpha_composite(sh, offset)
    return out


def paste_with_shadow(canvas, sprite, xy, radius=28, offset=(0, 18), opacity=0.55, rotate=0.0):
    if rotate:
        sprite = sprite.rotate(rotate, resample=Image.BICUBIC, expand=True)
    pad = radius * 3 + max(abs(offset[0]), abs(offset[1]))
    lay = Image.new("RGBA", (sprite.width + pad * 2, sprite.height + pad * 2), (0, 0, 0, 0))
    lay.alpha_composite(sprite, (pad, pad))
    sh = shadow_of(lay, radius, offset, opacity)
    x, y = xy[0] - pad, xy[1] - pad
    _paste_clip(canvas, sh, x, y)
    _paste_clip(canvas, lay, x, y)
    return sprite.size


def _paste_clip(canvas, lay, x, y):
    tmp = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    tmp.paste(lay, (x, y), lay)
    canvas.alpha_composite(tmp)


def dashed_polyline(draw, pts, dash, gap, width, fill, closed=False):
    if closed:
        pts = list(pts) + [pts[0]]
    carry = 0.0
    on = True
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        seg = math.hypot(x1 - x0, y1 - y0)
        if seg == 0:
            continue
        ux, uy = (x1 - x0) / seg, (y1 - y0) / seg
        pos = 0.0
        while seg - pos > 1e-6:
            length = (dash if on else gap) - carry
            end = min(seg, pos + length)
            if on:
                draw.line([(x0 + ux * pos, y0 + uy * pos), (x0 + ux * end, y0 + uy * end)],
                          fill=fill, width=width)
            if length - (end - pos) > 1e-6:
                carry += end - pos
            else:
                carry = 0.0
                on = not on
            pos = end


def rounded_rect_pts(x0, y0, x1, y1, r, n=10):
    pts = []
    for cx, cy, a0 in ((x1 - r, y0 + r, -90), (x1 - r, y1 - r, 0), (x0 + r, y1 - r, 90), (x0 + r, y0 + r, 180)):
        for i in range(n + 1):
            a = math.radians(a0 + 90 * i / n)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def ss_layer(size, ss=2):
    """Supersampled RGBA layer for crisp anti-aliased vector drawing."""
    return Image.new("RGBA", (size[0] * ss, size[1] * ss), (0, 0, 0, 0))


def ss_down(lay, ss=2):
    return lay.resize((lay.width // ss, lay.height // ss), Image.LANCZOS)


def weave_texture(size, base, seed=7):
    """Procedural plain-weave fabric in `base` colour."""
    w, h = size
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    p = 9.0
    warp = 0.5 + 0.5 * np.sin(xx * 2 * math.pi / p)
    weft = 0.5 + 0.5 * np.sin(yy * 2 * math.pi / p)
    checker = ((np.floor(xx / p) + np.floor(yy / p)) % 2)
    tex = np.where(checker > 0, warp, weft) * 0.06 - 0.03
    noise = rng.normal(0, 1, (h // 4 + 1, w // 4 + 1)).astype(np.float32)
    noise = np.asarray(Image.fromarray(noise).resize((w, h), Image.BICUBIC)) * 0.02
    b = np.array(base, dtype=np.float32) / 255.0
    a = b[None, None, :] * (1 + tex[..., None] + noise[..., None])
    return Image.fromarray(np.clip(a * 255, 0, 255).astype(np.uint8)).convert("RGBA")


def text_layer(txt, fnt, fill, stroke=0, stroke_fill=None, tracking=0):
    """Render text (optionally letter-spaced) on its own tight RGBA layer."""
    tmp = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
    if tracking == 0:
        l, t, r, b = tmp.textbbox((0, 0), txt, font=fnt, stroke_width=stroke)
        lay = Image.new("RGBA", (r - l, b - t), (0, 0, 0, 0))
        ImageDraw.Draw(lay).text((-l, -t), txt, font=fnt, fill=fill,
                                 stroke_width=stroke, stroke_fill=stroke_fill)
        return lay
    widths = [tmp.textlength(c, font=fnt) for c in txt]
    total = sum(widths) + tracking * (len(txt) - 1)
    asc, desc = fnt.getmetrics()
    lay = Image.new("RGBA", (int(total + stroke * 2 + 4), asc + desc + stroke * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    x = stroke
    for c, cw in zip(txt, widths):
        d.text((x, stroke), c, font=fnt, fill=fill, stroke_width=stroke, stroke_fill=stroke_fill)
        x += cw + tracking
    return lay.crop(lay.getchannel("A").getbbox())


def pinked_patch(w, h, fill, stitch, zig=22, inset=34, stitch_w=7, dash=34, gap=22, ss=2):
    """Fabric patch with pinking-shear (zigzag) edges and an inner running stitch."""
    lay = ss_layer((w, h), ss)
    d = ImageDraw.Draw(lay)
    Z = zig * ss
    W2, H2 = w * ss, h * ss
    pts = []
    n = max(2, round(W2 / (Z * 2)))
    for i in range(n + 1):
        pts.append((W2 * i / n, Z if i % 2 else 0))
    m = max(2, round(H2 / (Z * 2)))
    for i in range(1, m + 1):
        pts.append((W2 - (Z if i % 2 else 0), H2 * i / m))
    for i in range(1, n + 1):
        pts.append((W2 - W2 * i / n, H2 - (Z if i % 2 else 0)))
    for i in range(1, m):
        pts.append((Z if i % 2 else 0, H2 - H2 * i / m))
    d.polygon(pts, fill=fill)
    I = inset * ss
    dashed_polyline(d, rounded_rect_pts(I, I, W2 - I, H2 - I, 18 * ss), dash * ss, gap * ss,
                    stitch_w * ss, stitch, closed=True)
    return ss_down(lay, ss)


def stitched_frame(canvas, box, color, width=8, dash=40, gap=26, r=40):
    lay = ss_layer(canvas.size)
    d = ImageDraw.Draw(lay)
    x0, y0, x1, y1 = [v * 2 for v in box]
    dashed_polyline(d, rounded_rect_pts(x0, y0, x1, y1, r * 2), dash * 2, gap * 2, width * 2, color,
                    closed=True)
    canvas.alpha_composite(ss_down(lay))


def logo(width):
    return fit_width(asset("overlock_logo.png"), width)


def tagline_plate(txt, size, fg=FABRIC_CREAM, bg=DEEP_PLUM, accent=STITCH_RED, pad=(64, 30)):
    """Tagline on a dark ribbon with a running stitch; returns RGBA."""
    tl = text_layer(txt, font("ExtraBold", size), fg + (255,))
    w = tl.width + pad[0] * 2
    h = tl.height + pad[1] * 2 + 20
    plate = pinked_patch(w, h, bg + (236,), accent + (255,), zig=14, inset=16, stitch_w=5,
                         dash=26, gap=16)
    plate.alpha_composite(tl, (pad[0], (h - tl.height) // 2))
    return plate


# ---------------------------------------------------------------- variants

def base_game(name, tilt, blur_center, blur=(0.045, 10, 0.42, 0.95), grade_kw=None):
    im = still(name)
    assert im.size == (W, H), im.size
    if tilt:
        im = tilt_fill(im, tilt)
    if blur:
        im = zoom_blur(im, blur_center, *blur)
    return grade(im, **(grade_kw or {})).convert("RGBA")


def speed_streaks(center, count, r0, r1, a0, a1, color, alpha, width, seed=3):
    """Thin tapered streaks radiating away from `center` (angles in degrees,
    0 = right, 90 = down). Drawn supersampled; returns an RGBA layer."""
    rng = np.random.default_rng(seed)
    ss = 2
    lay = ss_layer((W, H), ss)
    d = ImageDraw.Draw(lay)
    cx, cy = center
    for _ in range(count):
        ang = math.radians(rng.uniform(a0, a1))
        ra = rng.uniform(r0, r1)
        rb = ra + rng.uniform(260, 700)
        ux, uy = math.cos(ang), math.sin(ang)
        wmax = rng.uniform(0.5, 1.0) * width
        a = int(alpha * rng.uniform(0.45, 1.0))
        n = 8
        for k in range(n):
            t0, t1 = k / n, (k + 1) / n
            p0 = (cx + ux * (ra + (rb - ra) * t0), cy + uy * (ra + (rb - ra) * t0))
            p1 = (cx + ux * (ra + (rb - ra) * t1), cy + uy * (ra + (rb - ra) * t1))
            w = max(1, int(wmax * ss * (0.25 + 0.75 * t1)))
            fade = math.sin(math.pi * (t0 + t1) / 2)
            d.line([(p0[0] * ss, p0[1] * ss), (p1[0] * ss, p1[1] * ss)],
                   fill=color + (int(a * fade),), width=w)
    return ss_down(lay, ss)


def variant_a(clean):
    """Full-bleed curve frame, slight lean, logo + tagline lower-left."""
    vp = (1920, 960)  # vanishing point just under the presser foot
    cv = base_game("heart01_curve02_3840x2160_nohud.png", tilt=-2.0, blur_center=(1920, 1300),
                   grade_kw={"vcenter": (0.52, 0.42)})
    cv.alpha_composite(speed_streaks(vp, 70, 1450, 2100, 18, 162, FABRIC_CREAM, 120, 10))
    # darken lower-left for type contrast
    g = np.zeros((H, W, 4), dtype=np.float32)
    g[..., :3] = DEEP_PLUM
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    d = np.hypot((xx - 0) / 2300, (yy - H) / 1100)
    g[..., 3] = (1 - smoothstep(0.35, 1.0, d)) * 0.78 * 255
    cv.alpha_composite(Image.fromarray(g.astype(np.uint8), "RGBA"))
    if not clean:
        lx, ly = 196, 1320
        lw, lh = paste_with_shadow(cv, logo(1500), (lx, ly), radius=30, offset=(0, 22),
                                   opacity=0.6, rotate=0)
        tp = tagline_plate(TAGLINE, 96)
        tp = tp.rotate(1, resample=Image.BICUBIC, expand=True)
        paste_with_shadow(cv, tp, (lx + (lw - tp.width) // 2, ly + lh - 72), radius=18,
                          offset=(0, 10), opacity=0.5)
        u = text_layer(URL, font("Bold", 56), FABRIC_CREAM + (240,), tracking=2)
        pill = pinked_patch(u.width + 84, u.height + 60, DEEP_PLUM + (190,), THREAD_PURPLE + (220,),
                            zig=8, inset=12, stitch_w=4, dash=18, gap=12)
        pill.alpha_composite(u, (42, 30))
        cv.alpha_composite(pill, (W - 210 - pill.width, 200))
    return cv


def variant_b(clean):
    """Split: plum fabric type panel on the left, game frame on the right."""
    game = still("star01_drift02_3840x2160_nohud.png")
    game = zoom_blur(game, (1920, 1320), 0.04, 10, 0.42, 0.95)
    game = grade(game, vcenter=(0.5, 0.45), vignette=0.3).convert("RGBA")
    cv = Image.new("RGBA", (W, H))
    # shift frame right so the presser foot sits at x=2440
    cv.alpha_composite(game.crop((0, 0, W, H)), (520, 0))
    # fill the uncovered strip at far left (hidden under the panel anyway)
    # slanted panel with pinked edge
    panel_top, panel_bot = 1500, 1180
    lay = ss_layer((W, H))
    d = ImageDraw.Draw(lay)
    zig = 26
    edge = []
    n = 60
    for i in range(n + 1):
        t = i / n
        x = panel_top + (panel_bot - panel_top) * t + (zig if i % 2 else 0)
        edge.append((x * 2, H * t * 2))
    d.polygon([(0, 0)] + edge + [(0, H * 2)], fill=DEEP_PLUM + (255,))
    panel_mask = ss_down(lay).getchannel("A")
    tex = weave_texture((W, H), DEEP_PLUM)
    tex.putalpha(panel_mask)
    cv.alpha_composite(shadow_of(tex, 30, (14, 0), 0.7))
    cv.alpha_composite(tex)
    # running stitch parallel to the pinked edge
    lay = ss_layer((W, H))
    d = ImageDraw.Draw(lay)
    dashed_polyline(d, [((panel_top - 70) * 2, 0), ((panel_bot - 70) * 2, H * 2)], 80, 52, 16,
                    THREAD_PURPLE + (255,))
    cv.alpha_composite(ss_down(lay))
    if not clean:
        lg = logo(1300)
        paste_with_shadow(cv, lg, (110, 560), radius=26, offset=(0, 20), opacity=0.6, rotate=3)
        tl = text_layer(TAGLINE, font("ExtraBold", 80), FABRIC_CREAM + (255,))
        cv.alpha_composite(tl, (200, 1300))
        ul = ss_layer((W, H))
        dashed_polyline(ImageDraw.Draw(ul), [(200 * 2, 1450 * 2), ((200 + tl.width) * 2, 1450 * 2)],
                        60, 36, 14, STITCH_RED + (255,))
        cv.alpha_composite(ss_down(ul))
        u = text_layer(URL, font("SemiBold", 64), THREAD_PURPLE + (255,), tracking=2)
        cv.alpha_composite(u, (200, 1880))
    return cv


def variant_c(clean):
    """Collage: tilted game card on plum fabric with mom sticker and thimble."""
    cv = weave_texture((W, H), (0x3A, 0x22, 0x4E))
    # radial light behind the card
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    d = np.hypot((xx - W / 2) / W, (yy - H * 0.55) / H)
    glow = np.zeros((H, W, 4), dtype=np.float32)
    glow[..., :3] = THREAD_PURPLE
    glow[..., 3] = (1 - smoothstep(0.0, 0.55, d)) * 0.55 * 255
    cv.alpha_composite(Image.fromarray(glow.astype(np.uint8), "RGBA"))
    cw, ch = 2720, 1530
    game = grade(still("heart01_curve03_3840x2160_nohud.png"), vignette=0.2).resize((cw, ch), Image.LANCZOS)
    card = Image.new("RGBA", (cw + 60, ch + 60), FABRIC_CREAM + (255,))
    card.paste(game, (30, 30))
    stitched_frame(card, (12, 12, cw + 48, ch + 48), THREAD_PURPLE + (255,), width=6, dash=30, gap=18, r=10)
    paste_with_shadow(cv, card, (560, 520), radius=40, offset=(0, 30), opacity=0.7, rotate=-2.5)
    mom = fit_width(asset("ui/mom_scolding.png"), 760)
    paste_with_shadow(cv, mom, (180, 1260), radius=24, offset=(0, 16), opacity=0.55, rotate=6)
    th = fit_width(asset("item_thimble.png"), 420)
    paste_with_shadow(cv, th, (3280, 1540), radius=20, offset=(0, 14), opacity=0.5, rotate=-12)
    if not clean:
        lg = logo(1500)
        paste_with_shadow(cv, lg, ((W - 1500) // 2, 110), radius=30, offset=(0, 22), opacity=0.65)
        tp = tagline_plate(TAGLINE, 84)
        paste_with_shadow(cv, tp, ((W - tp.width) // 2, 1880), radius=18, offset=(0, 10), opacity=0.5)
        bub = pinked_patch(820, 180, FABRIC_CREAM + (255,), STITCH_RED + (255,), zig=10, inset=16,
                           stitch_w=4, dash=20, gap=12)
        t = text_layer(SCOLD, font("ExtraBold", 72), INK_BROWN + (255,))
        bub.alpha_composite(t, ((820 - t.width) // 2, (180 - t.height) // 2))
        paste_with_shadow(cv, bub, (700, 1260), radius=16, offset=(0, 10), opacity=0.5, rotate=4)
    return cv


VARIANTS = {"A": variant_a, "B": variant_b, "C": variant_c}


def render(variant, clean=False):
    im = VARIANTS[variant](clean).convert("RGB")
    assert im.size == (W, H)
    return im


def save(im, path, size=None, quality=None):
    if size:
        im = im.resize(size, Image.LANCZOS)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    icc = bytearray(ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes())
    icc[24:36] = bytes(12)  # blank the header creation date so rebuilds are byte-identical
    icc = bytes(icc)
    if path.lower().endswith(".jpg"):
        im.save(path, "JPEG", quality=quality or 90, subsampling=0, optimize=True, progressive=True,
                icc_profile=icc)
    else:
        im.save(path, "PNG", optimize=True, icc_profile=icc)
    print("wrote", path, im.size)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant", default="A", choices=sorted(VARIANTS))
    ap.add_argument("--out")
    ap.add_argument("--size", type=int, help="output width (16:9); default master 3840")
    ap.add_argument("--clean", action="store_true", help="omit logo and copy")
    ap.add_argument("--final", action="store_true", help="write every deliverable")
    args = ap.parse_args()
    if args.final:
        final_variant = "A"
        master = render(final_variant)
        save(master, os.path.join(PROMO, "overlock_key_visual_16x9_3840.png"))
        save(master, os.path.join(PROMO, "overlock_key_visual_16x9_1920.png"), (1920, 1080))
        save(master, os.path.join(PROMO, "overlock_key_visual_16x9_1280.jpg"), (1280, 720), 90)
        save(render(final_variant, clean=True),
             os.path.join(PROMO, "overlock_key_visual_16x9_3840_clean.png"))
        alt_dir = os.path.join(PROMO, "keyvisual_alternatives")
        for v in sorted(VARIANTS):
            if v != final_variant:
                save(render(v), os.path.join(alt_dir, f"overlock_key_visual_alt_{v}_1920.jpg"),
                     (1920, 1080), 90)
        return
    im = render(args.variant, args.clean)
    size = (args.size, args.size * 9 // 16) if args.size else None
    save(im, args.out, size)


if __name__ == "__main__":
    main()
