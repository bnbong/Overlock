#!/usr/bin/env python3
"""run_capture.sh ... stills 결과(<runs>/s_<시나리오>_<1080|4k>/stills)를 footage/stills 로 모은다.

usage: collect_stills.py <runs 디렉터리> <footage/stills 디렉터리>
파일명: <트랙>_<장면><순번>_<해상도>_<hud|nohud>.png (hud=실제 HUD 그대로, nohud=같은 프레임에서 HUD 레이어만 숨김)
"""
import glob
import os
import re
import shutil
import sys

TRACK = {"heart": "heart01", "tee": "tee01", "star": "star01"}
RES = {"1080": "1920x1080", "4k": "3840x2160"}


def main():
    runs, dst = sys.argv[1], sys.argv[2]
    os.makedirs(dst, exist_ok=True)
    for f in glob.glob(os.path.join(dst, "*.png")):
        os.remove(f)
    n = 0
    for d in sorted(glob.glob(os.path.join(runs, "s_*_*"))):
        _, scen, res = os.path.basename(d).split("_")
        for f in sorted(glob.glob(os.path.join(d, "stills", "*.png"))):
            m = re.match(r"(.+)_(\d\d)_(hud|nohud)\.png$", os.path.basename(f))
            if not m:
                continue
            name, seq, hud = m.groups()
            out = "%s_%s%s_%s_%s.png" % (TRACK[scen], name, seq, RES[res], hud)
            shutil.copy2(f, os.path.join(dst, out))
            n += 1
    print("copied", n)


if __name__ == "__main__":
    main()
