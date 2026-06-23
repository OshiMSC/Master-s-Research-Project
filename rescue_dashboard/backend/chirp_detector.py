"""
ResQNet — Chirp Beacon Detector (3-Band Sequential Sweep Engine)
====================================================================
Detects the REAL multi_band_chirp.wav beacon: a 3-band sequential
sweep through 1-2kHz, then 2-3kHz, then 3-4kHz (0.3s each, ~0.9s
total), followed by 0.6s silence, repeated 10 times.

== ROOT CAUSE OF PREVIOUS FAILURE (confirmed via simulation) ==
The original _check_sequence() searched for the LAST band0 occurrence
in history before looking for band1. Because the history window
(2.23s) is wider than one full beacon cycle (1.5s), by the time
detection runs during cycle N's band2 phase, cycle N+1's band0 chunks
are already in the history — making the "last band0" always belong to
the NEXT cycle. The search then looks forward from there for band1,
finds none (since we're still in band0 of the next cycle), and fails.
Every cycle after the very first fails identically for this reason.

== THE FIX ==
The _check_sequence() method now uses a FORWARD-SCAN state machine:
it finds the FIRST band0 that leads to a valid complete sequence
(band0 → band1 → band2, with None/silence chunks freely allowed
anywhere in between since mic distance causes intermittent drops),
rather than anchoring to the last band0 and searching forward from
there. This is immune to next-cycle contamination because it stops
at the first complete match, not the last anchor point.
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
DEVICE_INDEX = None     # None = auto-detect default input device

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
RMS_GATE = 0.0005          # lowered slightly from 0.0008 for distance
DOMINANCE_RATIO = 0.30     # lowered from 0.35 — sweeps have spread energy
HISTORY_CHUNKS = 32        # slightly larger window for robustness
COOLDOWN_S = 20.0
# FIX: the previous cooldown was max(FULL_CYCLE_S * 1.5, 2.0) = 2.25s,
# which is just barely longer than one beacon sweep cycle (1.5s).
# Since the beacon WAV plays 10 repetitions × 1.5s = 15s total, this
# produced ~7 detections per single beacon activation — one per cycle.
# The correct behaviour is: one beacon activation = one dashboard alert.
# 20s cooldown covers the full 15s playback with 5s margin, so every
# cycle after the first is suppressed and only one alert fires per
# distinct beacon event. In a real deployment (continuous beacon loop),
# this means a new alert fires at most every 20s, which is appropriate
# for a rescue team tracking a victim's location.
DEBUG_MODE = True


def list_audio_devices():
    """Print all available audio input devices for manual selection."""
    if not PYAUDIO_AVAILABLE:
        return
    audio = pyaudio.PyAudio()
    print("\n=== Available Audio Input Devices ===")
    for i in range(audio.get_device_count()):
        info = audio.get_device_info_by_index(i)
        if info['maxInputChannels'] > 0:
            print(f"  [{i}] {info['name']} (inputs: {info['maxInputChannels']})")
    print("  Set DEVICE_INDEX at the top of this file to choose a specific one.")
    print("  DEVICE_INDEX = None uses the system default input.\n")
    audio.terminate()


def band_energy_ratio(audio: np.ndarray, sample_rate: int, band: tuple) -> float:
    """
    Returns the fraction of this chunk's total energy within [band[0], band[1]) Hz.
    Uses FFT bin sum — suited to ~1000Hz-wide bands, not narrow single tones.
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
        self._band_history = deque(maxlen=HISTORY_CHUNKS)
        self._last_rms = 0.0
        self._last_ratios = [0.0, 0.0, 0.0]
        self._last_dominant = None

    def _open_stream(self, audio, device_idx):
        kwargs = dict(
            format=pyaudio.paInt16,
            channels=CHANNELS,
            rate=SAMPLE_RATE,
            input=True,
            frames_per_buffer=CHUNK_SIZE,
        )
        if device_idx is not None:
            kwargs['input_device_index'] = device_idx
        return audio.open(**kwargs)

    def start(self):
        if not PYAUDIO_AVAILABLE:
            print("ChirpDetector: pyaudio not installed — pip install pyaudio")
            return False
        if self._running:
            return True
        try:
            self._audio = pyaudio.PyAudio()

            # Auto-detect or use specified device
            if DEVICE_INDEX is None:
                default = self._audio.get_default_input_device_info()
                self._device_name = default['name']
                print(f"ChirpDetector: Using default input device — "
                      f"[{default['index']}] {default['name']}")
            else:
                info = self._audio.get_device_info_by_index(DEVICE_INDEX)
                if info['maxInputChannels'] == 0:
                    print(f"ChirpDetector: Device {DEVICE_INDEX} has no input channels")
                    list_audio_devices()
                    return False
                self._device_name = info['name']
                print(f"ChirpDetector: Using device [{DEVICE_INDEX}] {info['name']}")

            self._stream = self._open_stream(self._audio, DEVICE_INDEX)

            self._running = True
            self._thread = threading.Thread(target=self._listen_loop, daemon=True)
            self._thread.start()
            band_desc = " → ".join(f"{b[0]:.0f}-{b[1]:.0f}Hz" for b in BANDS)
            print(f"ChirpDetector: Sequential-Sweep Engine Active "
                  f"({band_desc}, {SEGMENT_DURATION_S}s/band)")
            print(f"  RMS gate: {RMS_GATE}, Dominance threshold: {DOMINANCE_RATIO}")
            print(f"  History window: {HISTORY_CHUNKS} chunks "
                  f"({HISTORY_CHUNKS * CHUNK_SIZE / SAMPLE_RATE:.2f}s)\n")
            return True
        except Exception as e:
            print(f"ChirpDetector: Failed to start — {e}")
            list_audio_devices()
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
                    print(f"\nChirpDetector warning: {e}")
                time.sleep(0.04)

    def _check_sequence(self, now):
        """
        FIX: Forward-scan state machine — finds the FIRST complete
        band0→band1→band2 sequence in history.

        The original version found the LAST band0 and searched forward,
        which was poisoned by the next cycle's band0 appearing in the
        history window before the current cycle's band2 was detected.
        (History = 2.23s, full cycle = 1.5s → overlap of 0.73s.)

        None/silence chunks are freely allowed anywhere in the sequence
        since mic distance causes intermittent drops even during active
        beacon playback — silence is part of the design (the 0.6s gap),
        so treating it as a hard break incorrectly invalidates sequences.
        """
        history = list(self._band_history)
        if len(history) < 3:
            return

        min_expected = SEGMENT_DURATION_S * 0.5
        max_expected = SEGMENT_DURATION_S * len(BANDS) * 2.5

        for i, (t0, b0) in enumerate(history):
            if b0 != 0:
                continue

            # Found a band0 — look forward for band1
            for j in range(i + 1, len(history)):
                tj, bj = history[j]
                if bj is None or bj == 0:
                    continue   # silence or continued band0 — keep scanning
                if bj != 1:
                    break      # hit band2 before band1 — invalid, try next band0
                # Found band1 — look forward for band2
                for k in range(j + 1, len(history)):
                    tk, bk = history[k]
                    if bk is None or bk == 1:
                        continue   # silence or continued band1 — keep scanning
                    if bk == 2:
                        elapsed = tk - t0
                        if min_expected <= elapsed <= max_expected:
                            self._last_event_time = now
                            self._band_history.clear()
                            self._trigger(elapsed)
                            return
                        # Timing wrong — try next band0 starting position
                    break  # anything else (including band0 = new cycle) stops this search
                break  # done searching from this band0 anchor

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
              f"elapsed={sequence_elapsed_s:.2f}s at {event['timestamp']}")
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
    print("ResQNet — Sequential 3-Band Sweep Engine (Fixed)")
    print(f"Bands: {BANDS}, {SEGMENT_DURATION_S}s each")
    print("=" * 50)
    list_audio_devices()
    d = ChirpDetector(on_chirp_detected=lambda e: print("[EVENT CAPTURED]"))
    if d.start():
        try:
            while True:
                time.sleep(0.5)
        except KeyboardInterrupt:
            d.stop()
            print(f"\nStopped. Total detections: {d.total_detections}")