"""
ResQNet — Live Chirp Frequency Analyzer
==========================================
Run this WHILE playing the chirp from the phone near the laptop mic.
It records a few seconds of real audio and reports the actual dominant
frequencies it sees — telling us definitively whether the captured
signal really contains energy near 3200Hz/4500Hz, or whether it's
showing up somewhere else entirely (which would explain why the
Goertzel band-ratio check in chirp_detector.py reads 0.00 even with
healthy RMS).

This does NOT touch chirp_detector.py's detection logic — it's a
read-only diagnostic using the same capture settings.

Usage:
    python analyze_real_chirp.py
    (then play the chirp from the phone near the laptop mic during
    the 5-second recording window)
"""

import pyaudio
import numpy as np

SAMPLE_RATE  = 44100   # must match chirp_detector.py
CHUNK_SIZE   = 4096    # must match chirp_detector.py
DEVICE_INDEX = 5       # must match chirp_detector.py
RECORD_SECONDS = 5

p = pyaudio.PyAudio()

try:
    info = p.get_device_info_by_index(DEVICE_INDEX)
    print(f"Recording from: {info['name']}")
    print(f"Device default sample rate: {info['defaultSampleRate']}")
    print(f"Requesting capture at: {SAMPLE_RATE}Hz")
    print()
except Exception as e:
    print(f"Could not get device info for index {DEVICE_INDEX}: {e}")
    p.terminate()
    raise SystemExit(1)

stream = p.open(
    format=pyaudio.paInt16,
    channels=1,
    rate=SAMPLE_RATE,
    input=True,
    input_device_index=DEVICE_INDEX,
    frames_per_buffer=CHUNK_SIZE,
)

print(f"Recording {RECORD_SECONDS} seconds now — PLAY THE CHIRP NOW...")
frames = []
n_chunks = int(SAMPLE_RATE / CHUNK_SIZE * RECORD_SECONDS)
for i in range(n_chunks):
    data = stream.read(CHUNK_SIZE, exception_on_overflow=False)
    frames.append(np.frombuffer(data, dtype=np.int16))

stream.stop_stream()
stream.close()
p.terminate()

audio = np.concatenate(frames).astype(np.float64) / 32768.0
print(f"\nCaptured {len(audio)} samples ({len(audio)/SAMPLE_RATE:.2f}s)")
print(f"Overall RMS: {np.sqrt(np.mean(audio**2)):.4f}")

# Full FFT over the whole recording — find where the energy actually is.
fft_vals = np.abs(np.fft.rfft(audio))
freqs    = np.fft.rfftfreq(len(audio), d=1.0/SAMPLE_RATE)

# Find the top 10 peaks by magnitude (excluding near-DC/very low freq, which
# is usually room rumble / mic self-noise, not signal of interest).
mask = freqs > 100
peak_indices = np.argsort(fft_vals[mask])[::-1][:10]
peak_freqs = freqs[mask][peak_indices]
peak_mags  = fft_vals[mask][peak_indices]

print("\nTop 10 dominant frequencies across the whole recording:")
print(f"{'Frequency (Hz)':>15}  {'Relative Magnitude':>20}")
max_mag = peak_mags.max() if len(peak_mags) else 1
for f, m in sorted(zip(peak_freqs, peak_mags), key=lambda x: -x[1]):
    bar = '#' * int(30 * m / max_mag)
    print(f"{f:>15.1f}  {m:>20.1f}  {bar}")

print("\n--- Expected (per chirp_service.dart) ---")
print("3200 Hz and 4500 Hz should both appear strongly above.")
print("If they don't, the WAV's real frequency content (as captured by")
print("THIS mic, through THIS playback chain) doesn't match what")
print("chirp_detector.py is configured to look for.")

# Specifically report energy right around the two target bins.
for target in (3200, 4500):
    idx = np.argmin(np.abs(freqs - target))
    nearby = fft_vals[max(0, idx-5):idx+6]
    print(f"\nEnergy near {target}Hz (+/- ~{5*SAMPLE_RATE/len(audio):.0f}Hz): "
          f"peak magnitude = {nearby.max():.1f} "
          f"(compare to overall max = {fft_vals[mask].max():.1f})")
