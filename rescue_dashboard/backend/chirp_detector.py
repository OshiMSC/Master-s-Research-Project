"""
ResQNet — Chirp Beacon Detector (Hardened Dynamic-RMS Engine)
============================================================
Optimized for: High Noise Baselines & Aggressive Audio Gain
"""

import numpy as np
import threading
import time
from datetime import datetime

try:
    import pyaudio
    PYAUDIO_AVAILABLE = True
except ImportError:
    PYAUDIO_AVAILABLE = False

# ── Settings ───────────────────────────────────────────────────
SAMPLE_RATE    = 44100
CHUNK_SIZE     = 4096
CHANNELS       = 1
DEVICE_INDEX   = 5      # Intel Smart Sound System Target

# ── Hardened Dynamic Gating Layout ─────────────────────────────
BG_MEMORY_CHUNKS = 20   # Larger moving window to smooth out sudden baseline drifts
SURGE_RATIO      = 2.50 # Hardened threshold: Must clear local baseline by 30%
REQUIRED_HITS    = 4    # Requiring 4 consecutive frames filters out room noise spikes
COOLDOWN_S       = 45  
DEBUG_MODE       = True
HARDCODED_THRESHOLD = 0.45


class ChirpDetector:

    def __init__(self, on_chirp_detected=None):
        self.on_chirp_detected = on_chirp_detected
        self._running          = False
        self._thread           = None
        self._audio            = None
        self._stream           = None
        self._consecutive_hits = 0
        self._last_event_time  = 0
        self.total_detections  = 0
        self.detection_history = []
        self._device_name      = 'Unknown'
        self._miss_count       = 0
        self._history_buffer   = []

    def _open_stream(self, audio, device_idx):
        return audio.open(
            format=pyaudio.paInt16, channels=CHANNELS,
            rate=SAMPLE_RATE, input=True,
            input_device_index=device_idx,
            frames_per_buffer=CHUNK_SIZE)

    def start(self):
        if not PYAUDIO_AVAILABLE:
            print("ChirpDetector: pyaudio library missing"); return False
        if self._running: return True
        try:
            self._audio = pyaudio.PyAudio()
            try:
                info = self._audio.get_device_info_by_index(DEVICE_INDEX)
                self._device_name = info['name']
            except:
                print(f"ChirpDetector: Device ID {DEVICE_INDEX} inaccessible."); return False

            self._stream = self._open_stream(self._audio, DEVICE_INDEX)
            
            print("  Seeding adaptive room audio footprint values...")
            for _ in range(10):
                raw = self._stream.read(CHUNK_SIZE, exception_on_overflow=False)
                d = np.frombuffer(raw, dtype=np.int16).astype(np.float32)/32768
                rms = float(np.sqrt(np.mean(d**2)))
                if rms > 0:
                    self._history_buffer.append(rms)

            self._running = True
            self._thread  = threading.Thread(target=self._listen_loop, daemon=True)
            self._thread.start()
            print(f"ChirpDetector: Adaptive Dynamic-RMS Engine Active (Hardened Mode) ✓\n")
            return True
        except Exception as e:
            print(f"ChirpDetector: Engine failed to spin up — {e}"); return False

    def stop(self):
        self._running = False
        try:
            if self._stream: self._stream.stop_stream(); self._stream.close()
            if self._audio:  self._audio.terminate()
        except: pass

    def _listen_loop(self):
        chunk_count = 0
        warmup_end  = time.time() + 1.0
        signal_must_drop = False  # <-- NEW: Track trailing edge of the sound wave

        while self._running:
            try:
                raw   = self._stream.read(CHUNK_SIZE, exception_on_overflow=False)
                audio = np.frombuffer(raw, dtype=np.int16).astype(np.float32)/32768
                
                rms   = float(np.sqrt(np.mean(audio**2)))
                now   = time.time()
                chunk_count += 1

                if now < warmup_end: continue

                if len(self._history_buffer) > 0:
                    current_baseline = float(np.median(self._history_buffer))
                else:
                    current_baseline = 0.25

                surge_detected = rms >= HARDCODED_THRESHOLD 
                in_cooldown = (now - self._last_event_time) < COOLDOWN_S

                # Baseline updates: Only update if it's genuinely quiet environment
                if not surge_detected and rms > 0 and not in_cooldown:
                    self._history_buffer.append(rms)
                    if len(self._history_buffer) > BG_MEMORY_CHUNKS:
                        self._history_buffer.pop(0)

                # Track if the continuous loud sound has finally stopped
                if signal_must_drop and not surge_detected:
                    signal_must_drop = False  # Room quieted down! Safe to arm.

                # Cooldown handling
                # ── HARDENED COOLDOWN HANDLER ────────────────────────────
                if in_cooldown:
                    self._consecutive_hits = 0
                    self._miss_count = 0
                    
                    # UI rendering update for tracking active cooldown state
                    if DEBUG_MODE and (chunk_count % 4 == 0):
                        current_baseline = float(np.median(self._history_buffer)) if len(self._history_buffer) > 0 else 0.25
                        cd = f' [cd {int(COOLDOWN_S - (now - self._last_event_time))}s]'
                        print(f"\r  RMS:{rms:.4f} (Base:{current_baseline:.4f}) hits:0/{REQUIRED_HITS} 🔒 MUTED{cd}          ", end='', flush=True)
                    
                    # CRITICAL FIX: Skip evaluating hits while the alarm or echoes are active
                    continue 

                # ── DETECTION ENGINE MATRIX ──────────────────────────────
                if surge_detected:
                    # --- FIX: Block processing if it's just the old sound lingering ---
                    if signal_must_drop:
                        self._consecutive_hits = 0
                        self._miss_count = 0
                    else:
                        self._consecutive_hits += 1
                        self._miss_count = 0
                        if self._consecutive_hits >= REQUIRED_HITS:
                            print()
                            self._last_event_time = now
                            self._consecutive_hits = 0
                            self._miss_count = 0
                            signal_must_drop = True  # <-- Lock system until audio drops
                            self._trigger()
                else:
                    self._miss_count += 1
                    if self._miss_count > 1:
                        self._consecutive_hits = 0
                        self._miss_count = 0

                # UI rendering
                if DEBUG_MODE and (surge_detected or chunk_count % 4 == 0):
                    bar_len = int(min(rms * 40, 20))
                    bar     = '█' * bar_len + '░' * (20 - bar_len)
                    mark    = '★ LOCK' if signal_must_drop else ('★ SURGE' if surge_detected else '       ')
                    cd      = f' [cd {int(COOLDOWN_S-(now-self._last_event_time))}s]' if in_cooldown else ''
                    print(f"\r  RMS:{rms:.4f} (Base:{current_baseline:.4f}) hits:{self._consecutive_hits}/{REQUIRED_HITS} {mark}{cd}          ", end='', flush=True)

            except Exception as e:
                if self._running: print(f"\nChirpDetector execution warning: {e}")
                time.sleep(0.04)

    def _trigger(self):
        self.total_detections += 1
        event = {
            'id':        int(time.time() * 1000),
            'type':      'CHIRP_BEACON',
            'timestamp': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
            'message':   'ResQNet acoustic chirp beacon detected',
            'count':     self.total_detections,
        }
        self.detection_history.append(event)
        if len(self.detection_history) > 50:
            self.detection_history.pop(0)
        print(f"*** CHIRP BEACON DETECTED! *** total={self.total_detections}  at {event['timestamp']}")
        if self.on_chirp_detected:
            self.on_chirp_detected(event)

    def get_status(self):
        current_baseline = float(np.median(self._history_buffer)) if self._history_buffer else 0.25
        return {
            'running':          self._running,
            'total_detections': self.total_detections,
            'history':          self.detection_history[-10:],
            'threshold':        round(current_baseline * SURGE_RATIO, 5),
            'baseline_rms':     round(current_baseline, 5),
            'device':           self._device_name,
        }


if __name__ == "__main__":
    print("ResQNet — Hardened Adaptive Engine")
    print("=" * 50)
    d = ChirpDetector(on_chirp_detected=lambda e: print(f"\n[EMISSION CAPTURED]"))
    if d.start():
        try:
            while True: time.sleep(0.5)
        except KeyboardInterrupt:
            d.stop()