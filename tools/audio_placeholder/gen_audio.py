#!/usr/bin/env python3
"""Generate placeholder audio assets for Overlock (sewing-machine racing game).

Pure Python standard library only (wave, math, struct, random, pathlib) --
no numpy, no third-party audio libraries. All sounds are synthesized from
scratch using simple additive/subtractive synthesis (sine tones, harmonic
mixes, noise bursts, and phase-accumulated frequency sweeps) and written out
as 44.1kHz 16-bit mono PCM WAV files.

Every generated clip is normalized below full scale (peak target <= 0.9) and
has its edges faded to exact zero so it starts/ends without a click. The BGM
loop is built from independently-enveloped "grain" notes that are mixed into
the output buffer with wrap-around indexing, which makes the loop
mathematically periodic (the tail of the last note spills into the head of
the buffer exactly as it would on a real repeat), so there is no seam at the
loop point.

Run directly to (re)generate every file under game/assets/audio/:

    python3 tools/audio_placeholder/gen_audio.py

The script prints peak / RMS / duration stats for every generated file so
clipping (and, for the BGM, loop-boundary discontinuities) can be checked by
eye without needing to actually play the files back.
"""

from __future__ import annotations

import math
import random
import struct
import wave
from pathlib import Path

SAMPLE_RATE = 44100
BIT_DEPTH = 16
OUTPUT_DIR = Path(__file__).resolve().parents[2] / "game" / "assets" / "audio"

TAU = 2.0 * math.pi


# ---------------------------------------------------------------------------
# Low-level synthesis helpers
# ---------------------------------------------------------------------------


def freq_from_semitone(semitones_from_a4: float) -> float:
    """Equal-temperament frequency, `semitones_from_a4` semitones from A4 (440Hz)."""
    return 440.0 * (2.0 ** (semitones_from_a4 / 12.0))


def gen_tone(
    freq: float,
    duration: float,
    sample_rate: int = SAMPLE_RATE,
    wave_shape: str = "sine",
    harmonic2: float = 0.0,
) -> list[float]:
    """Fixed-frequency tone. `harmonic2` mixes in a 2nd-harmonic sine for brightness."""
    n = int(round(duration * sample_rate))
    out = [0.0] * n
    for i in range(n):
        t = i / sample_rate
        val = math.sin(TAU * freq * t)
        if harmonic2:
            val += harmonic2 * math.sin(TAU * 2.0 * freq * t)
        if wave_shape == "square":
            val = 1.0 if val >= 0.0 else -1.0
        out[i] = val
    return out


def gen_sweep(
    f_start: float, f_end: float, duration: float, sample_rate: int = SAMPLE_RATE
) -> list[float]:
    """Linear frequency sweep, phase-accumulated so there is no phase discontinuity."""
    n = int(round(duration * sample_rate))
    out = [0.0] * n
    phase = 0.0
    for i in range(n):
        t = i / sample_rate
        frac = t / duration if duration > 0 else 0.0
        freq = f_start + (f_end - f_start) * frac
        phase += TAU * freq / sample_rate
        out[i] = math.sin(phase)
    return out


def gen_noise(duration: float, sample_rate: int = SAMPLE_RATE, seed: int = 0) -> list[float]:
    rnd = random.Random(seed)
    n = int(round(duration * sample_rate))
    return [rnd.uniform(-1.0, 1.0) for _ in range(n)]


def env_exp_decay(
    n: int, sample_rate: int = SAMPLE_RATE, attack: float = 0.002, tau: float = 0.05
) -> list[float]:
    """Linear attack ramp 0->1, then exponential decay towards 0."""
    out = [0.0] * n
    for i in range(n):
        t = i / sample_rate
        if attack > 0 and t < attack:
            out[i] = t / attack
        else:
            out[i] = math.exp(-(t - attack) / tau) if tau > 0 else 0.0
    return out


def env_trapezoid(
    n: int, sample_rate: int = SAMPLE_RATE, attack: float = 0.01, release: float = 0.03
) -> list[float]:
    """Linear fade in, flat sustain at 1.0, linear fade out."""
    out = [1.0] * n
    a = max(1, int(round(attack * sample_rate))) if attack > 0 else 0
    r = max(1, int(round(release * sample_rate))) if release > 0 else 0
    for i in range(min(a, n)):
        out[i] = i / a
    for i in range(min(r, n)):
        idx = n - 1 - i
        out[idx] = min(out[idx], i / r)
    return out


def mul(a: list[float], b: list[float]) -> list[float]:
    return [x * y for x, y in zip(a, b)]


def mix(*layers: list[float]) -> list[float]:
    n = max(len(layer) for layer in layers)
    out = [0.0] * n
    for layer in layers:
        for i, v in enumerate(layer):
            out[i] += v
    return out


def pluck_grain(
    freq: float,
    tau: float = 0.05,
    attack: float = 0.002,
    amp: float = 1.0,
    grain_len: float = 0.3,
    harmonic2: float = 0.0,
    sample_rate: int = SAMPLE_RATE,
) -> list[float]:
    """A single self-contained plucked/bell note: starts at 0, decays to ~0."""
    n = int(round(grain_len * sample_rate))
    env = env_exp_decay(n, sample_rate, attack=attack, tau=tau)
    out = [0.0] * n
    for i in range(n):
        t = i / sample_rate
        val = math.sin(TAU * freq * t)
        if harmonic2:
            val += harmonic2 * math.sin(TAU * 2.0 * freq * t)
        out[i] = val * env[i] * amp
    return out


def add_grain_clip(buf: list[float], grain: list[float], onset_sample: int) -> None:
    """Mix `grain` into `buf` at `onset_sample`, dropping any part past the end."""
    n = len(buf)
    for i, s in enumerate(grain):
        idx = onset_sample + i
        if 0 <= idx < n:
            buf[idx] += s


def add_grain_wrap(buf: list[float], grain: list[float], onset_sample: int) -> None:
    """Mix `grain` into `buf`, wrapping any overflow around to the start.

    This is what makes the BGM loop mathematically seamless: a note near the
    end of the loop whose decay tail would spill past the loop point is
    exactly the same tail that would appear at the start of the buffer on
    the next repetition, so wrapping it there reproduces true periodic
    playback instead of truncating (== clicking) the tail.
    """
    n = len(buf)
    for i, s in enumerate(grain):
        idx = (onset_sample + i) % n
        buf[idx] += s


def normalize(samples: list[float], peak: float = 0.9) -> list[float]:
    m = max((abs(x) for x in samples), default=0.0)
    if m == 0.0:
        return list(samples)
    scale = peak / m
    return [x * scale for x in samples]


def fade_edges(samples: list[float], fade_in_ms: float = 1.0, fade_out_ms: float = 3.0) -> list[float]:
    """Force the first/last few ms to taper linearly to exact 0 (click guard)."""
    out = list(samples)
    n = len(out)
    fi = int(round(fade_in_ms / 1000.0 * SAMPLE_RATE))
    fo = int(round(fade_out_ms / 1000.0 * SAMPLE_RATE))
    for i in range(min(fi, n)):
        out[i] *= i / fi if fi > 0 else 1.0
    for i in range(min(fo, n)):
        idx = n - 1 - i
        out[idx] *= i / fo if fo > 0 else 1.0
    return out


def finalize_sfx(
    samples: list[float], peak: float = 0.85, fade_in_ms: float = 1.0, fade_out_ms: float = 3.0
) -> list[float]:
    """Standard finishing pass for one-shot SFX: normalize, then hard zero the edges."""
    return fade_edges(normalize(samples, peak), fade_in_ms, fade_out_ms)


# ---------------------------------------------------------------------------
# WAV writing / analysis
# ---------------------------------------------------------------------------


def write_wav(path: Path, samples: list[float], sample_rate: int = SAMPLE_RATE) -> None:
    frames = bytearray()
    max_int = (2 ** (BIT_DEPTH - 1)) - 1
    for x in samples:
        clamped = max(-1.0, min(1.0, x))
        frames += struct.pack("<h", int(round(clamped * max_int)))
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(BIT_DEPTH // 8)
        w.setframerate(sample_rate)
        w.writeframes(bytes(frames))


def analyze(samples: list[float], sample_rate: int = SAMPLE_RATE) -> dict:
    n = len(samples)
    peak = max((abs(x) for x in samples), default=0.0)
    rms = math.sqrt(sum(x * x for x in samples) / n) if n else 0.0
    edge_n = max(1, int(0.002 * sample_rate))  # ~2ms boundary window
    head = samples[:edge_n]
    tail = samples[-edge_n:]
    boundary_gap = max(abs(head[0]), abs(tail[-1])) if samples else 0.0
    return {
        "duration_s": n / sample_rate if sample_rate else 0.0,
        "peak": peak,
        "rms": rms,
        "clipping": peak > 1.0,
        "boundary_gap": boundary_gap,
    }


# ---------------------------------------------------------------------------
# BGM: bgm_main.wav -- 16s seamless loop, I-vi-IV-V arpeggio
# ---------------------------------------------------------------------------


def gen_bgm_main() -> list[float]:
    bpm = 120.0
    beat = 60.0 / bpm  # 0.5s
    sixteenth = beat / 4.0  # 0.125s
    beats_per_bar = 4
    bars_per_chord = 2
    slots_per_chord = beats_per_bar * bars_per_chord * 4  # 32
    chord_duration = slots_per_chord * sixteenth  # 4.0s
    n_chords = 4
    loop_len = chord_duration * n_chords  # 16.0s
    n_samples = int(round(loop_len * SAMPLE_RATE))

    # I - vi - IV - V in C major, arpeggio notes as semitone offsets from A4.
    arpeggios = [
        [-9, -5, -2, 3],  # C major: C4 E4 G4 C5
        [-12, -9, -5, 0],  # A minor: A3 C4 E4 A4
        [-16, -12, -9, -4],  # F major: F3 A3 C4 F4
        [-14, -10, -7, -2],  # G major: G3 B3 D4 G4
    ]
    bass_notes = [-21, -24, -28, -26]  # C3, A2, F2, G2

    buf = [0.0] * n_samples

    for c in range(n_chords):
        chord_start = c * chord_duration
        arp = arpeggios[c]
        for slot in range(slots_per_chord):
            onset_t = chord_start + slot * sixteenth
            note = arp[slot % 4]
            freq = freq_from_semitone(note)
            grain = pluck_grain(
                freq, tau=0.05, attack=0.002, amp=0.42, grain_len=0.35, harmonic2=0.18
            )
            add_grain_wrap(buf, grain, int(round(onset_t * SAMPLE_RATE)) % n_samples)

        bass_freq = freq_from_semitone(bass_notes[c])
        for bar in range(bars_per_chord):
            onset_t = chord_start + bar * (beat * beats_per_bar)
            grain = pluck_grain(
                bass_freq, tau=0.55, attack=0.006, amp=0.34, grain_len=1.9, harmonic2=0.05
            )
            add_grain_wrap(buf, grain, int(round(onset_t * SAMPLE_RATE)) % n_samples)

    return normalize(buf, 0.85)


# ---------------------------------------------------------------------------
# SFX generators
# ---------------------------------------------------------------------------


def gen_sfx_tick() -> list[float]:
    dur = 0.08
    n = int(round(dur * SAMPLE_RATE))
    click = mul(gen_noise(dur, seed=1), env_exp_decay(n, attack=0.0003, tau=0.004))
    punch = mul(gen_tone(150.0, dur), env_exp_decay(n, attack=0.001, tau=0.02))
    out = mix([0.55 * v for v in click], [0.65 * v for v in punch])
    return finalize_sfx(out, peak=0.85, fade_in_ms=0.3, fade_out_ms=2.0)


def gen_sfx_countdown() -> list[float]:
    dur = 0.15
    n = int(round(dur * SAMPLE_RATE))
    tone = gen_tone(220.0, dur, harmonic2=0.15)  # A3, low beep
    env = env_trapezoid(n, attack=0.008, release=0.06)
    out = mul(tone, env)
    return finalize_sfx(out, peak=0.85, fade_in_ms=1.0, fade_out_ms=3.0)


def gen_sfx_go() -> list[float]:
    dur = 0.3
    n = int(round(dur * SAMPLE_RATE))
    tone = gen_sweep(700.0, 920.0, dur)  # bright rising "go" beep
    tone = mix(tone, [0.15 * v for v in gen_tone(920.0 * 2, dur)])
    env = env_trapezoid(n, attack=0.01, release=0.09)
    out = mul(tone, env)
    return finalize_sfx(out, peak=0.85, fade_in_ms=1.0, fade_out_ms=4.0)


def gen_sfx_cut() -> list[float]:
    dur = 0.4
    n = int(round(dur * SAMPLE_RATE))
    noise_part = mul(gen_noise(dur, seed=2), env_exp_decay(n, attack=0.0005, tau=0.035))
    sweep_part = mul(gen_sweep(1400.0, 180.0, dur), env_exp_decay(n, attack=0.001, tau=0.15))
    out = mix([0.5 * v for v in noise_part], [0.6 * v for v in sweep_part])
    return finalize_sfx(out, peak=0.9, fade_in_ms=0.3, fade_out_ms=4.0)


def gen_sfx_offseam() -> list[float]:
    dur = 0.2
    n = int(round(dur * SAMPLE_RATE))
    square = gen_tone(110.0, dur, wave_shape="square")
    tremolo = [0.6 + 0.4 * math.sin(TAU * 35.0 * (i / SAMPLE_RATE)) for i in range(n)]
    noise = gen_noise(dur, seed=3)
    buzzer = [0.85 * (square[i] * tremolo[i]) + 0.15 * noise[i] for i in range(n)]
    env = env_trapezoid(n, attack=0.005, release=0.05)
    out = mul(buzzer, env)
    return finalize_sfx(out, peak=0.85, fade_in_ms=0.5, fade_out_ms=3.0)


def gen_sfx_speed_up() -> list[float]:
    dur = 0.12
    n = int(round(dur * SAMPLE_RATE))
    tone = gen_sweep(420.0, 900.0, dur)
    env = env_trapezoid(n, attack=0.005, release=0.035)
    out = mul(tone, env)
    return finalize_sfx(out, peak=0.85, fade_in_ms=0.5, fade_out_ms=2.0)


def gen_sfx_speed_down() -> list[float]:
    dur = 0.12
    n = int(round(dur * SAMPLE_RATE))
    tone = gen_sweep(900.0, 420.0, dur)
    env = env_trapezoid(n, attack=0.005, release=0.035)
    out = mul(tone, env)
    return finalize_sfx(out, peak=0.85, fade_in_ms=0.5, fade_out_ms=2.0)


def gen_sfx_finish() -> list[float]:
    dur = 0.8
    n_total = int(round(dur * SAMPLE_RATE))
    freqs = [freq_from_semitone(s) for s in (3, 7, 10)]  # C5 E5 G5 rising arpeggio
    note_dur = dur / 3.0
    buf = [0.0] * n_total
    for i, f in enumerate(freqs):
        onset_t = i * note_dur
        grain = pluck_grain(
            f, tau=0.18, attack=0.004, amp=0.75, grain_len=dur - onset_t, harmonic2=0.2
        )
        add_grain_clip(buf, grain, int(round(onset_t * SAMPLE_RATE)))
    return finalize_sfx(buf, peak=0.9, fade_in_ms=1.0, fade_out_ms=8.0)


def gen_sfx_record() -> list[float]:
    dur = 1.2
    n_total = int(round(dur * SAMPLE_RATE))
    # C5 E5 G5 C6 bright 4-note fanfare, last note rings out longer.
    freqs = [freq_from_semitone(s) for s in (3, 7, 10, 15)]
    onsets = [0.0, 0.25, 0.5, 0.75]
    taus = [0.15, 0.15, 0.15, 0.45]
    amps = [0.65, 0.65, 0.7, 0.85]
    buf = [0.0] * n_total
    for f, onset_t, tau, amp in zip(freqs, onsets, taus, amps):
        grain = pluck_grain(
            f, tau=tau, attack=0.003, amp=amp, grain_len=dur - onset_t, harmonic2=0.35
        )
        add_grain_clip(buf, grain, int(round(onset_t * SAMPLE_RATE)))
    return finalize_sfx(buf, peak=0.9, fade_in_ms=1.0, fade_out_ms=10.0)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

GENERATORS = [
    ("bgm_main.wav", gen_bgm_main, True),
    ("sfx_tick.wav", gen_sfx_tick, False),
    ("sfx_countdown.wav", gen_sfx_countdown, False),
    ("sfx_go.wav", gen_sfx_go, False),
    ("sfx_cut.wav", gen_sfx_cut, False),
    ("sfx_offseam.wav", gen_sfx_offseam, False),
    ("sfx_speed_up.wav", gen_sfx_speed_up, False),
    ("sfx_speed_down.wav", gen_sfx_speed_down, False),
    ("sfx_finish.wav", gen_sfx_finish, False),
    ("sfx_record.wav", gen_sfx_record, False),
]


def main() -> None:
    print(f"Output dir: {OUTPUT_DIR}")
    print(f"{'file':<20} {'dur(s)':>8} {'peak':>8} {'rms':>8} {'clip?':>6} {'boundary':>10}")
    print("-" * 66)

    any_clipping = False
    for filename, generator, is_loop in GENERATORS:
        samples = generator()
        stats = analyze(samples)
        write_wav(OUTPUT_DIR / filename, samples)
        tag = " (loop)" if is_loop else ""
        print(
            f"{filename:<20} {stats['duration_s']:>8.3f} {stats['peak']:>8.3f} "
            f"{stats['rms']:>8.4f} {str(stats['clipping']):>6} {stats['boundary_gap']:>10.5f}{tag}"
        )
        if stats["clipping"]:
            any_clipping = True

    print("-" * 66)
    if any_clipping:
        print("WARNING: one or more files exceeded full scale (peak > 1.0).")
    else:
        print("OK: no clipping detected in any generated file.")
    print(
        "boundary = max(|first sample|, |last sample|) over each file; "
        "should be near 0 for a click-free start/end (and, for bgm_main.wav, a click-free loop)."
    )


if __name__ == "__main__":
    main()
