#!/usr/bin/env python3
"""Contact sheets for review and the storyboard deliverable.

usage:
  sheets.py grid OUT.jpg COLS THUMB_W IMG1 [IMG2 ...]            (labels = file names)
  sheets.py frames VIDEO OUT.jpg COLS THUMB_W F1,F2,...          (frames from a video, labelled with time/beat)
  sheets.py storyboard VIDEO RESOLVED_TIMELINE.json OUT.jpg      (one frame per shot, labelled with beat/time)
  sheets.py poster VIDEO FRAME OUT.jpg
"""
import json
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
FONT = os.path.join(ROOT, "tools", "promo", "fonts", "Pretendard-Bold.otf")
FFMPEG = "/opt/homebrew/bin/ffmpeg"
W, H = 1920, 1080


def video_frames(video, frames):
    """Decode exact frame indices (BT.709 limited -> RGB)."""
    frames = sorted(set(frames))
    sel = "+".join("eq(n\\,%d)" % f for f in frames)
    cmd = [FFMPEG, "-v", "error", "-nostdin", "-i", video, "-vf",
           "select='%s',scale=in_color_matrix=bt709:in_range=tv:flags=accurate_rnd+full_chroma_int,format=rgb24" % sel,
           "-fps_mode", "passthrough", "-f", "rawvideo", "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    n = len(raw) // (W * H * 3)
    arr = np.frombuffer(raw[: n * W * H * 3], np.uint8).reshape(n, H, W, 3)
    return {f: Image.fromarray(arr[i]) for i, f in enumerate(frames[:n])}


def grid(images, labels, cols, thumb_w, title=None):
    th = int(thumb_w * 9 / 16)
    lab_h = 34
    rows = (len(images) + cols - 1) // cols
    top = 56 if title else 0
    sheet = Image.new("RGB", (cols * thumb_w + (cols + 1) * 8, top + rows * (th + lab_h + 8) + 8), (24, 14, 32))
    d = ImageDraw.Draw(sheet)
    font = ImageFont.truetype(FONT, 22)
    if title:
        d.text((12, 12), title, font=ImageFont.truetype(FONT, 30), fill=(243, 231, 201))
    for i, (im, lab) in enumerate(zip(images, labels)):
        r, c = divmod(i, cols)
        x = 8 + c * (thumb_w + 8)
        y = top + 8 + r * (th + lab_h + 8)
        sheet.paste(im.convert("RGB").resize((thumb_w, th), Image.LANCZOS), (x, y + lab_h))
        d.text((x + 2, y + 4), lab, font=font, fill=(243, 231, 201))
    return sheet


def main():
    mode = sys.argv[1]
    if mode == "grid":
        out, cols, tw = sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
        paths = sys.argv[5:]
        ims = [Image.open(p) for p in paths]
        grid(ims, [os.path.basename(p) for p in paths], cols, tw).save(out, quality=90)
    elif mode == "frames":
        video, out, cols, tw = sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
        fl = [int(x) for x in sys.argv[6].split(",") if x]
        period = float(sys.argv[7]) if len(sys.argv) > 7 else 0.5454592
        got = video_frames(video, fl)
        fl = [f for f in fl if f in got]
        labels = ["f%d  %.3fs  b%.2f" % (f, f / 60, f / 60 / period) for f in fl]
        grid([got[f] for f in fl], labels, cols, tw).save(out, quality=90)
    elif mode == "storyboard":
        video, tlp, out = sys.argv[2], sys.argv[3], sys.argv[4]
        tl = json.load(open(tlp))
        picks, labels = [], []
        for s in tl["shots"]:
            f0, f1 = s["f0"], s["f1"]
            f = f0 + max(1, int((f1 - f0) * 0.62)) if f1 - f0 > 12 else f0 + (f1 - f0) // 2
            picks.append(f)
            src = s.get("clip", s.get("background", ""))
            labels.append("b%s-%s  %.2f-%.2fs  %s" % (s["start_b"], s["end_b"], s["t0"], s["t1"], s["id"]))
        got = video_frames(video, picks)
        grid([got[f] for f in picks], labels, 4, 460,
             title="OVERLOCK promo storyboard  (b = beat of Newer Wave clip, 110 BPM, 60 fps)").save(out, quality=90)
    elif mode == "poster":
        video, f, out = sys.argv[2], int(sys.argv[3]), sys.argv[4]
        video_frames(video, [f])[f].save(out, quality=92)
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
