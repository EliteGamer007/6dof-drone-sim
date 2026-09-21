"""Synthesise the simulator's UI / alarm audio as 16-bit WAVs.

Everything here is generated from scratch, so there is nothing to license and
nothing to attribute. Run:  python tools/make_audio.py
"""

from __future__ import annotations

import os
import struct
import wave

import numpy as np

SR = 44100
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "audio")

rng = np.random.default_rng(20260818)


# ----------------------------------------------------------------- helpers

def t(dur: float) -> np.ndarray:
    return np.linspace(0.0, dur, int(SR * dur), endpoint=False)


def env_ad(n: int, attack: float, decay: float, curve: float = 2.0) -> np.ndarray:
    """Attack/decay envelope over `n` samples, both given as fractions."""
    a = max(int(n * attack), 1)
    d = max(n - a, 1)
    return np.concatenate([
        np.linspace(0.0, 1.0, a) ** 0.6,
        (np.linspace(1.0, 0.0, d) ** curve),
    ])[:n]


def tone(freq: float, dur: float, kind: str = "sine") -> np.ndarray:
    x = t(dur)
    if kind == "square":
        return np.sign(np.sin(2 * np.pi * freq * x))
    if kind == "saw":
        return 2.0 * (freq * x - np.floor(0.5 + freq * x))
    return np.sin(2 * np.pi * freq * x)


def sweep(f0: float, f1: float, dur: float) -> np.ndarray:
    x = t(dur)
    k = (f1 - f0) / max(dur, 1e-6)
    return np.sin(2 * np.pi * (f0 * x + 0.5 * k * x * x))


def noise(dur: float) -> np.ndarray:
    return rng.uniform(-1.0, 1.0, int(SR * dur))


def lowpass(sig: np.ndarray, cutoff: float, order: int = 4) -> np.ndarray:
    """Simple cascaded one-pole low-pass - plenty for texture beds."""
    a = np.exp(-2.0 * np.pi * cutoff / SR)
    out = sig.astype(np.float64)
    for _ in range(order):
        y = np.empty_like(out)
        acc = 0.0
        for i in range(out.size):
            acc = (1 - a) * out[i] + a * acc
            y[i] = acc
        out = y
    return out


def lowpass_fast(sig: np.ndarray, cutoff: float, order: int = 4) -> np.ndarray:
    """Frequency-domain low-pass; far quicker than the sample loop above."""
    n = sig.size
    spec = np.fft.rfft(sig)
    freqs = np.fft.rfftfreq(n, 1.0 / SR)
    resp = 1.0 / (1.0 + (freqs / max(cutoff, 1.0)) ** (2 * order)) ** 0.5
    return np.fft.irfft(spec * resp, n)


def highpass_fast(sig: np.ndarray, cutoff: float, order: int = 4) -> np.ndarray:
    n = sig.size
    spec = np.fft.rfft(sig)
    freqs = np.fft.rfftfreq(n, 1.0 / SR)
    with np.errstate(divide="ignore"):
        resp = 1.0 / (1.0 + (max(cutoff, 1.0) / np.maximum(freqs, 1e-6)) ** (2 * order)) ** 0.5
    return np.fft.irfft(spec * resp, n)


def normalise(sig: np.ndarray, peak: float = 0.92) -> np.ndarray:
    m = float(np.max(np.abs(sig))) or 1.0
    return sig / m * peak


def fade_edges(sig: np.ndarray, ms: float = 4.0) -> np.ndarray:
    n = max(int(SR * ms / 1000.0), 1)
    if sig.size < 2 * n:
        return sig
    out = sig.copy()
    out[:n] *= np.linspace(0.0, 1.0, n)
    out[-n:] *= np.linspace(1.0, 0.0, n)
    return out


def crossfade_loop(sig: np.ndarray, ms: float = 120.0) -> np.ndarray:
    """Make a seamless loop by crossfading the tail over the head."""
    n = min(int(SR * ms / 1000.0), sig.size // 3)
    head, tail = sig[:n], sig[-n:]
    ramp = np.linspace(0.0, 1.0, n)
    blended = tail * (1 - ramp) + head * ramp
    return np.concatenate([blended, sig[n:-n]])


def write(name: str, sig: np.ndarray, stereo: bool = False) -> None:
    os.makedirs(OUT, exist_ok=True)
    data = normalise(np.asarray(sig, dtype=np.float64))
    pcm = np.clip(data, -1.0, 1.0)
    pcm = (pcm * 32767.0).astype("<i2")
    path = os.path.join(OUT, name)
    with wave.open(path, "wb") as w:
        w.setnchannels(2 if stereo else 1)
        w.setsampwidth(2)
        w.setframerate(SR)
        if stereo:
            inter = np.empty(pcm.size * 2, dtype="<i2")
            inter[0::2] = pcm
            inter[1::2] = np.roll(pcm, 311)  # tiny decorrelation for width
            w.writeframes(inter.tobytes())
        else:
            w.writeframes(pcm.tobytes())
    print(f"  {name:<22} {os.path.getsize(path)/1024:7.1f} KB")


# ------------------------------------------------------------------ sounds

def gas_alarm() -> np.ndarray:
    """Short, piercing two-tone chirp - the classic 4-gas detector alarm."""
    a = tone(2730, 0.055, "square") * env_ad(int(SR * 0.055), 0.02, 0.98, 1.4)
    b = tone(3480, 0.055, "square") * env_ad(int(SR * 0.055), 0.02, 0.98, 1.4)
    gap = np.zeros(int(SR * 0.02))
    sig = np.concatenate([a, gap, b])
    return fade_edges(sig * 0.8, 2.0)


def critical_alarm() -> np.ndarray:
    parts = []
    for _ in range(3):
        w = sweep(1500, 950, 0.13) * env_ad(int(SR * 0.13), 0.05, 0.95, 1.2)
        parts += [w, np.zeros(int(SR * 0.05))]
    return fade_edges(np.concatenate(parts), 3.0)


def proximity_blip() -> np.ndarray:
    n = int(SR * 0.04)
    sig = tone(1180, 0.04) * env_ad(n, 0.05, 0.95, 3.0)
    return fade_edges(sig, 2.0)


def detect_ping() -> np.ndarray:
    """Sonar-style contact ping with a short tail."""
    dur = 0.7
    n = int(SR * dur)
    body = (
        tone(880, dur) * 0.6
        + tone(1320, dur) * 0.3
        + tone(1760, dur) * 0.15
    )
    tail = np.exp(-np.linspace(0, 9, n))
    strike = env_ad(n, 0.004, 0.996, 1.0)
    return fade_edges(body * tail * strike, 3.0)


def ui_click() -> np.ndarray:
    n = int(SR * 0.025)
    sig = highpass_fast(noise(0.025), 1800) * env_ad(n, 0.02, 0.98, 4.0)
    return fade_edges(sig * 0.5, 1.5)


def ui_switch() -> np.ndarray:
    dur = 0.16
    n = int(SR * dur)
    sig = sweep(420, 1400, dur) * env_ad(n, 0.1, 0.9, 1.8)
    sig += highpass_fast(noise(dur), 2600) * env_ad(n, 0.02, 0.98, 5.0) * 0.25
    return fade_edges(sig, 3.0)


def shutter() -> np.ndarray:
    def clack(dur: float, cutoff: float) -> np.ndarray:
        n = int(SR * dur)
        return lowpass_fast(noise(dur), cutoff) * env_ad(n, 0.01, 0.99, 6.0)

    return fade_edges(np.concatenate([
        clack(0.035, 5200),
        np.zeros(int(SR * 0.045)),
        clack(0.05, 3400) * 0.8,
    ]), 2.0)


def marker_drop() -> np.ndarray:
    a = tone(1046, 0.07) * env_ad(int(SR * 0.07), 0.05, 0.95, 2.0)
    b = tone(1568, 0.11) * env_ad(int(SR * 0.11), 0.04, 0.96, 2.0)
    return fade_edges(np.concatenate([a, np.zeros(int(SR * 0.02)), b]), 3.0)


def low_battery() -> np.ndarray:
    parts = []
    for f in (1200, 950, 720):
        n = int(SR * 0.16)
        parts += [tone(f, 0.16, "square") * env_ad(n, 0.04, 0.96, 1.6) * 0.7,
                  np.zeros(int(SR * 0.06))]
    return fade_edges(np.concatenate(parts), 4.0)


def impact() -> np.ndarray:
    dur = 0.35
    n = int(SR * dur)
    thud = lowpass_fast(noise(dur), 260) * env_ad(n, 0.005, 0.995, 3.0)
    ring = tone(150, dur) * env_ad(n, 0.002, 0.998, 5.0) * 0.4
    crack = highpass_fast(noise(0.06), 3000) * env_ad(int(SR * 0.06), 0.01, 0.99, 6.0)
    sig = thud + ring
    sig[: crack.size] += crack * 0.5
    return fade_edges(sig, 3.0)


def mission_complete() -> np.ndarray:
    parts = []
    for i, f in enumerate((523.25, 659.25, 783.99, 1046.5)):
        dur = 0.5 if i == 3 else 0.16
        n = int(SR * dur)
        v = (tone(f, dur) + 0.4 * tone(f * 2, dur)) * env_ad(n, 0.02, 0.98, 2.2)
        parts.append(v * (0.9 if i == 3 else 0.6))
    # let the notes overlap slightly
    out = np.zeros(int(SR * 1.1))
    pos = 0
    for i, p in enumerate(parts):
        out[pos:pos + p.size] += p
        pos += int(SR * (0.13 if i < 3 else 0.0))
    return fade_edges(out, 5.0)


def wind_loop() -> np.ndarray:
    dur = 6.0
    base = lowpass_fast(noise(dur), 520, 3)
    gust = lowpass_fast(noise(dur), 0.7, 2)
    gust = (gust - gust.min()) / (float(np.ptp(gust)) or 1.0) * 0.75 + 0.35
    whistle = lowpass_fast(highpass_fast(noise(dur), 900, 3), 2400, 2) * 0.22
    sig = base * gust + whistle * gust
    return crossfade_loop(sig, 400.0)


def rotor_loop() -> np.ndarray:
    """Quadcopter bed: blade-pass fundamental plus harmonics and motor whine."""
    dur = 1.0
    x = t(dur)
    blade = 118.0  # Hz blade-pass; pitch-shifted at runtime by thrust
    sig = np.zeros_like(x)
    for h, amp in ((1, 1.0), (2, 0.55), (3, 0.3), (4, 0.18), (6, 0.1)):
        detune = 1.0 + 0.0025 * h
        sig += amp * np.sin(2 * np.pi * blade * h * detune * x)
    # four motors slightly out of sync
    for offset in (0.997, 1.004, 1.009):
        sig += 0.35 * np.sin(2 * np.pi * blade * offset * x)
    whine = 0.18 * np.sin(2 * np.pi * 2360 * x) * (0.7 + 0.3 * np.sin(2 * np.pi * 7 * x))
    air = lowpass_fast(highpass_fast(noise(dur), 700, 2), 5200, 2) * 0.35
    sig = sig * 0.35 + whine + air
    return crossfade_loop(sig, 60.0)


def gas_hiss() -> np.ndarray:
    """Pressurised leak. Spatialised in-world, so the pilot can fly the hiss
    back to the valve it is coming from."""
    dur = 4.0
    n = int(SR * dur)
    core = highpass_fast(noise(dur), 2200, 3)
    body = lowpass_fast(highpass_fast(noise(dur), 700, 2), 5200, 2) * 0.55
    flutter = 0.8 + 0.2 * np.sin(2 * np.pi * 3.1 * t(dur)) + 0.1 * lowpass_fast(noise(dur), 6, 2)
    sig = (core * 0.7 + body) * flutter[:n]
    return crossfade_loop(sig, 250.0)


def fire_crackle() -> np.ndarray:
    dur = 5.0
    n = int(SR * dur)
    roar = lowpass_fast(noise(dur), 380, 3) * 0.8
    rumble = lowpass_fast(noise(dur), 90, 2) * 0.5
    pops = np.zeros(n)
    for _ in range(90):
        i = int(rng.integers(0, n - 2000))
        ln = int(rng.integers(220, 1400))
        burst = highpass_fast(rng.uniform(-1.0, 1.0, ln), 1500)
        pops[i:i + ln] += burst * env_ad(ln, 0.01, 0.99, 5.0) * rng.uniform(0.25, 1.0)
    sig = roar + rumble + pops * 0.7
    return crossfade_loop(sig, 300.0)


def tap_signal() -> np.ndarray:
    """Three knocks on debris - the 'I am here' signal rescue teams listen for.
    Chosen over any human voice so the scene stays a respectful reconstruction
    rather than a re-enactment."""
    def knock() -> np.ndarray:
        d = 0.09
        nn = int(SR * d)
        body = lowpass_fast(noise(d), 900, 2) * env_ad(nn, 0.004, 0.996, 7.0)
        ring = tone(310, d) * env_ad(nn, 0.002, 0.998, 9.0) * 0.5
        return body + ring

    gap = np.zeros(int(SR * 0.17))
    long_gap = np.zeros(int(SR * 2.3))
    return fade_edges(np.concatenate([knock(), gap, knock(), gap, knock(), long_gap]), 4.0)


SOUNDS = {
    "gas_hiss.wav": (gas_hiss, False),
    "fire_crackle.wav": (fire_crackle, False),
    "tap_signal.wav": (tap_signal, False),
    "alarm_gas.wav": (gas_alarm, False),
    "alarm_critical.wav": (critical_alarm, False),
    "proximity.wav": (proximity_blip, False),
    "detect_ping.wav": (detect_ping, False),
    "ui_click.wav": (ui_click, False),
    "ui_switch.wav": (ui_switch, False),
    "shutter.wav": (shutter, False),
    "marker_drop.wav": (marker_drop, False),
    "low_battery.wav": (low_battery, False),
    "impact.wav": (impact, False),
    "mission_complete.wav": (mission_complete, False),
    "wind_loop.wav": (wind_loop, True),
    "rotor_loop.wav": (rotor_loop, False),
}


def main() -> None:
    print(f"Writing {len(SOUNDS)} sounds to {os.path.relpath(OUT, ROOT)}")
    for name, (fn, stereo) in SOUNDS.items():
        write(name, fn(), stereo)
    print("done")


if __name__ == "__main__":
    main()
