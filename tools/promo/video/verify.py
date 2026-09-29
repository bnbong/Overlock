#!/usr/bin/env python3
"""Verification for the promo video: container spec, cut/beat sync, audio alignment, loudness.

usage:
  verify.py spec   FINAL.mp4
  verify.py cuts   FINAL.mp4 RESOLVED_TIMELINE.json OUT.json
  verify.py audio  FINAL.mp4 SONG_48K.wav RESOLVED_TIMELINE.json OUT.json
  verify.py debug  DEBUG.mp4 RESOLVED_TIMELINE.json OUT.json
  verify.py loud   FINAL.mp4
  verify.py dark   FINAL.mp4 RESOLVED_TIMELINE.json
"""
import json
import re
import subprocess
import sys

import numpy as np

FFMPEG = "/opt/homebrew/bin/ffmpeg"
FFPROBE = "/opt/homebrew/bin/ffprobe"
FPS = 60
SR = 48000


def sh(cmd, text=True):
    return subprocess.run(cmd, capture_output=True, text=text, check=True)


def spec(path):
    r = sh([FFPROBE, "-v", "error", "-show_format", "-show_streams", "-of", "json", path])
    d = json.loads(r.stdout)
    out = {"format": {k: d["format"].get(k) for k in ("duration", "size", "bit_rate", "format_name", "start_time")}}
    for s in d["streams"]:
        keys = ["codec_name", "profile", "width", "height", "pix_fmt", "r_frame_rate", "avg_frame_rate",
                "color_range", "color_space", "color_transfer", "color_primaries", "nb_frames", "start_time",
                "start_pts", "duration", "bit_rate", "sample_rate", "channels", "channel_layout", "level"]
        out[s["codec_type"]] = {k: s.get(k) for k in keys if k in s}
    # first packet timestamps and edit lists
    for sel in ("v:0", "a:0"):
        r = sh([FFPROBE, "-v", "error", "-select_streams", sel, "-show_entries", "packet=pts_time,dts_time",
                "-read_intervals", "%+#3", "-of", "csv=p=0", path])
        out["first_packets_" + sel] = r.stdout.split()
    r = subprocess.run([FFPROBE, "-v", "trace", "-i", path], capture_output=True, text=True)
    out["edit_lists"] = re.findall(r"(?:duration=\d+ time=-?\d+ rate=[\d.]+)", r.stderr)
    out["moov_before_mdat"] = r.stderr.find("type:'moov'") < r.stderr.find("type:'mdat'")
    return out


def decode_small(path, w=192, h=108):
    r = subprocess.run([FFMPEG, "-v", "error", "-nostdin", "-i", path, "-vf",
                        "scale=%d:%d:flags=area,format=rgb24" % (w, h), "-f", "rawvideo", "-"],
                       capture_output=True, check=True)
    n = len(r.stdout) // (w * h * 3)
    return np.frombuffer(r.stdout, np.uint8).reshape(n, h, w, 3).astype(np.float32)


def detect_cuts(frames):
    """A cut = large frame difference that is a local spike vs. its neighbours."""
    d = np.abs(np.diff(frames, axis=0)).mean(axis=(1, 2, 3))  # d[i] = diff between frame i and i+1
    changed = (np.abs(np.diff(frames, axis=0)).max(axis=3) > 40).mean(axis=(1, 2))
    cuts = []
    for i in range(len(d)):
        lo = d[max(0, i - 3):i]
        hi = d[i + 1:i + 4]
        neigh = np.concatenate([lo, hi]) if len(lo) + len(hi) else np.array([0.0])
        if d[i] > 9.0 and changed[i] > 0.18 and d[i] > 2.2 * max(np.median(neigh), 1.0):
            cuts.append(i + 1)  # first frame of the new shot
    return cuts, d, changed


def cuts_cmd(video, tlp, outp):
    tl = json.load(open(tlp))
    period = tl["music"]["period_sec"]
    intended = [s["f0"] for s in tl["shots"] if s["f0"] > 0]
    frames = decode_small(video)
    det, d, ch = detect_cuts(frames)
    rows = []
    for f in sorted(set(det) | set(intended)):
        t = f / FPS
        b = t / period
        nb = round(b)
        n16 = round(b * 4) / 4
        grid = n16 if abs(b - n16) < abs(b - nb) - 1e-9 else nb
        rows.append({
            "frame": f, "t": round(t, 4), "detected": f in det, "intended": f in intended,
            "nearest_grid_beat": grid, "grid_t": round(grid * period, 4),
            "err_ms": round((t - grid * period) * 1000, 2), "err_frames": round((t - grid * period) * FPS, 3),
            "diff": round(float(d[f - 1]), 2) if f - 1 < len(d) else None,
        })
    missed = [f for f in intended if f not in det]
    extra = [f for f in det if f not in intended]
    res = {"frames_total": int(len(frames)), "intended": intended, "detected": det, "missed": missed,
           "unplanned": extra, "rows": rows,
           "max_abs_err_frames_intended": max(abs(r["err_frames"]) for r in rows if r["intended"]),
           "max_abs_err_ms_intended": max(abs(r["err_ms"]) for r in rows if r["intended"])}
    json.dump(res, open(outp, "w"), indent=1)
    print("intended %d detected %d missed %s unplanned %s max err %.3f frames (%.2f ms)"
          % (len(intended), len(det), missed, extra, res["max_abs_err_frames_intended"], res["max_abs_err_ms_intended"]))


def decode_audio(path, mono=True):
    r = subprocess.run([FFMPEG, "-v", "error", "-nostdin", "-i", path, "-map", "0:a:0", "-f", "f32le",
                        "-ac", "1" if mono else "2", "-ar", str(SR), "-"], capture_output=True, check=True)
    return np.frombuffer(r.stdout, np.float32).astype(np.float64)


def xcorr_lag(a, b, maxlag):
    """Lag L (samples) maximising sum a[n] * b[n + L]."""
    n = min(len(a), len(b))
    a, b = a[:n], b[:n]
    size = 1 << int(np.ceil(np.log2(2 * n)))
    fa = np.fft.rfft(a, size)
    fb = np.fft.rfft(b, size)
    cc = np.fft.irfft(np.conj(fa) * fb, size)
    lags = np.concatenate([np.arange(0, maxlag + 1), np.arange(-maxlag, 0)])
    vals = np.concatenate([cc[:maxlag + 1], cc[-maxlag:]])
    i = int(np.argmax(vals))
    return int(lags[i]), float(vals[i] / (np.sqrt((a * a).sum() * (b * b).sum()) + 1e-12))


def onsets(y, sr=SR):
    import librosa
    hop = 64
    env = librosa.onset.onset_strength(y=y.astype(np.float32), sr=sr, hop_length=hop, aggregate=np.median)
    pk = librosa.util.peak_pick(env, pre_max=6, post_max=6, pre_avg=40, post_avg=40,
                                delta=float(np.percentile(env, 92)) * 0.35, wait=40)
    return librosa.frames_to_time(pk, sr=sr, hop_length=hop), env


def audio_cmd(video, song48, tlp, outp):
    import soundfile as sf
    tl = json.load(open(tlp))
    m = tl["music"]
    period = m["period_sec"]
    fin = decode_audio(video)
    ref, sr = sf.read(song48, dtype="float64", always_2d=True)
    ref = ref.mean(axis=1)
    s0 = int(round(m["song_start_sec"] * SR))
    refc = ref[s0:s0 + len(fin)]
    # alignment of the delivered audio against the untouched song, over the middle of the clip
    a0, a1 = int(2 * SR), int(40 * SR)
    lag, corr = xcorr_lag(refc[a0:a1], fin[a0:a1], 2000)
    on, _ = onsets(fin)
    beats = np.array([b["t"] for b in tl["beats"]])
    errs = []
    for t in beats[:-1]:
        j = np.argmin(np.abs(on - t))
        if abs(on[j] - t) < 0.08:
            errs.append((on[j] - t) * 1000)
    errs = np.array(errs)
    # fill 16ths
    fill = [round((63 + k / 4) * period, 4) for k in range(4)] + [round(64 * period, 4)]
    fill_err = [round(float((on[np.argmin(np.abs(on - t))] - t) * 1000), 2) for t in fill]
    res = {"samples_final": int(len(fin)), "duration_final_s": len(fin) / SR,
           "lag_samples_vs_source": lag, "lag_ms": lag / SR * 1000, "norm_xcorr": round(corr, 4),
           "beats_with_onset_within_80ms": int(len(errs)), "beats_total": int(len(beats) - 1),
           "onset_minus_beat_ms": {"median": round(float(np.median(errs)), 2), "mean": round(float(errs.mean()), 2),
                                   "p90_abs": round(float(np.percentile(np.abs(errs), 90)), 2),
                                   "max_abs": round(float(np.abs(errs).max()), 2)},
           "fill_16ths_onset_err_ms": fill_err,
           "clip_samples_over_0.999": int((np.abs(decode_audio(video, mono=False)) >= 0.999).sum())}
    json.dump(res, open(outp, "w"), indent=1)
    print(json.dumps(res, indent=1))


def debug_cmd(video, tlp, outp):
    """Debug render: a white square is lit for 3 frames from every beat frame.
    Compare lit frames with the kick onsets decoded from the same file."""
    tl = json.load(open(tlp))
    r = subprocess.run([FFMPEG, "-v", "error", "-nostdin", "-i", video, "-vf",
                        "crop=60:60:1815:175,scale=1:1:flags=area,format=rgb24", "-f", "rawvideo", "-"],
                       capture_output=True, check=True)
    # red channel: the marker is white on beats and red+white on downbeats, black otherwise
    lum = np.frombuffer(r.stdout, np.uint8).reshape(-1, 3)[:, 0].astype(int)
    lit = np.where((lum[1:] > 128) & (lum[:-1] <= 128))[0] + 1
    if lum[0] > 128:
        lit = np.concatenate([[0], lit])
    fin = decode_audio(video)
    on, _ = onsets(fin)
    rows = []
    for f in lit:
        t = f / FPS
        j = np.argmin(np.abs(on - t))
        rows.append({"marker_frame": int(f), "marker_t": round(t, 5), "onset_t": round(float(on[j]), 5),
                     "onset_sample": int(round(on[j] * SR)), "marker_sample": int(f * SR // FPS),
                     "diff_ms": round(float((on[j] - t) * 1000), 2),
                     "diff_frames": round(float((on[j] - t) * FPS), 3)})
    expected = [b["f"] for b in tl["beats"][:-1]]
    diffs = np.array([r_["diff_ms"] for r_ in rows if abs(r_["diff_ms"]) < 80])
    res = {"marker_frames_found": int(len(lit)), "expected_beats": len(expected),
           "marker_frames_equal_timeline": [int(x) for x in lit] == expected,
           "onset_minus_marker_ms": {"median": round(float(np.median(diffs)), 2),
                                     "max_abs": round(float(np.abs(diffs).max()), 2),
                                     "within_1_frame": int((np.abs(diffs) <= 1000 / FPS).sum()),
                                     "n": int(len(diffs))},
           "rows": rows}
    json.dump(res, open(outp, "w"), indent=1)
    print(json.dumps({k: v for k, v in res.items() if k != "rows"}, indent=1))


def loud_cmd(video):
    r = subprocess.run([FFMPEG, "-hide_banner", "-nostdin", "-i", video, "-map", "0:a:0", "-af",
                        "ebur128=peak=true:framelog=quiet", "-f", "null", "-"], capture_output=True, text=True)
    tail = r.stderr[r.stderr.rfind("Summary:"):]
    print(tail.strip())


def dark_cmd(video, tlp):
    tl = json.load(open(tlp))
    frames = decode_small(video)
    luma = frames.mean(axis=(1, 2, 3))
    fade0 = [o for o in tl["overlays"] if o["type"] == "fade_black"][0]["f0"]
    bad = [int(i) for i in np.where(luma < 12)[0] if i < fade0]
    print("frames darker than 12/255 before the planned fade:", bad[:50], "count", len(bad))
    print("min luma %.1f at %d; mean %.1f" % (luma.min(), int(luma.argmin()), luma.mean()))


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "spec":
        print(json.dumps(spec(sys.argv[2]), indent=1))
    elif cmd == "cuts":
        cuts_cmd(*sys.argv[2:5])
    elif cmd == "audio":
        audio_cmd(*sys.argv[2:6])
    elif cmd == "debug":
        debug_cmd(*sys.argv[2:5])
    elif cmd == "loud":
        loud_cmd(sys.argv[2])
    elif cmd == "dark":
        dark_cmd(*sys.argv[2:4])
    else:
        raise SystemExit(__doc__)
