"""Overlock promo: drawing primitives (skia) for the sewing-motif motion graphics.

Everything here is stateless: a function receives the canvas, the geometry and an
animation age (in frames) and draws one frame. Timing decisions live in render.py.
"""
import math
import os

import numpy as np
import skia

W, H = 1920, 1080
FPS = 60

# Shared colour tokens (same values as the key visual).
PALETTE = {
    "purple": (0x8D, 0x62, 0xB9),   # Thread Purple, main accent
    "plum": (0x2A, 0x18, 0x38),     # Deep Plum, dark background
    "cream": (0xF3, 0xE7, 0xC9),    # Fabric Cream, light fill / text
    "red": (0xE5, 0x36, 0x4B),      # Stitch Red, beat accent
    "yellow": (0xFF, 0xD4, 0x3B),   # Star Yellow, secondary accent
    "ink": (0x47, 0x34, 0x2A),      # Ink Brown, text on cream
}


def rgb(name):
    return PALETTE[name] if isinstance(name, str) else tuple(name)


def col(name, a=1.0):
    r, g, b = rgb(name)
    return skia.Color(r, g, b, max(0, min(255, int(round(a * 255)))))


def paint(color="cream", a=1.0, **kw):
    p = skia.Paint(AntiAlias=True, Color=col(color, a))
    for k, v in kw.items():
        setattr_map = {
            "stroke": lambda p, v: (p.setStyle(skia.Paint.kStroke_Style), p.setStrokeWidth(v)),
            "cap": lambda p, v: p.setStrokeCap(v),
            "join": lambda p, v: p.setStrokeJoin(v),
            "dash": lambda p, v: p.setPathEffect(skia.DashPathEffect.Make(v[0], v[1])),
            "blur": lambda p, v: p.setMaskFilter(skia.MaskFilter.MakeBlur(skia.kNormal_BlurStyle, v)),
            "shader": lambda p, v: p.setShader(v),
        }
        setattr_map[k](p, v)
    return p


# ---------------------------------------------------------------- easing

def clamp01(x):
    return 0.0 if x < 0 else 1.0 if x > 1 else x


def ease_out_cubic(p):
    p = clamp01(p)
    return 1 - (1 - p) ** 3


def ease_in_cubic(p):
    p = clamp01(p)
    return p * p * p


def ease_in_out(p):
    p = clamp01(p)
    return p * p * (3 - 2 * p)


def ease_out_back(p, c1=2.0):
    p = clamp01(p)
    c3 = c1 + 1
    return 1 + c3 * (p - 1) ** 3 + c1 * (p - 1) ** 2


def stamp(age, dur=10, s0=0.35):
    """Scale/alpha of a 'stamped' element: grows with overshoot, then settles at exactly 1.0."""
    if age < 0:
        return 0.0, 0.0
    if age >= dur:
        return 1.0, 1.0
    p = age / dur
    return s0 + (1 - s0) * ease_out_back(p), clamp01((age + 1) / 3)


def beat_pulse(age, amp=0.02, tau_frames=5.0):
    if age < 0:
        return 1.0
    return 1.0 + amp * math.exp(-age / tau_frames)


# ---------------------------------------------------------------- fonts

class Fonts:
    def __init__(self, font_dir):
        self.dir = font_dir
        self.tf = {}
        self.cache = {}

    def get(self, weight, size):
        key = (weight, size)
        if key not in self.cache:
            if weight not in self.tf:
                path = os.path.join(self.dir, "Pretendard-%s.otf" % weight)
                tf = skia.Typeface.MakeFromFile(path)
                if tf is None:
                    raise RuntimeError("font missing: " + path)
                self.tf[weight] = tf
            f = skia.Font(self.tf[weight], size)
            f.setEdging(skia.Font.Edging.kAntiAlias)
            f.setSubpixel(True)
            f.setHinting(skia.FontHinting.kNone)
            f.setLinearMetrics(True)
            self.cache[key] = f
        return self.cache[key]


def text_width(font, text):
    return font.measureText(text)


def check_glyphs(font, text):
    """Raise if any character would render as tofu."""
    gl = font.textToGlyphs(text)
    missing = [ch for ch, g in zip(text, gl) if g == 0 and not ch.isspace()]
    if missing:
        raise RuntimeError("missing glyphs %r in %r" % (missing, text))


def cap_box(size):
    """Visual box of a Hangul/Latin line relative to baseline (top, bottom) for Pretendard."""
    return -0.80 * size, 0.08 * size


def draw_text(canvas, font, text, x, y, color="cream", a=1.0, stroke=None, stroke_w=0.0, align="left"):
    w = font.measureText(text)
    if align == "center":
        x -= w / 2
    elif align == "right":
        x -= w
    if stroke is not None and stroke_w > 0:
        p = paint(stroke, a, stroke=stroke_w, join=skia.Paint.kRound_Join)
        canvas.drawString(text, x, y, font, p)
    canvas.drawString(text, x, y, font, paint(color, a))
    return w


def draw_segments(canvas, font, segs, x, y, a=1.0):
    """segs: list of (text, color). Left aligned at x, baseline y."""
    for text, color in segs:
        canvas.drawString(text, x, y, font, paint(color, a))
        x += font.measureText(text)


def split_accent(text, accents, base, accent):
    segs = [(text, base)]
    for acc in accents or []:
        out = []
        for t, c in segs:
            if c != base or acc not in t:
                out.append((t, c))
                continue
            i = t.index(acc)
            if t[:i]:
                out.append((t[:i], base))
            out.append((acc, accent))
            if t[i + len(acc):]:
                out.append((t[i + len(acc):], base))
        segs = out
    return segs


# ---------------------------------------------------------------- backgrounds

def make_plum_bg(seed=7):
    """Deep plum radial background with a faint twill weave and grain (prevents banding)."""
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    cx, cy = W * 0.5, H * 0.44
    d = np.sqrt(((xx - cx) / (W * 0.62)) ** 2 + ((yy - cy) / (H * 0.78)) ** 2)
    t = np.clip(d, 0, 1.25) / 1.25
    inner = np.array([0x3E, 0x25, 0x55], np.float32)
    outer = np.array([0x17, 0x0C, 0x20], np.float32)
    img = inner[None, None, :] * (1 - t[..., None] ** 1.3) + outer[None, None, :] * (t[..., None] ** 1.3)
    weave = np.sin((xx + yy) * (2 * math.pi / 7.0)) * np.sin((xx - yy) * (2 * math.pi / 23.0))
    img += weave[..., None] * 2.2
    rng = np.random.default_rng(seed)
    img += rng.normal(0, 1.4, size=(H, W, 1)).astype(np.float32)
    out = np.empty((H, W, 4), np.uint8)
    out[..., :3] = np.clip(img + 0.5, 0, 255).astype(np.uint8)
    out[..., 3] = 255
    return skia.Image.fromarray(out, colorType=skia.kRGBA_8888_ColorType)


def load_image(path, crop_alpha=True):
    from PIL import Image
    im = Image.open(path).convert("RGBA")
    if crop_alpha:
        bb = im.split()[3].getbbox()
        if bb:
            im = im.crop(bb)
    arr = np.array(im)
    # skia wants premultiplied for kPremul; supply unpremul and let skia convert
    return skia.Image.fromarray(arr, colorType=skia.kRGBA_8888_ColorType, alphaType=skia.kUnpremul_AlphaType)


# ---------------------------------------------------------------- sewing shapes

PATCH_STYLES = {
    "cream": {"fill": "cream", "stitch": "purple", "text": "ink", "accent": "red"},
    "purple": {"fill": "purple", "stitch": "cream", "text": "cream", "accent": "yellow"},
    "red": {"fill": "red", "stitch": "cream", "text": "cream", "accent": "yellow"},
}


def draw_patch(canvas, rect, style="cream", march=0.0, radius=None, shadow=True, a=1.0):
    """Fabric patch: rounded card with an inset dashed stitch border."""
    st = PATCH_STYLES[style]
    h = rect.height()
    r = radius if radius is not None else min(26.0, h * 0.3)
    rr = skia.RRect.MakeRectXY(rect, r, r)
    if shadow:
        sh = skia.RRect.MakeRectXY(rect.makeOffset(0, 7), r, r)
        canvas.drawRRect(sh, paint((10, 4, 14), 0.45 * a, blur=9.0))
    fr, fg, fb = rgb(st["fill"])
    top = skia.Color(min(255, fr + 10), min(255, fg + 10), min(255, fb + 10), int(255 * a))
    bot = skia.Color(max(0, fr - 12), max(0, fg - 12), max(0, fb - 12), int(255 * a))
    sh = skia.GradientShader.MakeLinear([skia.Point(0, rect.top()), skia.Point(0, rect.bottom())], [top, bot])
    canvas.drawRRect(rr, paint(st["fill"], a, shader=sh))
    inset = max(7.0, min(11.0, h * 0.09))
    ir = rect.makeInset(inset, inset)
    irr = skia.RRect.MakeRectXY(ir, max(2.0, r - inset * 0.8), max(2.0, r - inset * 0.8))
    dash = [15.0, 9.0]
    canvas.drawRRect(irr, paint(st["stitch"], 0.95 * a, stroke=3.2, cap=skia.Paint.kRound_Cap,
                                dash=(dash, -march * sum(dash))))
    return st


def keycap(canvas, cx, cy, w, h, label, fonts, pressed=0.0, a=1.0):
    depth = 11.0
    off = depth * pressed
    base = skia.Rect.MakeXYWH(cx - w / 2, cy - h / 2 + depth, w, h)
    canvas.drawRRect(skia.RRect.MakeRectXY(base.makeOffset(0, 5), 18, 18), paint((10, 4, 14), 0.4 * a, blur=8.0))
    canvas.drawRRect(skia.RRect.MakeRectXY(base, 18, 18), paint((0x5A, 0x3E, 0x7C), a))
    face = skia.Rect.MakeXYWH(cx - w / 2, cy - h / 2 + off, w, h)
    fill = "cream" if pressed < 0.5 else (0xE4, 0xD3, 0xF5)
    canvas.drawRRect(skia.RRect.MakeRectXY(face, 18, 18), paint(fill, a))
    canvas.drawRRect(skia.RRect.MakeRectXY(face.makeInset(7, 7), 12, 12),
                     paint("purple", 0.9 * a, stroke=3.0, dash=([12.0, 8.0], 0)))
    ccx, ccy = cx, cy + off
    if label in ("<", ">"):
        s = h * 0.22
        d = -1 if label == "<" else 1
        path = skia.Path()
        path.moveTo(ccx + d * s * 1.0, ccy)
        path.lineTo(ccx - d * s * 0.75, ccy - s * 1.1)
        path.lineTo(ccx - d * s * 0.75, ccy + s * 1.1)
        path.close()
        canvas.drawPath(path, paint("ink", a))
    else:
        size = h * (0.46 if len(label) == 1 else 0.33)
        f = fonts.get("ExtraBold", round(size))
        draw_text(canvas, f, label, ccx, ccy + size * 0.36, "ink", a, align="center")


def needle(canvas, x, tip_y, length=1250.0, width=44.0, thread=True, a=1.0):
    """Big sewing needle pointing down with its tip at (x, tip_y)."""
    top = tip_y - length
    hw = width / 2
    taper = width * 4.5
    p = skia.Path()
    p.moveTo(x, tip_y)
    p.cubicTo(x + hw * 0.35, tip_y - taper * 0.35, x + hw, tip_y - taper * 0.7, x + hw, tip_y - taper)
    p.lineTo(x + hw, top + hw)
    p.arcTo(skia.Rect(x - hw, top, x + hw, top + width), 0, -180, False)
    p.lineTo(x - hw, tip_y - taper)
    p.cubicTo(x - hw, tip_y - taper * 0.7, x - hw * 0.35, tip_y - taper * 0.35, x, tip_y)
    p.close()
    eye = skia.RRect.MakeRectXY(skia.Rect(x - hw * 0.32, top + width * 0.9, x + hw * 0.32, top + width * 4.2),
                                hw * 0.32, hw * 0.32)
    ep = skia.Path()
    ep.addRRect(eye)
    p.addPath(ep)
    p.setFillType(skia.PathFillType.kEvenOdd)
    colors = [skia.Color(0x55, 0x58, 0x62, int(255 * a)), skia.Color(0xC4, 0xC8, 0xD2, int(255 * a)),
              skia.Color(0xFF, 0xFF, 0xFF, int(255 * a)), skia.Color(0xA9, 0xAD, 0xB8, int(255 * a)),
              skia.Color(0x5E, 0x61, 0x6B, int(255 * a))]
    sh = skia.GradientShader.MakeLinear([skia.Point(x - hw, 0), skia.Point(x + hw, 0)], colors,
                                        [0.0, 0.3, 0.45, 0.72, 1.0])
    canvas.drawPath(p, paint((0, 0, 0), 0.35 * a, blur=10.0))
    canvas.drawPath(p, paint("cream", a, shader=sh))
    canvas.drawPath(p, paint((0x2E, 0x2F, 0x36), 0.9 * a, stroke=2.2))
    if thread:
        ey = top + width * 2.6
        t = skia.Path()
        t.moveTo(x - hw * 0.2, ey)
        t.cubicTo(x - width * 2.2, ey - 160, x + width * 2.0, ey - 320, x - width * 0.6, ey - 700)
        canvas.drawPath(t, paint("purple", a, stroke=width * 0.2, cap=skia.Paint.kRound_Cap))
        t2 = skia.Path()
        t2.moveTo(x + hw * 0.2, ey)
        t2.cubicTo(x + width * 1.3, ey + 60, x + width * 1.9, ey + 190, x + width * 1.1, ey + 330)
        canvas.drawPath(t2, paint("purple", a, stroke=width * 0.2, cap=skia.Paint.kRound_Cap))


def dashed_ring(canvas, cx, cy, r, color, a, width=6.0, rot=0.0):
    circ = 2 * math.pi * r
    n = max(8, int(circ / 38))
    seg = circ / n
    p = paint(color, a, stroke=width, cap=skia.Paint.kRound_Cap, dash=([seg * 0.6, seg * 0.4], rot * seg))
    canvas.drawCircle(cx, cy, r, p)


def star_path(cx, cy, r_out, r_in, rot=0.0):
    p = skia.Path()
    for i in range(10):
        ang = rot - math.pi / 2 + i * math.pi / 5
        r = r_out if i % 2 == 0 else r_in
        x, y = cx + r * math.cos(ang), cy + r * math.sin(ang)
        if i == 0:
            p.moveTo(x, y)
        else:
            p.lineTo(x, y)
    p.close()
    return p


def polyline_path(pts):
    p = skia.Path()
    p.moveTo(*pts[0])
    for q in pts[1:]:
        p.lineTo(*q)
    return p


class StitchCurve:
    """Parametric curve u in [0,1] used for running-stitch lines."""

    def __init__(self, kind, **kw):
        self.kind = kind
        self.kw = kw
        if kind == "wave":
            self.x0, self.x1 = kw.get("x0", 96.0), kw.get("x1", 1824.0)
            self.y0, self.amp = kw.get("y", 600.0), kw.get("amp", 26.0)
        elif kind == "rect":
            ins = kw.get("inset", 44.0)
            self.rect = (ins, ins, W - ins, H - ins)
            x0, y0, x1, y1 = self.rect
            self.perim = 2 * ((x1 - x0) + (y1 - y0))

    def point(self, u):
        if self.kind == "wave":
            x = self.x0 + (self.x1 - self.x0) * u
            return x, self.y0 + self.amp * math.sin(u * 2 * math.pi * 1.5)
        if self.kind == "ellipse":
            ang = -math.pi / 2 + u * 2 * math.pi
            return self.kw["cx"] + self.kw["rx"] * math.cos(ang), self.kw["cy"] + self.kw["ry"] * math.sin(ang)
        if self.kind == "rect":
            x0, y0, x1, y1 = self.rect
            wdt, hgt = x1 - x0, y1 - y0
            d = (u * self.perim + wdt / 2) % self.perim  # start at top centre, clockwise
            if d < wdt:
                return x0 + d, y0
            d -= wdt
            if d < hgt:
                return x1, y0 + d
            d -= hgt
            if d < wdt:
                return x1 - d, y1
            d -= wdt
            return x0, y1 - d
        raise ValueError(self.kind)

    def segment(self, u0, u1, n=10):
        return [self.point(u0 + (u1 - u0) * i / n) for i in range(n + 1)]
