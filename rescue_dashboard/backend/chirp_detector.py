"""
ResQNet — Chirp Beacon Detector (3-Band Sequential Sweep Engine)
====================================================================
Detects the REAL multi_band_chirp.wav beacon: a 3-band sequential
sweep through 1-2kHz, then 2-3kHz, then 3-4kHz (0.3s each, ~0.9s
total), followed by 0.6s silence, repeated 10 times. See
generate_chirp.py for the authoritative source of this design.

== WHY THIS VERSION REPLACES THE PREVIOUS DUAL-TONE VERSION ==
Two earlier engines were built against specifications for this beacon
that, it turns out, never matched the real WAV file:
  1. The original RMS-only engine just measured loudness.
  2. A later dual-tone Goertzel engine checked for simultaneous,
     fixed energy at exactly 3200Hz and 4500Hz.
Both were reasonable given the documentation/comments available at the
time (chirp_service.dart's comment literally says "3200+4500Hz
tones"), but direct inspection of the real WAV file
(inspect_chirp_wav.py) proved its actual dominant content sits at
1500/2500/3500Hz — the midpoints of three SWEEPING bands, not two
fixed tones. The dual-tone engine could never have worked against this
file: 4500Hz has essentially zero energy in it at all.

== THE NEW APPROACH ==
Rather than checking for a static frequency fingerprint, this engine
tracks which of the three ~1kHz-wide bands holds the most energy in
each ~93ms audio chunk (at 44100Hz / 4096-sample chunks), keeps a
short rolling history of that "dominant band" sequence, and checks
whether the history shows band 1 -> band 2 -> band 3 in order within
a time window consistent with the beacon's real 0.3s-per-band timing.
This is the noise-resilient, sequential-fingerprint design the
generator script's own notes describe ("pattern unique: YES — 3
sequential diagonals", "noise resilient: YES — partial band detection
sufficient") — actually implemented, rather than approximated by a
simpler (and, for this file, non-functional) dual-tone check.

Ordinary sounds (voice, wind, knocks, white noise) essentially never
produce a clean, repeated, correctly-timed climb through three
adjacent bands in sequence — that sequential structure IS the
fingerprint, and is what makes this resistant to false positives
without needing the bands to be narrow, fixed tones.
"""

import numpy as np
import threading
import time
from collections import deque
from datetime import datetime

try:
    import pyaudio
    PYAUDIO_AVAILABLE = True
except ImportError:
    PYAUDIO_AVAILABLE = False

# ── Audio capture settings ──────────────────────────────────────
SAMPLE_RATE  = 44100
CHUNK_SIZE   = 4096     # ~93ms per chunk at 44100Hz
CHANNELS     = 1
DEVICE_INDEX = 5        # Intel Smart Sound System Target

# ── Beacon band definitions (MUST match generate_chirp.py `bands`) ──
BANDS = [
    (1000.0, 2000.0),   # Band 1 — low
    (2000.0, 3000.0),   # Band 2 — mid
    (3000.0, 4000.0),   # Band 3 — high
]
SEGMENT_DURATION_S = 0.3   # per band, matches generator
SILENCE_DURATION_S = 0.6   # gap between pulses, matches generator
FULL_CYCLE_S = SEGMENT_DURATION_S * len(BANDS) + SILENCE_DURATION_S  # 1.5s

# ── Detection gating ─────────────────────────────────────────────
RMS_GATE = 0.0008
# A band must hold at least this fraction of total chunk energy to
# count as "dominant" for that chunk. Loose-ish on purpose: the chirp
# is a sweep, so within one ~93ms chunk the energy may itself be
# split across part of one band and bleeding into the next.
DOMINANCE_RATIO = 0.35
# How many recent chunks (history) to keep — needs to cover at least
# one full cycle (1.5s) with margin. At ~93ms/chunk, ~1.5s = ~16
# chunks; use a bit more to tolerate jitter/drift in capture timing.
HISTORY_CHUNKS = 24
# Cooldown shorter than one full cycle would re-trigger on the same
# pulse; longer than FULL_CYCLE_S avoids re-firing on the very next
# repetition before the user/rescuer has had a chance to register it.
COOLDOWN_S = max(FULL_CYCLE_S * 1.5, 2.0)
DEBUG_MODE = True


def band_energy_ratio(audio: np.ndarray, sample_rate: int, band: tuple) -> float:
    """
    Returns the fraction of this chunk's total energy that falls
    within [band[0], band[1]) Hz. Uses a straightforward FFT bin sum
    rather than Goertzel, since these are ~1000Hz-wide bands (not
    single frequencies) — a handful of FFT bins summed is the natural
    tool for "how much energy is in this range", whereas Goertzel is
    suited to checking one exact frequency.
    """
    n = len(audio)
    if n == 0:
        return 0.0
    fft_vals = np.abs(np.fft.rfft(audio))
    freqs = np.fft.rfftfreq(n, d=1.0 / sample_rate)
    total_energy = float(np.sum(fft_vals ** 2)) + 1e-12
    mask = (freqs >= band[0]) & (freqs < band[1])
    band_energy = float(np.sum(fft_vals[mask] ** 2))
    return band_energy / total_energy


class ChirpDetector:

    def __init__(self, on_chirp_detected=None):
        self.on_chirp_detected = on_chirp_detected
        self._running = False
        self._thread = None
        self._audio = None
        self._stream = None
        self._last_event_time = 0.0
        self.total_detections = 0
        self.detection_history = []
        self._device_name = 'Unknown'
        # Rolling history of (timestamp, dominant_band_index_or_None)
        self._band_history = deque(maxlen=HISTORY_CHUNKS)
        # Diagnostics for dashboard / debug overlay
        self._last_rms = 0.0
        self._last_ratios = [0.0, 0.0, 0.0]
        self._last_dominant = None

    def _open_stream(self, audio, device_idx):
        return audio.open(
            format=pyaudio.paInt16, channels=CHANNELS,
            rate=SAMPLE_RATE, input=True,
            input_device_index=device_idx,
            frames_per_buffer=CHUNK_SIZE)

    def start(self):
        if not PYAUDIO_AVAILABLE:
            print("ChirpDetector: pyaudio library missing")
            return False
        if self._running:
            return True
        try:
            self._audio = pyaudio.PyAudio()
            try:
                info = self._audio.get_device_info_by_index(DEVICE_INDEX)
                self._device_name = info['name']
            except Exception:
                print(f"ChirpDetector: Device ID {DEVICE_INDEX} inaccessible.")
                return False

            self._stream = self._open_stream(self._audio, DEVICE_INDEX)

            self._running = True
            self._thread = threading.Thread(target=self._listen_loop, daemon=True)
            self._thread.start()
            band_desc = " -> ".join(f"{b[0]:.0f}-{b[1]:.0f}Hz" for b in BANDS)
            print(f"ChirpDetector: Sequential-Sweep Engine Active "
                  f"({band_desc}, {SEGMENT_DURATION_S}s/band) ✓\n")
            return True
        except Exception as e:
            print(f"ChirpDetector: Engine failed to spin up — {e}")
            return False

    def stop(self):
        self._running = False
        try:
            if self._stream:
                self._stream.stop_stream()
                self._stream.close()
            if self._audio:
                self._audio.terminate()
        except Exception:
            pass

    def _listen_loop(self):
        chunk_count = 0
        warmup_end = time.time() + 1.0

        while self._running:
            try:
                raw = self._stream.read(CHUNK_SIZE, exception_on_overflow=False)
                audio = np.frombuffer(raw, dtype=np.int16).astype(np.float64) / 32768.0

                now = time.time()
                chunk_count += 1
                if now < warmup_end:
                    continue

                rms = float(np.sqrt(np.mean(audio ** 2)))
                self._last_rms = rms

                in_cooldown = (now - self._last_event_time) < COOLDOWN_S

                if rms < RMS_GATE:
                    # Silence is part of the expected pattern (the 0.6s
                    # gap) — record it as "no dominant band" rather than
                    # treating it as a gap that breaks the sequence.
                    self._band_history.append((now, None))
                    self._last_dominant = None
                    self._last_ratios = [0.0, 0.0, 0.0]
                    if not in_cooldown:
                        self._check_sequence(now)
                    self._maybe_log(chunk_count, rms, None, in_cooldown)
                    continue

                ratios = [band_energy_ratio(audio, SAMPLE_RATE, b) for b in BANDS]
                self._last_ratios = ratios
                best_idx = int(np.argmax(ratios))
                dominant = best_idx if ratios[best_idx] >= DOMINANCE_RATIO else None
                self._last_dominant = dominant

                self._band_history.append((now, dominant))

                if not in_cooldown:
                    self._check_sequence(now)

                self._maybe_log(chunk_count, rms, dominant, in_cooldown)

            except Exception as e:
                if self._running:
                    print(f"\nChirpDetector execution warning: {e}")
                time.sleep(0.04)

    def _check_sequence(self, now):
        """
        Looks at the rolling history for a clean climb: band 0 seen,
        THEN (later) band 1 seen, THEN (later) band 2 seen, each
        within a window consistent with the real ~0.3s/band timing
        (with generous slack for capture jitter, mic distance, and
        partial-band detection — the generator's own design goal is
        that partial detection should still work).
        """
        history = list(self._band_history)
        if len(history) < 3:
            return

        # Find the most recent occurrence of band 0, then look for
        # band 1 after it, then band 2 after that — allowing other
        # chunks (silence, None, or repeated same-band chunks) in
        # between, since a 93ms chunk grid won't align perfectly with
        # 300ms band boundaries.
        idx_band0 = None
        for i, (t, band) in enumerate(history):
            if band == 0:
                idx_band0 = i

        if idx_band0 is None:
            return

        idx_band1 = None
        for i in range(idx_band0 + 1, len(history)):
            t, band = history[i]
            if band == 1:
                idx_band1 = i
                break
            if band == 0:
                # Saw band 0 again before band 1 — restart the search
                # from this later band-0 occurrence instead.
                idx_band0 = i

        if idx_band1 is None:
            return

        idx_band2 = None
        for i in range(idx_band1 + 1, len(history)):
            t, band = history[i]
            if band == 2:
                idx_band2 = i
                break
            if band == 0:
                # A new cycle's band 0 started before band 2 of this
                # one ever appeared — treat the sequence as broken and
                # don't carry over.
                return

        if idx_band2 is None:
            return

        t0 = history[idx_band0][0]
        t2 = history[idx_band2][0]
        elapsed = t2 - t0

        # Real sequence should take roughly 2 * SEGMENT_DURATION_S to
        # go from band-0 chunk to band-2 chunk (it skips through band
        # 1 in between). Allow a generous window since chunk timing
        # isn't perfectly aligned to band boundaries and the mic may
        # catch the sweep off-center within each band.
        min_expected = SEGMENT_DURATION_S * 0.5
        max_expected = SEGMENT_DURATION_S * len(BANDS) * 2.5

        if min_expected <= elapsed <= max_expected:
            self._last_event_time = now
            # Clear history so the same physical sweep can't immediately
            # re-trigger on its own tail end before cooldown logic below
            # would otherwise prevent it.
            self._band_history.clear()
            self._trigger(elapsed)

    def _maybe_log(self, chunk_count, rms, dominant, in_cooldown):
        if not DEBUG_MODE:
            return
        if in_cooldown:
            if chunk_count % 4 == 0:
                cd = int(COOLDOWN_S - (time.time() - self._last_event_time))
                print(f"\r  RMS:{rms:.4f} band:{dominant} 🔒 MUTED [cd {cd}s]"
                      f"          ", end='', flush=True)
            return
        if dominant is not None or chunk_count % 4 == 0:
            r = self._last_ratios
            mark = f"★ BAND-{dominant}" if dominant is not None else "         "
            print(f"\r  RMS:{rms:.4f} b0:{r[0]:.2f} b1:{r[1]:.2f} b2:{r[2]:.2f} "
                  f"{mark}          ", end='', flush=True)

    def _trigger(self, sequence_elapsed_s):
        self.total_detections += 1
        event = {
            'id': int(time.time() * 1000),
            'type': 'CHIRP_BEACON',
            'timestamp': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
            'message': 'ResQNet acoustic chirp beacon detected',
            'count': self.total_detections,
            'sequence_elapsed_s': round(sequence_elapsed_s, 3),
        }
        self.detection_history.append(event)
        if len(self.detection_history) > 50:
            self.detection_history.pop(0)
        print(f"\n*** CHIRP BEACON DETECTED! *** total={self.total_detections} "
              f"sequence_time={sequence_elapsed_s:.2f}s at {event['timestamp']}")
        if self.on_chirp_detected:
            self.on_chirp_detected(event)

    def get_status(self):
        return {
            'running': self._running,
            'total_detections': self.total_detections,
            'history': self.detection_history[-10:],
            'last_rms': round(self._last_rms, 5),
            'last_band_ratios': [round(r, 3) for r in self._last_ratios],
            'last_dominant_band': self._last_dominant,
            'device': self._device_name,
        }


if __name__ == "__main__":
    print("ResQNet — Sequential 3-Band Sweep Engine")
    print(f"Bands: {BANDS}, {SEGMENT_DURATION_S}s each")
    print("=" * 50)
    d = ChirpDetector(on_chirp_detected=lambda e: print("[EMISSION CAPTURED]"))
    if d.start():
        try:
            while True:
                time.sleep(0.5)
        except KeyboardInterrupt:
            d.stop()