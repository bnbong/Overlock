#!/usr/bin/env python3
"""Overlock itch.io cover (630x500) compositor.

Same recipe as the 16:9 key visual (make_keyvisual.py: slight clockwise lean,
radial zoom blur around the presser foot, mild grade + Deep Plum vignette,
plum gradient under the logo) re-framed for itch.io's 1.26:1 cover slot.

The background is a HUD-less 3840x2160 drift still rendered by the promo
capture driver (fabric fold rising in front of the right fingertips). Stills
are not committed; pass the folder that holds them with --stills.

Usage:
    python make_itch_cover.py --stills <dir> --final      # both deliverables + alternatives
    python make_itch_cover.py --stills <dir> --variant B --out b.png [--size 630]

All layout numbers below are in master (2520x2000) pixels; the 1260x1000 and
630x500 outputs are Lanczos downsamples of the master.
"""

import argparse
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

import make_keyvisual as kv

PROMO = kv.PROMO
CW, CH = 2520, 2000          # master canvas (2x of 1260x1000, 4x of 630x500)
SRC_W, SRC_H = 3840, 2160    # capture still size

TAGLINE = "~재봉틀 레이싱~"


def still(stills_dir, name):
    im = Image.open(os.path.join(stills_dir, name)).convert("RGB")
    assert im.size == (SRC_W, SRC_H), im.size
    return im


def lean_crop(im, center, crop_h, deg):
    """Rotate the still by `deg` (negative = clockwise) about `center`, then cut
    a 1.26:1 box of height `crop_h` centred there and scale it to the master
    canvas. Asserts that no rotated-in empty corner reaches the box."""
    crop_w = round(crop_h * CW / CH)
    cx, cy = center
    th = math.radians(deg)
    for sx in (-1, 1):
        for sy in (-1, 1):
            dx, dy = sx * crop_w / 2, sy * crop_h / 2
            # source pixel that lands on this box corner after rotation
            x = cx + dx * math.cos(th) - dy * math.sin(th)
            y = cy + dx * math.sin(th) + dy * math.cos(th)
            assert 0 <= x <= SRC_W and 0 <= y <= SRC_H, ("empty corner", x, y)
    rot = im.rotate(deg, resample=Image.BICUBIC, center=center) if deg else im
    box = (round(cx - crop_w / 2), round(cy - crop_h / 2),
           round(cx - crop_w / 2) + crop_w, round(cy - crop_h / 2) + crop_h)
    out = rot.crop(box).resize((CW, CH), Image.LANCZOS)
    return out.filter(ImageFilter.UnsharpMask(radius=2.0, percent=40, threshold=2))


def zoom_blur(im, center, max_scale, steps, inner, outer):
    """kv.zoom_blur for the cover canvas (distance normalised to its half diagonal)."""
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
    d = np.hypot(xx - cx, yy - cy) / math.hypot(im.width / 2, im.height / 2)
    m = kv.smoothstep(inner, outer, d)[..., None]
    out = base * (1 - m) + acc * m
    return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8))


def corner_shade(cv, corner, rx, ry, alpha):
    """Deep Plum elliptical shade anchored at a canvas corner, for type contrast."""
    g = np.zeros((CH, CW, 4), dtype=np.float32)
    g[..., :3] = kv.DEEP_PLUM
    yy, xx = np.mgrid[0:CH, 0:CW].astype(np.float32)
    ox, oy = corner
    d = np.hypot((xx - ox) / rx, (yy - oy) / ry)
    g[..., 3] = (1 - kv.smoothstep(0.35, 1.0, d)) * alpha * 255
    cv.alpha_composite(Image.fromarray(g.astype(np.uint8), "RGBA"))


# Each variant: still, crop centre/height (source px), lean, blur centre (master px),
# logo box and whether the tagline ribbon goes under it.
VARIANTS = {
    # chosen: biggest, clearest fold under the right fingertips, stitch line
    # sweeping to the lower right, logo lower-left like the key visual
    "A": dict(still="heart01_fold11_3840x2160_nohud.png", center=(2000, 1110), crop_h=1980,
              tilt=-2.0, blur_center=(1180, 1300), shade=((0, CH), 1500, 820, 0.78),
              logo=dict(x=104, y=1250, w=1120), tagline=True, vcenter=(0.52, 0.42)),
    # same frame two-thirds of a second earlier: fold flatter but longer, stitch
    # line hugging the white edge stripe
    "B": dict(still="heart01_fold01_3840x2160_nohud.png", center=(2000, 1110), crop_h=1980,
              tilt=-2.0, blur_center=(1180, 1300), shade=((0, CH), 1500, 820, 0.78),
              logo=dict(x=104, y=1250, w=1120), tagline=True, vcenter=(0.52, 0.42)),
    # fold right under the fingertips with the red stitch riding over it; logo only,
    # no tagline
    "C": dict(still="heart01_fold07_3840x2160_nohud.png", center=(2000, 1110), crop_h=1980,
              tilt=-2.0, blur_center=(1180, 1300), shade=((0, CH), 1500, 820, 0.78),
              logo=dict(x=104, y=1330, w=1120), tagline=False, vcenter=(0.52, 0.42)),
}


def render(stills_dir, variant, clean=False):
    v = VARIANTS[variant]
    im = lean_crop(still(stills_dir, v["still"]), v["center"], v["crop_h"], v["tilt"])
    im = zoom_blur(im, v["blur_center"], 0.04, 10, 0.45, 1.0)
    cv = kv.grade(im, vignette=0.42, vcenter=v["vcenter"]).convert("RGBA")
    corner_shade(cv, *v["shade"])
    if not clean:
        lg = v["logo"]
        lw, lh = kv.paste_with_shadow(cv, kv.logo(lg["w"]), (lg["x"], lg["y"]), radius=22,
                                      offset=(0, 16), opacity=0.6)
        if v["tagline"]:
            tp = kv.tagline_plate(TAGLINE, 84, pad=(54, 22))
            tp = tp.rotate(1, resample=Image.BICUBIC, expand=True)
            kv.paste_with_shadow(cv, tp, (lg["x"] + (lw - tp.width) // 2, lg["y"] + lh - 58),
                                 radius=14, offset=(0, 8), opacity=0.5)
    out = cv.convert("RGB")
    assert out.size == (CW, CH)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stills", required=True, help="folder holding the *_nohud.png capture stills")
    ap.add_argument("--variant", default="A", choices=sorted(VARIANTS))
    ap.add_argument("--out")
    ap.add_argument("--size", type=int, help="output width (1.26:1); default master 2520")
    ap.add_argument("--clean", action="store_true", help="omit logo and tagline")
    ap.add_argument("--final", action="store_true", help="write every deliverable")
    args = ap.parse_args()
    if args.final:
        final_variant = "A"
        master = render(args.stills, final_variant)
        kv.save(master, os.path.join(PROMO, "overlock_itch_cover_1260x1000.png"), (1260, 1000))
        kv.save(master, os.path.join(PROMO, "overlock_itch_cover_630x500.png"), (630, 500))
        alt_dir = os.path.join(PROMO, "keyvisual_alternatives")
        for name in sorted(VARIANTS):
            if name != final_variant:
                kv.save(render(args.stills, name),
                        os.path.join(alt_dir, f"overlock_itch_cover_alt_{name}_630x500.png"),
                        (630, 500))
        return
    im = render(args.stills, args.variant, args.clean)
    size = (args.size, round(args.size * CH / CW)) if args.size else None
    kv.save(im, args.out, size)


if __name__ == "__main__":
    main()
