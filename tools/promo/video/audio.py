#!/usr/bin/env python3
"""Cut the music clip on the beat grid, fade, loudness-normalise (EBU R128, 2 passes).

usage: audio.py OUT.wav WORKDIR
The clip starts exactly at beat `first_beat_index` of the beat grid fitted to beatmap.json
and lasts exactly as many samples as the video has frames (so audio sample 0 == video frame 0).
"""
import json
import os
import re
import subprocess
import sys

import numpy as np
import soundfile as sf

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, HERE)
from render import Grid, FPS  # noqa: E402

FFMPEG = "/opt/homebrew/bin/ffmpeg"
SR = 48000
# True-peak target leaves headroom for the AAC encoder (measured overshoot about +0.4 dB with aac_at).
TARGET_I, TARGET_TP, TARGET_LRA = -14.0, -2.0, 11.0


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=True)


def loudnorm_measure(path, extra=""):
    r = run([FFMPEG, "-hide_banner", "-nostdin", "-i", path, "-af",
             "loudnorm=I=%g:TP=%g:LRA=%g:print_format=json%s" % (TARGET_I, TARGET_TP, TARGET_LRA, extra),
             "-f", "null", "-"])
    js = re.findall(r"\{[^{}]*\"input_i\"[^{}]*\}", r.stderr, re.S)[-1]
    return json.loads(js)


def main():
    out, work = sys.argv[1], sys.argv[2]
    os.makedirs(work, exist_ok=True)
    tl = json.load(open(os.path.join(HERE, "timeline.json")))
    mus = tl["music"]
    g = Grid(os.path.join(ROOT, mus["beatmap"]), mus["first_beat_index"], mus["length_beats"])
    full = os.path.join(work, "song_48k.wav")
    # Decode the whole mp3 once (ffmpeg handles the mp3 encoder delay/padding, same time base as beatmap.json)
    # and resample with soxr, which is phase-linear and delay-compensated.
    run([FFMPEG, "-v", "error", "-y", "-nostdin", "-i", os.path.join(ROOT, mus["file"]),
         "-af", "aresample=%d:resampler=soxr:precision=28" % SR, "-c:a", "pcm_f32le", full])
    y, sr = sf.read(full, dtype="float64", always_2d=True)
    assert sr == SR
    s0 = int(round(g.song_start * SR))
    n = int(round(g.nframes / FPS * SR))  # exactly the video length
    clip = y[s0:s0 + n].copy()
    assert len(clip) == n
    # 50 ms de-click fade in, equal-power fade out over the last bar(s)
    fi = int(mus["fade_in_ms"] / 1000 * SR)
    clip[:fi] *= np.linspace(0, 1, fi)[:, None]
    fo0 = int(round(g.sec(mus["fade_out_beats"][0]) * SR))
    ramp = np.linspace(0, 1, n - fo0)
    clip[fo0:] *= np.cos(ramp * np.pi / 2)[:, None]
    cut = os.path.join(work, "music_cut.wav")
    sf.write(cut, clip.astype(np.float32), SR, subtype="FLOAT")
    m1 = loudnorm_measure(cut)
    # Second pass: linear gain only (no dynamic processing) when the true-peak budget allows it.
    gain_db = TARGET_I - float(m1["input_i"])
    tp_after = float(m1["input_tp"]) + gain_db
    limited = False
    g_lin = 10 ** (gain_db / 20)
    y2 = clip * g_lin
    if tp_after > TARGET_TP:
        # Soft look-ahead-free safety: use ffmpeg alimiter at the true-peak ceiling (rare with this track).
        tmp = os.path.join(work, "music_gain.wav")
        sf.write(tmp, y2.astype(np.float32), SR, subtype="FLOAT")
        lim = os.path.join(work, "music_lim.wav")
        run([FFMPEG, "-v", "error", "-y", "-nostdin", "-i", tmp, "-af",
             "alimiter=limit=%f:attack=1:release=60:level=disabled:latency=1" % (10 ** ((TARGET_TP - 0.3) / 20)),
             "-c:a", "pcm_f32le", lim])
        y2, _ = sf.read(lim, dtype="float64", always_2d=True)
        y2 = y2[:n]
        limited = True
    sf.write(out, np.clip(y2, -1, 1).astype(np.float32), SR, subtype="FLOAT")
    m2 = loudnorm_measure(out)
    report = {
        "song_start_sec": g.song_start, "start_sample_48k": s0, "samples": n, "sample_rate": SR,
        "duration_sec": n / SR, "pass1": m1, "gain_db": gain_db, "limiter": limited, "result": m2,
    }
    with open(os.path.join(work, "audio_report.json"), "w") as fp:
        json.dump(report, fp, indent=1)
    print(json.dumps({"gain_db": round(gain_db, 2), "limiter": limited, "I": m2["input_i"], "TP": m2["input_tp"],
                      "LRA": m2["input_lra"], "samples": n}))


if __name__ == "__main__":
    main()
