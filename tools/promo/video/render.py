#!/usr/bin/env python3
"""Overlock promo compositor.

Reads tools/promo/video/timeline.json (all times in music beats), derives seconds and
frames from docs/promo/video/music/beatmap.json, composites the gameplay footage and the
sewing-motif motion graphics with skia, and streams RGBA frames into ffmpeg (one H.264
encode, no intermediate generation loss).

usage:
  render.py --out video.mp4 [--crf 16] [--debug-beats] [--range A:B]
  render.py --stills DIR --at 0,120,522      (random access, PNG per output frame)
  render.py --export-timeline PATH           (resolved timeline with seconds/frames)
"""
import argparse
import json
import math
import os
import subprocess
import sys
import time

import numpy as np
import skia

import motion as M
from motion import W, H, FPS

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
# Footage clips are not committed (see docs/promo/video/README.md). PROMO_FOOTAGE points at the
# encode_clips.py output directory; the default is the historical in-repo location.
FOOT = os.environ.get("PROMO_FOOTAGE") or os.path.join(ROOT, "docs", "promo", "video", "footage")
FONT_DIR = os.path.join(ROOT, "tools", "promo", "fonts")
FFMPEG = "/opt/homebrew/bin/ffmpeg"
FRAME_BYTES = W * H * 4

# Footage clips are BT.709 limited-range yuv420p. Decode to full-range RGB with the right matrix.
DECODE_VF = "scale=in_color_matrix=bt709:in_range=tv:flags=accurate_rnd+full_chroma_int+bicubic,format=rgba"


# ---------------------------------------------------------------- beat grid

class Grid:
    def __init__(self, beatmap_path, first_beat, length_beats):
        bm = json.load(open(beatmap_path))
        b = np.array(bm["beats_sec"], dtype=np.float64)
        k = np.arange(len(b))
        self.period, self.offset = np.polyfit(k, b, 1)
        self.residual_ms = float(np.abs(b - (self.offset + k * self.period)).max() * 1000)
        self.first = first_beat
        self.song_start = self.offset + first_beat * self.period  # seconds into the mp3
        self.length = length_beats
        self.nframes = self.frame(length_beats)

    def sec(self, beat):
        return beat * self.period

    def frame(self, beat):
        return int(round(beat * self.period * FPS))

    def beat_of_frame(self, f):
        return f / FPS / self.period

    def last_beat_at(self, f, step=1.0):
        """Largest multiple of step whose frame is <= f."""
        k = math.floor(self.beat_of_frame(f) / step + 1e-9)
        while self.frame((k + 1) * step) <= f:
            k += 1
        while k > 0 and self.frame(k * step) > f:
            k -= 1
        return k * step


# ---------------------------------------------------------------- footage

_NFRAMES = {}


def clip_frames(name):
    if name not in _NFRAMES:
        meta = json.load(open(os.path.join(FOOT, "footage.json")))
        for c in meta["clips"]:
            _NFRAMES[c["file"][:-4]] = c["frames"]
    return _NFRAMES[name]


class ClipReader:
    """Sequential RGBA reader starting at an exact frame index (select by decoded frame number)."""

    def __init__(self, name, start):
        self.name = name
        self.n = clip_frames(name)
        start = max(0, min(self.n - 1, start))
        path = os.path.join(FOOT, name + ".mp4")
        cmd = [FFMPEG, "-v", "fatal", "-nostdin", "-i", path,
               "-vf", "select=gte(n\\,%d),%s" % (start, DECODE_VF),
               "-fps_mode", "passthrough", "-f", "rawvideo", "-"]
        self.p = subprocess.Popen(cmd, stdout=subprocess.PIPE, bufsize=FRAME_BYTES * 2)
        self.idx = start - 1
        self.cur = None
        self.start = start

    def get(self, n):
        n = max(self.start, min(self.n - 1, n))
        if n < self.idx:
            raise RuntimeError("non-monotonic read %s %d<%d" % (self.name, n, self.idx))
        while self.idx < n:
            buf = self.p.stdout.read(FRAME_BYTES)
            if len(buf) < FRAME_BYTES:
                break
            self.cur = np.frombuffer(buf, np.uint8).reshape(H, W, 4)
            self.idx += 1
        if self.cur is None:
            raise RuntimeError("no frames from %s" % self.name)
        return self.cur

    def close(self):
        try:
            self.p.stdout.close()
        except Exception:
            pass
        self.p.kill()
        self.p.wait()


def map_src_frame(grid, keys, f):
    """keys: [[beat, src_sec], ...]. Piecewise-linear retime with integer (non-blended) frames.
    Before the first key and after the last key the clip runs at 1x."""
    ks = [(grid.frame(b), int(round(s * FPS))) for b, s in keys]
    if f < ks[0][0]:
        return ks[0][1] - (ks[0][0] - f)
    for (f0, s0), (f1, s1) in zip(ks, ks[1:]):
        if f0 <= f < f1:
            return s0 + ((f - f0) * (s1 - s0)) // (f1 - f0)
    fl, sl = ks[-1]
    return sl + (f - fl)


# ---------------------------------------------------------------- compositor

class Compositor:
    def __init__(self, timeline, debug_beats=False):
        self.tl = timeline
        mus = timeline["music"]
        self.grid = Grid(os.path.join(ROOT, mus["beatmap"]), mus["first_beat_index"], mus["length_beats"])
        self.fonts = M.Fonts(FONT_DIR)
        self.debug = debug_beats
        self.info = skia.ImageInfo.Make(W, H, skia.kRGBA_8888_ColorType, skia.kPremul_AlphaType)
        self.surface = skia.Surface.MakeRaster(self.info)
        self.bg = M.make_plum_bg()
        self.logo = M.load_image(os.path.join(ROOT, "game", "assets", "gfx", "overlock_logo.png"))
        self.icons = {}
        self.cubic = skia.SamplingOptions(skia.CubicResampler.Mitchell())
        self.mip = skia.SamplingOptions(skia.FilterMode.kLinear, skia.MipmapMode.kLinear)
        self.readers = {}
        g = self.grid
        self.shots = timeline["shots"]
        for s in self.shots:
            s["f0"], s["f1"] = g.frame(s["start"]), g.frame(s["end"])
        self.cut_frames = sorted({s["f0"] for s in self.shots})
        self.ovs = timeline["overlays"]
        for o in self.ovs:
            if "at" in o and "start" not in o:
                o["f_at"] = g.frame(o["at"])
            if "start" in o:
                o["f0"], o["f1"] = g.frame(o["start"]), g.frame(o["end"])
            if "at" in o:
                o["f_at"] = g.frame(o["at"])
        self.warn = set()
        self._check_text()
        self._check_safe()

    # -- validation
    def _check_text(self):
        for o in self.ovs:
            texts = []
            if o["type"] in ("text", "stamp", "chip", "url"):
                texts.append(o["text"])
            if o["type"] == "caption":
                texts += [ln["text"] for ln in o["lines"]]
            if o["type"] == "words":
                texts += [w[0] for w in o["words"]]
            if o["type"] == "attribution":
                texts += o["lines"]
            for t in texts:
                M.check_glyphs(self.fonts.get("Black", 40), t)

    def _check_safe(self):
        """Every text element must stay inside the 5% title-safe area once it has settled."""
        sx0, sy0, sx1, sy1 = W * 0.05, H * 0.05, W * 0.95, H * 0.95
        boxes = []
        for o in self.ovs:
            t = o["type"]
            if t == "caption":
                items, icon_sz = self.caption_layout(o)
                for ln, font, rect, tx, ty in items:
                    boxes.append((ln["text"], rect.left() - (icon_sz * 0.8 if icon_sz else 0), rect.top(), rect.right(), rect.bottom()))
            elif t in ("text", "attribution", "words"):
                lines = o["lines"] if t == "attribution" else [o["text"]] if t == "text" else [" ".join(w[0] for w in o["words"])]
                size = o["size"]
                font = self.fonts.get(o.get("weight", "Black" if t == "words" else "Medium"), size)
                y = o.get("y")
                for ln in lines:
                    tw = font.measureText(ln) + (size * 0.8 if t == "words" else 0)
                    x0 = o.get("x", W / 2) - tw / 2 if o.get("align", "center") == "center" or t != "text" else o["x"]
                    boxes.append((ln, x0, y - size * 0.8, x0 + tw, y + size * 0.2))
                    y += size * 1.34
            elif t in ("stamp", "chip", "url"):
                size = o.get("size", 38)
                font = self.fonts.get("Black", size)
                tw = font.measureText(o["text"]) + (size if t != "stamp" else 0)
                boxes.append((o["text"], o["cx"] - tw / 2, o["cy"] - size * 0.6, o["cx"] + tw / 2, o["cy"] + size * 0.6))
        for label, x0, y0, x1, y1 in boxes:
            if x0 < sx0 or y0 < sy0 or x1 > sx1 or y1 > sy1:
                msg = "SAFE-AREA: %r box (%.0f,%.0f)-(%.0f,%.0f)" % (label, x0, y0, x1, y1)
                self.warn.add(msg)
                print(msg, file=sys.stderr)

    # -- helpers
    def shot_at(self, f):
        for s in self.shots:
            if s["f0"] <= f < s["f1"]:
                return s
        return self.shots[-1]

    def reader(self, key, clip, src):
        r = self.readers.get(key)
        if r is None or r.name != clip or src < r.idx:
            if r is not None:
                r.close()
            r = ClipReader(clip, src)
            self.readers[key] = r
        return r

    def drop_readers(self, keep):
        for k in list(self.readers):
            if k not in keep:
                self.readers[k].close()
                del self.readers[k]

    def icon(self, rel):
        if rel not in self.icons:
            self.icons[rel] = M.load_image(os.path.join(ROOT, rel))
        return self.icons[rel]

    def zoom(self, shot, f):
        z = shot.get("zoom")
        if not z:
            return (960.0, 540.0), 1.0
        g = self.grid
        keys = [(g.frame(b), s) for b, s in z["keys"]]
        mode = z.get("mode", "step")
        val = keys[0][1]
        if mode == "step":
            for fk, sk in keys:
                if fk <= f:
                    age = f - fk
                    val = sk if age >= 6 else val + (sk - val) * M.ease_out_cubic(age / 6)
        else:
            if f <= keys[0][0]:
                val = keys[0][1]
            elif f >= keys[-1][0]:
                val = keys[-1][1]
            else:
                for (f0, s0), (f1, s1) in zip(keys, keys[1:]):
                    if f0 <= f < f1:
                        val = s0 + (s1 - s0) * (f - f0) / (f1 - f0)
        return tuple(z["center"]), val

    def punch(self, shot, f):
        pd = dict(self.tl["punch"])
        pd.update(shot.get("punch", {}))
        k = self.grid.last_beat_at(f)
        if k < shot["start"] - 1e-9:
            return 0.0
        age = (f - self.grid.frame(k)) / FPS
        amp = pd["down"] if int(round(k)) % 4 == 0 else pd["beat"]
        return amp * math.exp(-age / pd["tau"])

    def beat_age(self, f, since_f=None):
        """Frames since the most recent beat (and since since_f if later)."""
        k = self.grid.last_beat_at(f)
        return f - self.grid.frame(k), k

    def draw_frame_image(self, c, arr, center, scale, crop=None, dst=None, sampling=None):
        img = skia.Image.fromarray(arr, colorType=skia.kRGBA_8888_ColorType)
        if crop is not None:
            c.drawImageRect(img, skia.Rect.MakeXYWH(*crop), dst, sampling or self.mip)
            return
        if abs(scale - 1.0) < 1e-6:
            c.drawImage(img, 0, 0)
            return
        cx, cy = center
        w, h = W / scale, H / scale
        x0 = min(max(cx - cx / scale, 0.0), W - w)
        y0 = min(max(cy - cy / scale, 0.0), H - h)
        c.drawImageRect(img, skia.Rect.MakeXYWH(x0, y0, w, h), skia.Rect(0, 0, W, H), self.cubic)

    # -- one frame
    def render(self, f, random_access=False):
        c = self.surface.getCanvas()
        c.clear(M.col("plum"))
        shot = self.shot_at(f)
        if "clip" in shot:
            src = map_src_frame(self.grid, shot["map"], f)
            key = "shot:" + shot["id"]
            if random_access:
                r = ClipReader(shot["clip"], src)
                arr = r.get(src)
                r.close()
            else:
                arr = self.reader(key, shot["clip"], src).get(src)
            center, z = self.zoom(shot, f)
            s = z * (1.0 + self.punch(shot, f))
            self.draw_frame_image(c, arr, center, s)
            if shot.get("mask_bottom"):
                self.mask_bottom(c, arr)
        else:
            c.drawImage(self.bg, 0, 0)
        for o in self.ovs:
            fn = getattr(self, "ov_" + o["type"])
            if "f0" in o and not (o["f0"] <= f < o["f1"]):
                continue
            fn(c, o, f, random_access)
        if self.debug:
            self.debug_marker(c, f)
        return c

    def read(self, out):
        self.surface.readPixels(self.info, out, W * 4, 0, 0)

    # ------------------------------------------------------------ overlays

    def exit_alpha(self, o, f, n=6):
        """Captions that end away from a cut fade out over n frames; at a cut they end hard."""
        if o["f1"] in self.cut_frames:
            return 1.0
        return M.clamp01((o["f1"] - f) / n)

    def mask_bottom(self, c, arr):
        colr = arr[1052:1078, 200:1720, :3].reshape(-1, 3).mean(axis=0)
        r, g, b = (int(round(v)) for v in colr)
        sh = skia.GradientShader.MakeLinear([skia.Point(0, 997), skia.Point(0, 1011)],
                                            [skia.Color(r, g, b, 0), skia.Color(r, g, b, 255)])
        c.drawRect(skia.Rect(0, 990, W, H), M.paint("plum", shader=sh))

    def ov_stitch_path(self, c, o, f, ra):
        kind = o["path"]
        if kind == "wave":
            curve = M.StitchCurve("wave", y=o.get("y", 600.0))
        elif kind == "ellipse":
            curve = M.StitchCurve("ellipse", cx=o["cx"], cy=o["cy"], rx=o["rx"], ry=o["ry"])
        else:
            curve = M.StitchCurve("rect", inset=o.get("inset", 44))
        n, every = o["count"], o["every"]
        a = o.get("alpha", 1.0) * self.exit_alpha(o, f)
        gap = 0.16
        width = 9.0 if kind == "wave" else 5.0
        if o.get("guide"):
            pts = curve.segment(0, 1, 160)
            c.drawPath(M.polyline_path(pts), M.paint("cream", 0.16, stroke=2.0, dash=([10.0, 10.0], 0)))
        head = None
        for i in range(n):
            born = self.grid.frame(o["start"] + i * every)
            nxt = self.grid.frame(o["start"] + (i + 1) * every)
            if f < born:
                break
            phase = M.clamp01((f - born + 1) / max(1, nxt - born))
            u0 = (i + gap / 2) / n
            u1 = (i + 1 - gap / 2) / n
            ue = u0 + (u1 - u0) * phase
            pts = curve.segment(u0, ue, 8)
            if kind == "wave":
                c.drawPath(M.polyline_path([(x + 1.5, y + 3) for x, y in pts]),
                           M.paint((0x12, 0x06, 0x0E), 0.55 * a, stroke=width, cap=skia.Paint.kRound_Cap))
            c.drawPath(M.polyline_path(pts), M.paint(o["color"], a, stroke=width, cap=skia.Paint.kRound_Cap))
            head = (curve.point(ue), phase)
        if o.get("needle") and head is not None:
            (hx, hy), phase = head
            lift = 70.0 * math.sin(math.pi * phase)
            M.needle(c, hx, hy - lift + 4, length=420, width=20, a=a)

    def ov_words(self, c, o, f, ra):
        font = self.fonts.get("Black", o["size"])
        widths = []
        for w in o["words"]:
            tw = font.measureText(w[0])
            if len(w) > 2 and w[2] == "tag":
                tw += o["size"] * 0.5
            widths.append(tw)
        total = sum(widths) + o["gap"] * (len(widths) - 1)
        x = W / 2 - total / 2
        y = o["y"]
        top, bot = M.cap_box(o["size"])
        for w, tw in zip(o["words"], widths):
            age = f - self.grid.frame(w[1])
            if age >= 0:
                s, a = M.stamp(age, 10, 0.4)
                pk = self.grid.last_beat_at(f)
                s *= M.beat_pulse(f - self.grid.frame(pk), 0.018) if age >= 10 else 1.0
                cx, cy = x + tw / 2, y + (top + bot) / 2
                c.save()
                c.translate(cx, cy)
                c.scale(s, s)
                c.translate(-cx, -cy)
                if len(w) > 2 and w[2] == "tag":
                    pad = o["size"] * 0.25
                    rect = skia.Rect(x, y + top - pad * 0.9, x + tw, y + bot + pad * 0.9)
                    c.rotate(-2.5, cx, cy)
                    M.draw_patch(c, rect, "red", a=a)
                    M.draw_text(c, font, w[0], x + pad, y, "cream", a)
                else:
                    c.drawString(w[0], x + 3, y + 5, font, M.paint((8, 2, 10), 0.5 * a))
                    M.draw_text(c, font, w[0], x, y, "cream", a)
                c.restore()
            x += tw + o["gap"]

    def ov_glow(self, c, o, f, ra):
        age = f - o["f0"]
        a = M.ease_out_cubic(age / 20)
        sh = skia.GradientShader.MakeRadial(skia.Point(o["cx"], o["cy"]), o["r"],
                                            [M.col("purple", 0.42 * a), M.col("purple", 0.12 * a), M.col("purple", 0.0)],
                                            [0.0, 0.55, 1.0])
        c.drawRect(skia.Rect(0, 0, W, H), M.paint("purple", shader=sh))

    def ov_logo(self, c, o, f, ra):
        age = f - o["f0"]
        s, a = M.stamp(age, 13, 0.5)
        rot = -7.0 * (1 - M.ease_out_cubic(age / 13))
        if age >= 13:
            k = self.grid.last_beat_at(f)
            amp = 0.022 if int(round(k)) % 4 == 0 else 0.01
            s *= M.beat_pulse(f - self.grid.frame(k), amp, 6.0)
        img = self.logo
        base = o["width"] / img.width()
        w, h = img.width() * base, img.height() * base
        c.save()
        c.translate(o["cx"], o["cy"])
        c.rotate(rot)
        c.scale(s, s)
        dst = skia.Rect(-w / 2, -h / 2, w / 2, h / 2)
        shadow = skia.Paint(AntiAlias=True, ImageFilter=skia.ImageFilters.DropShadowOnly(0, 14, 18, 18, M.col((6, 0, 10), 0.6)))
        shadow.setAlphaf(a)
        c.drawImageRect(img, dst, self.mip, shadow)
        p = skia.Paint(AntiAlias=True)
        p.setAlphaf(a)
        c.drawImageRect(img, dst, self.mip, p)
        c.restore()

    def ov_text(self, c, o, f, ra):
        age = f - o["f0"]
        font = self.fonts.get(o.get("weight", "Bold"), o["size"])
        a0 = o.get("alpha", 1.0) * self.exit_alpha(o, f)
        x, y = o["x"], o["y"]
        tw = font.measureText(o["text"])
        left = x - tw / 2 if o.get("align") == "center" else x
        top, bot = M.cap_box(o["size"])
        if o["size"] >= 100:
            s, a = M.stamp(age, 10, 0.45)
            cx, cy = left + tw / 2, y + (top + bot) / 2
            c.save()
            c.translate(cx, cy)
            c.scale(s, s)
            c.translate(-cx, -cy)
            c.drawString(o["text"], left + 4, y + 6, font, M.paint((8, 2, 10), 0.5 * a * a0))
            M.draw_text(c, font, o["text"], left, y, o.get("color", "cream"), a * a0)
            c.restore()
        else:
            p = M.ease_out_cubic(age / 9)
            dy = round(26 * (1 - p)) if p < 1 else 0
            a = M.clamp01((age + 1) / 7)
            c.drawString(o["text"], left + 2, y + dy + 4, font, M.paint((8, 2, 10), 0.45 * a * a0))
            M.draw_text(c, font, o["text"], left, y + dy, o.get("color", "cream"), a * a0)
        ul = o.get("underline")
        if ul:
            n = ul["count"]
            seg = tw / n
            uy = y + o["size"] * 0.2
            for i in range(n):
                born = self.grid.frame(o["start"] + i * ul["every"])
                nxt = self.grid.frame(o["start"] + (i + 1) * ul["every"])
                if f < born:
                    break
                ph = M.clamp01((f - born + 1) / max(1, nxt - born))
                x0 = left + i * seg + seg * 0.12
                x1 = x0 + seg * 0.76 * ph
                c.drawLine(x0, uy, x1, uy, M.paint(ul["color"], a0, stroke=10.0, cap=skia.Paint.kRound_Cap))

    def ov_card_clip(self, c, o, f, ra):
        age = f - o["f_at"]
        if age < 0:
            return
        src = map_src_frame(self.grid, o["map"], f)
        if ra:
            r = ClipReader(o["clip"], src)
            arr = r.get(src)
            r.close()
        else:
            arr = self.reader("card:" + o["id"], o["clip"], src).get(src)
        p = M.ease_out_back(age / 14, 1.4)
        a = M.clamp01((age + 1) / 5)
        dx = 460 * (1 - p)
        s = 0.86 + 0.14 * p
        w = o["w"]
        h = w * 9 / 16
        c.save()
        c.translate(o["cx"] + dx, o["cy"])
        c.rotate(o["rot"] + 6 * (1 - p))
        c.scale(s, s)
        border = 16.0
        outer = skia.Rect(-w / 2 - border, -h / 2 - border, w / 2 + border, h / 2 + border)
        orr = skia.RRect.MakeRectXY(outer, 30, 30)
        c.drawRRect(skia.RRect.MakeRectXY(outer.makeOffset(0, 16), 30, 30), M.paint((6, 0, 10), 0.55 * a, blur=22.0))
        c.drawRRect(orr, M.paint("cream", a))
        inner = skia.Rect(-w / 2, -h / 2, w / 2, h / 2)
        irr = skia.RRect.MakeRectXY(inner, 18, 18)
        c.save()
        c.clipRRect(irr, doAntiAlias=True)
        img = skia.Image.fromarray(arr, colorType=skia.kRGBA_8888_ColorType)
        pp = skia.Paint(AntiAlias=True)
        pp.setAlphaf(a)
        c.drawImageRect(img, skia.Rect.MakeXYWH(*o["crop"]), inner, self.mip, pp)
        if "dim_at" in o:
            dage = f - self.grid.frame(o["dim_at"])
            if dage >= 0:
                c.drawRect(inner, M.paint("plum", 0.5 * M.ease_out_cubic(dage / 10)))
        c.restore()
        c.drawRRect(skia.RRect.MakeRectXY(outer.makeInset(7, 7), 24, 24),
                    M.paint("purple", a, stroke=3.4, cap=skia.Paint.kRound_Cap, dash=([16.0, 10.0], 0)))
        c.restore()

    def ov_vignette(self, c, o, f, ra):
        p = (f - o["f0"]) / max(1, o["f1"] - o["f0"])
        a = o["from"] + (o["to"] - o["from"]) * p
        sh = skia.GradientShader.MakeRadial(skia.Point(W / 2, H * 0.45), W * 0.62,
                                            [M.col("plum", 0.0), M.col("plum", 0.0), M.col("plum", a)],
                                            [0.0, 0.55, 1.0])
        c.drawRect(skia.Rect(0, 0, W, H), M.paint("plum", shader=sh))

    def ov_ring(self, c, o, f, ra):
        age = f - o["f_at"]
        dur = 18
        if age < 0 or age >= dur:
            return
        p = M.ease_out_cubic(age / dur)
        r = o["r0"] + (o["r1"] - o["r0"]) * p
        M.dashed_ring(c, o["cx"], o["cy"], r, o["color"], (1 - p) * 0.9, width=7.0 * (1 - 0.5 * p), rot=p * 0.6)

    def ov_flash(self, c, o, f, ra):
        age = f - o["f_at"]
        if age < 0 or age >= o["frames"]:
            return
        a = o["alpha"] * (1 - age / o["frames"]) ** 2
        c.drawRect(skia.Rect(0, 0, W, H), M.paint(o["color"], a))

    def ov_burst(self, c, o, f, ra):
        age = f - o["f_at"]
        dur = 18
        if age < 0 or age >= dur:
            return
        p = M.ease_out_cubic(age / dur)
        n = 18
        for i in range(n):
            ang = i * 2 * math.pi / n + 0.1
            r0 = 90 + 520 * p
            r1 = r0 + 70 * (1 - p) + 20
            colr = "cream" if i % 2 == 0 else "red"
            c.drawLine(o["cx"] + r0 * math.cos(ang), o["cy"] + r0 * math.sin(ang),
                       o["cx"] + r1 * math.cos(ang), o["cy"] + r1 * math.sin(ang),
                       M.paint(colr, 1 - p, stroke=10 * (1 - 0.6 * p), cap=skia.Paint.kRound_Cap))
        M.dashed_ring(c, o["cx"], o["cy"], 80 + 380 * p, "cream", (1 - p) * 0.8, width=6)

    def ov_starburst(self, c, o, f, ra):
        age = f - o["f_at"]
        dur = 24
        if age < 0 or age >= dur:
            return
        p = M.ease_out_cubic(age / dur)
        fade = 1 - M.clamp01((age - 10) / (dur - 10))
        for i in range(8):
            ang = i * 2 * math.pi / 8 + 0.3
            r = 30 + 120 * p
            x, y = o["cx"] + r * math.cos(ang), o["cy"] + r * math.sin(ang)
            sz = 16 * (1 - 0.4 * p) + 4
            path = M.star_path(x, y, sz, sz * 0.45, rot=p * 2)
            c.drawPath(path, M.paint("yellow", fade))
        M.dashed_ring(c, o["cx"], o["cy"], 50 + 90 * p, "yellow", fade * 0.9, width=5)

    def caption_layout(self, o):
        items = []
        y = o["y"]
        x = o["x"]
        icon_sz = 0
        if o.get("icon"):
            first = o["lines"][0]["size"]
            icon_sz = first * 2.1
            x += icon_sz * 0.72
        for i, ln in enumerate(o["lines"]):
            size = ln["size"]
            font = self.fonts.get("ExtraBold", size)
            tw = font.measureText(ln["text"])
            padx, pady = size * 0.5, size * 0.36
            top, bot = M.cap_box(size)
            hgt = (bot - top) + 2 * pady
            rect = skia.Rect.MakeXYWH(x, y, tw + 2 * padx, hgt)
            base_y = y + pady - top
            items.append((ln, font, rect, x + padx, base_y))
            y += hgt + size * 0.2
        return items, icon_sz

    def ov_caption(self, c, o, f, ra):
        items, icon_sz = self.caption_layout(o)
        ea = self.exit_alpha(o, f)
        tilts = [-1.4, 1.0, -0.8, 1.2]
        k = self.grid.last_beat_at(f)
        bage = f - self.grid.frame(k)
        march = M.ease_out_cubic(bage / 5) + k
        for i, (ln, font, rect, tx, ty) in enumerate(items):
            age = f - self.grid.frame(ln["at"])
            if age < 0:
                continue
            s, a = M.stamp(age, 10, 0.5)
            if age >= 10:
                s *= M.beat_pulse(bage, 0.014, 5.0)
            a *= ea
            style = ln.get("style", "cream")
            cx, cy = rect.centerX(), rect.centerY()
            c.save()
            c.translate(cx, cy)
            c.rotate(tilts[i % 4])
            c.scale(s, s)
            c.translate(-cx, -cy)
            st = M.draw_patch(c, rect, style, march=march * 0.5, a=a)
            segs = M.split_accent(ln["text"], ln.get("accent"), st["text"], st["accent"])
            M.draw_segments(c, font, segs, tx, ty, a)
            c.restore()
        if icon_sz:
            ln0 = items[0]
            age = f - self.grid.frame(o["lines"][0]["at"])
            if age >= 0:
                s, a = M.stamp(age, 12, 0.3)
                if age >= 12:
                    s *= M.beat_pulse(bage, 0.04, 5.0)
                img = self.icon(o["icon"])
                rect = ln0[2]
                cx = rect.left() - icon_sz * 0.28
                cy = rect.centerY() + 6
                c.save()
                c.translate(cx, cy)
                c.rotate(-10 + 10 * M.ease_out_cubic(age / 12))
                c.scale(s, s)
                c.drawCircle(0, 0, icon_sz * 0.52, M.paint("cream", a * ea))
                c.drawCircle(0, 0, icon_sz * 0.52 - 8, M.paint("purple", a * ea, stroke=3.2, dash=([13.0, 8.0], 0)))
                sc = icon_sz * 0.78 / max(img.width(), img.height())
                iw, ih = img.width() * sc, img.height() * sc
                p = skia.Paint(AntiAlias=True)
                p.setAlphaf(a * ea)
                c.drawImageRect(img, skia.Rect(-iw / 2, -ih / 2, iw / 2, ih / 2), self.mip, p)
                c.restore()

    def ov_keycap(self, c, o, f, ra):
        age = f - o["f0"]
        s, a = M.stamp(age, 10, 0.4)
        a *= self.exit_alpha(o, f)
        pressed = 0.0
        for b in o.get("press", []):
            pa = f - self.grid.frame(b)
            if 0 <= pa < 12:
                pressed = max(pressed, 1 - M.ease_out_cubic(pa / 12))
        if "hold" in o:
            h0, h1 = (self.grid.frame(b) for b in o["hold"])
            if h0 <= f < h1:
                pressed = 1.0
            elif f >= h1:
                pressed = max(pressed, 1 - M.ease_out_cubic((f - h1) / 8))
        c.save()
        c.translate(o["cx"], o["cy"])
        c.scale(s, s)
        c.translate(-o["cx"], -o["cy"])
        M.keycap(c, o["cx"], o["cy"], o["w"], o["h"], o["label"], self.fonts, pressed, a)
        c.restore()

    def ov_stamp(self, c, o, f, ra):
        age = f - o["f0"]
        s, a = M.stamp(age, 10, 1.9) if o["size"] >= 150 else M.stamp(age, 10, 0.4)
        if o["size"] >= 150 and age < 10:
            # slam in from large: scale 1.9 -> 1.0 with a small undershoot
            p = age / 10
            s = 1.0 + 0.9 * (1 - M.ease_out_cubic(p)) - 0.06 * math.sin(math.pi * M.clamp01(p * 1.4)) * (p > 0.4)
        a *= self.exit_alpha(o, f)
        if age >= 10:
            k = self.grid.last_beat_at(f)
            s *= M.beat_pulse(f - self.grid.frame(k), 0.02, 5.0)
        font = self.fonts.get("Black", o["size"])
        tw = font.measureText(o["text"])
        top, bot = M.cap_box(o["size"])
        c.save()
        c.translate(o["cx"], o["cy"])
        c.rotate(o.get("rot", 0.0))
        c.skew(o.get("skew", 0.0), 0)
        c.scale(s, s)
        base = -(top + bot) / 2
        sw = o["size"] * 0.085
        c.drawString(o["text"], -tw / 2 + 6, base + 10, font,
                     M.paint((8, 2, 10), 0.5 * a, stroke=sw, join=skia.Paint.kRound_Join))
        M.draw_text(c, font, o["text"], -tw / 2, base, o["fill"], a, stroke=o["stroke"], stroke_w=sw)
        c.restore()

    def ov_skid(self, c, o, f, ra):
        age = f - o["f0"]
        a = self.exit_alpha(o, f)
        p = M.ease_out_cubic(age / 12)
        for i, (dy, ln) in enumerate([(-58, 360), (0, 440), (58, 330)]):
            x1 = o["cx"] - 320 + i * 20
            x0 = x1 - ln * p
            y = o["cy"] + dy
            c.drawLine(x0, y, x1, y, M.paint("plum", 0.55 * a, stroke=16, cap=skia.Paint.kRound_Cap))
            c.drawLine(x0, y, x1, y, M.paint("cream", 0.85 * a, stroke=5, cap=skia.Paint.kRound_Cap,
                                              dash=([22.0, 14.0], -age * 3.0)))

    def ov_chip(self, c, o, f, ra):
        age = f - o["f_at"]
        s, a = M.stamp(age, 10, 0.45)
        size = 38
        font = self.fonts.get("ExtraBold", size)
        tw = font.measureText(o["text"])
        padx, pady = 26, 16
        top, bot = M.cap_box(size)
        hgt = bot - top + 2 * pady
        rect = skia.Rect.MakeXYWH(o["cx"] - tw / 2 - padx, o["cy"] - hgt / 2, tw + 2 * padx, hgt)
        k = self.grid.last_beat_at(f)
        c.save()
        c.translate(o["cx"], o["cy"])
        c.rotate(-1.5 if o["at"] % 2 == 0 else 1.5)
        c.scale(s, s)
        c.translate(-o["cx"], -o["cy"])
        M.draw_patch(c, rect, "purple", march=k * 0.5, a=a)
        M.draw_text(c, font, o["text"], o["cx"], o["cy"] - (top + bot) / 2, "cream", a, align="center")
        c.restore()

    def ov_url(self, c, o, f, ra):
        age = f - o["f0"]
        s, a = M.stamp(age, 11, 0.45)
        k = self.grid.last_beat_at(f)
        if age >= 11:
            s *= M.beat_pulse(f - self.grid.frame(k), 0.03 if int(round(k)) % 4 == 0 else 0.012, 6.0)
        size = o["size"]
        font = self.fonts.get("ExtraBold", size)
        tw = font.measureText(o["text"])
        top, bot = M.cap_box(size)
        padx, pady = 44, 26
        hgt = bot - top + 2 * pady
        rect = skia.Rect.MakeXYWH(o["cx"] - tw / 2 - padx, o["cy"] - hgt / 2, tw + 2 * padx, hgt)
        c.save()
        c.translate(o["cx"], o["cy"])
        c.scale(s, s)
        c.translate(-o["cx"], -o["cy"])
        M.draw_patch(c, rect, "purple", march=k * 0.5, radius=hgt / 2, a=a)
        M.draw_text(c, font, o["text"], o["cx"], o["cy"] - (top + bot) / 2, "cream", a, align="center")
        c.restore()

    def ov_attribution(self, c, o, f, ra):
        age = f - o["f0"]
        a = 0.88 * M.clamp01(age / 12)
        font = self.fonts.get("Medium", o["size"])
        y = o["y"]
        for ln in o["lines"]:
            M.draw_text(c, font, ln, W / 2, y, "cream", a, align="center")
            y += o["size"] * 1.34

    def ov_needle(self, c, o, f, ra):
        rel = f - o["f_at"]
        if rel < -6 or rel > 9:
            return
        tip_hit = 660.0
        if rel < 0:
            p = (rel + 7) / 7
            tip = -60 + (tip_hit + 60) * M.ease_in_cubic(p)
            streak = M.ease_in_cubic(p)
        else:
            p = rel / 9
            tip = tip_hit + 24 * (1 - p) * (rel <= 1) - (tip_hit + 160) * M.ease_in_cubic(p)
            streak = 0.0
            if rel <= 7:
                q = rel / 7
                M.dashed_ring(c, 960, tip_hit, 30 + 160 * M.ease_out_cubic(q), "cream", 0.9 * (1 - q), width=6)
        if streak > 0:
            c.drawRect(skia.Rect(960 - 3, 0, 960 + 3, tip - 300), M.paint("cream", 0.35 * streak))
        M.needle(c, 960, tip, length=1300, width=46)

    def ov_fade_black(self, c, o, f, ra):
        a = M.clamp01((f - o["f0"] + 1) / (o["f1"] - o["f0"]))
        c.drawRect(skia.Rect(0, 0, W, H), M.paint((0, 0, 0), a))

    def debug_marker(self, c, f):
        k = self.grid.last_beat_at(f)
        age = f - self.grid.frame(k)
        on = age < 3
        c.drawRect(skia.Rect(1790, 150, 1900, 260), M.paint((255, 255, 255) if on else (0, 0, 0), 1.0))
        if int(round(k)) % 4 == 0 and on:
            c.drawRect(skia.Rect(1805, 165, 1885, 245), M.paint((255, 0, 0), 1.0))
        font = self.fonts.get("Bold", 30)
        M.draw_text(c, font, "b%d f%d" % (k, f), 1845, 300, (255, 255, 0), 1.0, stroke=(0, 0, 0), stroke_w=5, align="center")

    # ------------------------------------------------------------ resolved timeline

    def export(self):
        g = self.grid
        out = {
            "_doc": "Resolved from tools/promo/video/timeline.json by render.py. t = seconds in the video, f = frame index at 60 fps. "
                    "Beat b sits at t = b * period; the music clip starts at song_start seconds of the mp3.",
            "music": {"file": self.tl["music"]["file"], "song_start_sec": round(g.song_start, 6),
                      "period_sec": round(g.period, 6), "bpm": round(60 / g.period, 4),
                      "grid_fit_residual_ms": round(g.residual_ms, 3), "length_beats": g.length,
                      "frames": g.nframes, "duration_sec": round(g.nframes / FPS, 6)},
            "beats": [{"b": b, "t": round(g.sec(b), 4), "f": g.frame(b), "downbeat": b % 4 == 0} for b in range(g.length + 1)],
            "shots": [], "overlays": [],
        }
        for s in self.shots:
            d = {"id": s["id"], "start_b": s["start"], "end_b": s["end"], "t0": round(g.sec(s["start"]), 4),
                 "t1": round(g.sec(s["end"]), 4), "f0": s["f0"], "f1": s["f1"]}
            if "clip" in s:
                d["clip"] = s["clip"] + ".mp4"
                d["src_frame_first"] = map_src_frame(g, s["map"], s["f0"])
                d["src_frame_last"] = map_src_frame(g, s["map"], s["f1"] - 1)
                d["retime_keys"] = [{"b": b, "f": g.frame(b), "src_sec": sv, "src_frame": int(round(sv * FPS))} for b, sv in s["map"]]
                if "zoom" in s:
                    d["zoom"] = s["zoom"]
            else:
                d["background"] = s["bg"]
            out["shots"].append(d)
        for o in self.ovs:
            d = {k: v for k, v in o.items() if k not in ("f0", "f1", "f_at")}
            if "start" in o:
                d["t0"], d["t1"], d["f0"], d["f1"] = round(g.sec(o["start"]), 4), round(g.sec(o["end"]), 4), o["f0"], o["f1"]
            if "at" in o:
                d["t_at"], d["f_at"] = round(g.sec(o["at"]), 4), o["f_at"]
            if o["type"] == "caption":
                for ln in d["lines"]:
                    ln["t"] = round(g.sec(ln["at"]), 4)
                    ln["f"] = g.frame(ln["at"])
            out["overlays"].append(d)
        return out


def encoder_cmd(out, crf, fps=FPS):
    return [FFMPEG, "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgba", "-s", "%dx%d" % (W, H),
            "-framerate", str(fps), "-i", "-",
            "-vf", "scale=out_color_matrix=bt709:out_range=tv:flags=accurate_rnd+full_chroma_int,format=yuv420p",
            "-c:v", "libx264", "-preset", "slow", "-crf", str(crf), "-profile:v", "high", "-level:v", "4.2",
            "-g", "120", "-pix_fmt", "yuv420p",
            "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv",
            "-x264-params", "colorprim=bt709:transfer=bt709:colormatrix=bt709:range=tv",
            "-an", "-movflags", "+faststart", out]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--timeline", default=os.path.join(HERE, "timeline.json"))
    ap.add_argument("--out")
    ap.add_argument("--crf", type=int, default=16)
    ap.add_argument("--debug-beats", action="store_true")
    ap.add_argument("--range", default="")
    ap.add_argument("--stills")
    ap.add_argument("--at", default="")
    ap.add_argument("--export-timeline")
    a = ap.parse_args()
    tl = json.load(open(a.timeline))
    comp = Compositor(tl, debug_beats=a.debug_beats)
    g = comp.grid
    print("grid: period %.6f s (%.3f BPM), song start %.4f s, %d frames (%.4f s), fit residual %.2f ms"
          % (g.period, 60 / g.period, g.song_start, g.nframes, g.nframes / FPS, g.residual_ms), file=sys.stderr)
    if a.export_timeline:
        with open(a.export_timeline, "w") as fp:
            json.dump(comp.export(), fp, ensure_ascii=False, indent=1)
        print("wrote", a.export_timeline, file=sys.stderr)
    if a.stills:
        os.makedirs(a.stills, exist_ok=True)
        buf = np.empty((H, W, 4), np.uint8)
        for f in [int(x) for x in a.at.split(",") if x]:
            comp.render(f, random_access=True)
            comp.read(buf)
            from PIL import Image
            Image.fromarray(buf[..., :3]).save(os.path.join(a.stills, "f%05d.png" % f))
        return
    if not a.out:
        return
    f0, f1 = 0, g.nframes
    if a.range:
        s, e = a.range.split(":")
        f0, f1 = int(s), int(e)
    enc = subprocess.Popen(encoder_cmd(a.out, a.crf), stdin=subprocess.PIPE)
    buf = np.empty((H, W, 4), np.uint8)
    t0 = time.time()
    prev_shot = None
    for f in range(f0, f1):
        shot = comp.shot_at(f)
        if shot is not prev_shot:
            keep = {"shot:" + shot["id"]} | {"card:" + o["id"] for o in comp.ovs if o["type"] == "card_clip" and o["f0"] <= f < o["f1"]}
            comp.drop_readers(keep)
            prev_shot = shot
        comp.render(f)
        comp.read(buf)
        enc.stdin.write(buf.data)
        if f % 120 == 0:
            el = time.time() - t0
            print("frame %d/%d  %.1f fps" % (f, f1, (f - f0 + 1) / max(el, 1e-6)), file=sys.stderr)
    enc.stdin.close()
    rc = enc.wait()
    comp.drop_readers(set())
    print("done in %.1f s, encoder rc %d" % (time.time() - t0, rc), file=sys.stderr)
    sys.exit(rc)


if __name__ == "__main__":
    main()
