#!/usr/bin/env python3
"""footage/*.mp4 의 대표 프레임을 모아 클립명을 적은 contact_sheet.jpg 를 만든다.

usage: contact_sheet.py <footage 디렉터리> [출력 jpg]
대표 시각은 REP 표(초). 4열 그리드, 칸당 640x360.
"""
import os
import subprocess
import sys
import tempfile

FFMPEG = "/opt/homebrew/bin/ffmpeg"
FONT = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
REP = {
    "01_title": 3.0, "02_trackselect": 4.0, "03_countdown_go": 1.5, "04_straight_speedup": 3.6,
    "05_curves_clean": 6.0, "06_drift": 1.5, "07_thimble": 2.0, "08_mom_chance": 2.5,
    "09_injury": 2.6, "10_bonk_scold": 3.0, "11_finish_reveal": 3.0, "11b_finish_reveal_star": 3.0, "12_result": 2.0,
}


def main():
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(src, "contact_sheet.jpg")
    clips = sorted(f for f in os.listdir(src) if f.endswith(".mp4"))
    with tempfile.TemporaryDirectory(dir=os.path.dirname(os.path.abspath(out))) as tmp:
        for i, f in enumerate(clips):
            name = f[:-4]
            t = REP.get(name, 1.0)
            label = "%s  (t=%.1fs)" % (name, t)
            vf = (
                "scale=640:360,drawbox=x=0:y=0:w=iw:h=34:color=black@0.65:t=fill,"
                "drawtext=fontfile='%s':text='%s':x=10:y=8:fontsize=20:fontcolor=white"
                % (FONT, label)
            )
            subprocess.run(
                [FFMPEG, "-v", "error", "-y", "-ss", str(t), "-i", os.path.join(src, f),
                 "-frames:v", "1", "-vf", vf, os.path.join(tmp, "t%02d.png" % i)],
                check=True,
            )
        cols = 4
        rows = (len(clips) + cols - 1) // cols
        subprocess.run(
            [FFMPEG, "-v", "error", "-y", "-i", os.path.join(tmp, "t%02d.png"),
             "-vf", "tile=%dx%d:padding=4:color=white" % (cols, rows), "-frames:v", "1",
             "-q:v", "3", out],
            check=True,
        )
    print("wrote", out)


if __name__ == "__main__":
    main()
