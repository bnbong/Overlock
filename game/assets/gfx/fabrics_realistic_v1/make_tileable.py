#!/usr/bin/env python3
"""Make the realistic fabric candidates tile seamlessly for runtime use.

Source: game/assets/gfx/fabrics_realistic_v1/fabric_<id>.png (1254x1254, untouched).
Output: game/assets/gfx/fabrics/fabric_<id>.png (1024x1024, RGB).

Method (edge crossfade, square):
  1. Pick a band width b (64..220 px) where the first b columns/rows best match the
     columns/rows that follow the crop size M = N - b (min mean abs diff). A matching
     phase keeps the woven pattern aligned so the blend band does not ghost.
  2. Crop to M x M and blend the leftover b-px strip from the far edge into the near
     edge with a smoothstep ramp (x then y). The result wraps continuously.
  3. Resize to 1024 with Lanczos on a 3x3 tiled copy (wrap-aware), crop the center.

Prints the sRGB mean color of each output (FabricSurface.FABRIC_BASE values).
Requires Pillow and numpy. Run from anywhere: python3 make_tileable.py
"""

import os

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(os.path.dirname(HERE), "fabrics")
IDS = ["cotton", "denim", "silk", "knit", "felt", "satin", "wool", "leather"]
OUT_SIZE = 1024
B_MIN, B_MAX = 64, 220


def band_error(img, b):
    n = img.shape[0]
    m = n - b
    ex = np.abs(img[:, :b] - img[:, m:n]).mean()
    ey = np.abs(img[:b, :] - img[m:n, :]).mean()
    return ex + ey


def pick_band(img):
    best_b, best_e = B_MIN, None
    for b in range(B_MIN, B_MAX + 1):
        e = band_error(img, b)
        if best_e is None or e < best_e:
            best_b, best_e = b, e
    return best_b, best_e


def crossfade(img, b):
    n = img.shape[0]
    m = n - b
    t = np.linspace(0.0, 1.0, b, endpoint=False)
    w = t * t * (3.0 - 2.0 * t)  # smoothstep: 0 -> far-edge content, 1 -> near-edge content
    # x axis
    out = img[:, :m].copy()
    out[:, :b] = img[:, m:n] * (1.0 - w)[None, :, None] + img[:, :b] * w[None, :, None]
    # y axis (operate on the x-blended image, which still has n rows)
    full = out
    out = full[:m, :].copy()
    out[:b, :] = full[m:n, :] * (1.0 - w)[:, None, None] + full[:b, :] * w[:, None, None]
    return out


def wrap_resize(arr, size):
    im = Image.fromarray(np.clip(arr * 255.0 + 0.5, 0, 255).astype(np.uint8), "RGB")
    m = im.width
    big = Image.new("RGB", (m * 3, m * 3))
    for i in range(3):
        for j in range(3):
            big.paste(im, (i * m, j * m))
    big = big.resize((size * 3, size * 3), Image.LANCZOS)
    return big.crop((size, size, size * 2, size * 2))


def seam_ratio(arr):
    """Mean abs diff across the wrap edge divided by the mean neighbor diff inside."""
    a = arr.astype(float) / 255.0
    edge = (np.abs(a[:, 0] - a[:, -1]).mean() + np.abs(a[0] - a[-1]).mean()) / 2.0
    inner = (np.abs(a[:, 1:] - a[:, :-1]).mean() + np.abs(a[1:] - a[:-1]).mean()) / 2.0
    return edge / max(inner, 1e-6)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    for fid in IDS:
        src = os.path.join(HERE, "fabric_%s.png" % fid)
        img = np.asarray(Image.open(src).convert("RGB")).astype(np.float64) / 255.0
        before = seam_ratio((img * 255).astype(np.uint8))
        b, e = pick_band(img)
        tiled = crossfade(img, b)
        out = wrap_resize(tiled, OUT_SIZE)
        out.save(os.path.join(OUT_DIR, "fabric_%s.png" % fid), optimize=True)
        arr = np.asarray(out)
        mean = arr.reshape(-1, 3).astype(float).mean(0) / 255.0
        print(
            "%-8s band=%3dpx crop=%4d err=%.4f seam_ratio %.2f -> %.2f  mean=Color(%.3f, %.3f, %.3f)"
            % (fid, b, img.shape[0] - b, e, before, seam_ratio(arr), mean[0], mean[1], mean[2])
        )


if __name__ == "__main__":
    main()
