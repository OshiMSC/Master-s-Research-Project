"""
Validates the sequential 3-band sweep detector against:
  1. The REAL beacon signal (regenerated using the exact same
     parameters as generate_chirp.py)
  2. Realistic false-positive candidates (voice, knock, white noise,
     wind-like noise, a single ascending tone that ISN'T 3 separate
     bands)

Simulates real-time chunked processing (not a single offline FFT),
since the sequence-tracking logic depends on state evolving chunk by
chunk over time, exactly as the live detector does.
"""

import numpy as np
from scipy.signal import chirp as scipy_chirp
from chirp_detector import (
    band_energy_ratio, BANDS, SAMPLE_RATE, CHUNK_SIZE,
    DOMINANCE_RATIO, RMS_GATE
)


def generate_real_beacon(duration_s=3.0, amplitude=0.9):
    """Regenerates the real beacon using generate_chirp.py's exact
    parameters: 3 bands, 0.3s each, 0.6s silence, repeated."""
    sr = SAMPLE_RATE
    segment_duration = 0.3
    silence_duration = 0.6

    def make_segment(f0, f1, dur):
        t = np.linspace(0, dur, int(sr * dur), endpoint=False)
        sig = scipy_chirp(t, f0=f0, f1=f1, t1=dur, method='linear')
        window = np.hanning(len(sig))
        return (sig * window).astype(np.float64)

    segments = [make_segment(b[0], b[1], segment_duration) for b in
                [(1000, 2000), (2000, 3000), (3000, 4000)]]
    pulse = np.concatenate(segments)
    silence = np.zeros(int(sr * silence_duration))
    cycle = np.concatenate([pulse, silence])

    n_cycles = int(np.ceil(duration_s / (len(cycle) / sr))) + 1
    full = np.tile(cycle, n_cycles)
    full = (full / np.max(np.abs(full))) * amplitude
    return full[:int(duration_s * sr)]


def simulate_chunked_detection(signal, label, attenuation=1.0, noise_level=0.0,
                                 add_to_signal=None):
    """Runs the EXACT same chunk-by-chunk logic as ChirpDetector._listen_loop
    (minus pyaudio/threading), to validate sequence-tracking behavior."""
    rng = np.random.default_rng(123)
    sig = signal * attenuation
    if noise_level > 0:
        sig = sig + rng.normal(0, noise_level, len(sig))
    if add_to_signal is not None:
        n = min(len(sig), len(add_to_signal))
        sig[:n] = sig[:n] + add_to_signal[:n]

    n_chunks = len(sig) // CHUNK_SIZE
    band_history = []  # (chunk_index, dominant_band_or_None)
    detections = []

    from collections import deque
    history = deque(maxlen=24)

    for c in range(n_chunks):
        chunk = sig[c * CHUNK_SIZE:(c + 1) * CHUNK_SIZE]
        rms = float(np.sqrt(np.mean(chunk ** 2)))

        if rms < RMS_GATE:
            history.append((c, None))
            continue

        ratios = [band_energy_ratio(chunk, SAMPLE_RATE, b) for b in BANDS]
        best_idx = int(np.argmax(ratios))
        dominant = best_idx if ratios[best_idx] >= DOMINANCE_RATIO else None
        history.append((c, dominant))

        # Inline the same sequence-check logic as _check_sequence,
        # using chunk index instead of wall-clock time (equivalent
        # since chunks are evenly spaced).
        hist_list = list(history)
        idx_band0 = None
        for i, (idx, band) in enumerate(hist_list):
            if band == 0:
                idx_band0 = i
        if idx_band0 is None:
            continue
        idx_band1 = None
        for i in range(idx_band0 + 1, len(hist_list)):
            idx, band = hist_list[i]
            if band == 1:
                idx_band1 = i
                break
            if band == 0:
                idx_band0 = i
        if idx_band1 is None:
            continue
        idx_band2 = None
        broke = False
        for i in range(idx_band1 + 1, len(hist_list)):
            idx, band = hist_list[i]
            if band == 2:
                idx_band2 = i
                break
            if band == 0:
                broke = True
                break
        if broke or idx_band2 is None:
            continue

        chunk_dur = CHUNK_SIZE / SAMPLE_RATE
        elapsed = (hist_list[idx_band2][0] - hist_list[idx_band0][0]) * chunk_dur
        if 0.15 <= elapsed <= 2.25:
            detections.append(c)
            history.clear()

    verdict = "DETECTED" if detections else "no detection"
    print(f"{label:55s} -> {verdict} ({len(detections)} trigger(s) "
          f"in {n_chunks} chunks, {n_chunks*CHUNK_SIZE/SAMPLE_RATE:.1f}s)")
    return len(detections) > 0


print("=" * 75)
print("SEQUENTIAL 3-BAND SWEEP DETECTOR — VALIDATION")
print("=" * 75)

beacon = generate_real_beacon(duration_s=3.0)

# 1. Clean beacon, full strength
simulate_chunked_detection(beacon, "1. Clean real beacon (full strength)")

# 2. Beacon attenuated (across-room simulation)
simulate_chunked_detection(beacon, "2. Beacon attenuated 10x (across room)",
                            attenuation=0.1)

# 3. Beacon attenuated + realistic background noise
simulate_chunked_detection(beacon, "3. Beacon attenuated 5x + noise",
                            attenuation=0.2, noise_level=0.02)

# 4. Beacon very faint
simulate_chunked_detection(beacon, "4. Beacon very faint (30x attenuation)",
                            attenuation=1.0/30)

# 5. Voice-like harmonics (should NOT detect)
rng = np.random.default_rng(7)
t = np.arange(int(SAMPLE_RATE * 3.0)) / SAMPLE_RATE
voice = sum(np.sin(2*np.pi*f*t) * (1.0/i) for i, f in
            enumerate([180, 360, 720, 1440, 2880, 3500], start=1))
voice = voice / np.max(np.abs(voice)) * 0.6
simulate_chunked_detection(voice, "5. Voice-like harmonics (loud)")

# 6. Single ascending tone sweep 1000Hz->4000Hz CONTINUOUSLY over 0.9s
#    (tests that a single smooth sweep, not 3 distinct bands, doesn't
#    accidentally also trigger — it actually SHOULD trigger here since
#    it passes through all 3 band ranges in order, which is a fair and
#    expected behavior, not a false positive, since it has the same
#    sequential signature)
t_single = np.linspace(0, 0.9, int(SAMPLE_RATE * 0.9), endpoint=False)
single_sweep = scipy_chirp(t_single, f0=1000, f1=4000, t1=0.9, method='linear')
single_sweep = np.tile(np.concatenate([single_sweep, np.zeros(int(SAMPLE_RATE*0.6))]), 3)
simulate_chunked_detection(single_sweep, "6. Single continuous 1-4kHz sweep (expected to ALSO detect - same sequential signature)")

# 7. Random knocking/impacts (broadband transients, should NOT detect)
impacts = np.zeros(int(SAMPLE_RATE * 3.0))
rng2 = np.random.default_rng(99)
for knock_time in [0.5, 1.2, 2.0, 2.7]:
    idx = int(knock_time * SAMPLE_RATE)
    dur = int(0.05 * SAMPLE_RATE)
    decay = np.exp(-np.arange(dur) / (0.01 * SAMPLE_RATE))
    impacts[idx:idx+dur] += rng2.normal(0, 1, dur) * decay * 0.8
simulate_chunked_detection(impacts, "7. Random knocks/impacts")

# 8. Loud white noise throughout (should NOT detect)
white = rng.normal(0, 1, int(SAMPLE_RATE * 3.0)) * 0.4
simulate_chunked_detection(white, "8. Loud white noise (3s)")

# 9. Wind-like low frequency noise (should NOT detect)
wind_base = rng.normal(0, 1, int(SAMPLE_RATE * 3.0))
wind = np.cumsum(wind_base)
wind = (wind - np.mean(wind))
wind = wind / np.max(np.abs(wind)) * 0.5
simulate_chunked_detection(wind, "9. Wind-like low-frequency noise")

# 10. Bands played in WRONG order (3->2->1, reversed) - should NOT detect
def make_segment(f0, f1, dur):
    t = np.linspace(0, dur, int(SAMPLE_RATE * dur), endpoint=False)
    sig = scipy_chirp(t, f0=f0, f1=f1, t1=dur, method='linear')
    return (sig * np.hanning(len(sig))).astype(np.float64)
reversed_segments = [make_segment(3000,4000,0.3), make_segment(2000,3000,0.3), make_segment(1000,2000,0.3)]
reversed_pulse = np.concatenate(reversed_segments + [np.zeros(int(SAMPLE_RATE*0.6))])
reversed_signal = np.tile(reversed_pulse, 3)
simulate_chunked_detection(reversed_signal, "10. Bands in REVERSED order (3->2->1, should NOT trigger forward sequence)")

print("=" * 75)