"""
ResQNet — Frequency Scanner
=============================
Scans all frequencies 500Hz-8000Hz and finds which ones
have the LOWEST background noise on your laptop mic.
These are the best frequencies to use for chirp detection.

Run:
  python find_best_frequencies.py

Output:
  List of frequencies with lowest background noise
  → Use these in chirp_service.dart and chirp_detector.py
"""

import numpy as np
import time

try:
    import pyaudio
    PYAUDIO_AVAILABLE = True
except ImportError:
    print("pip install pyaudio")
    exit()

SAMPLE_RATE = 44100
CHUNK_SIZE  = 8192
SCAN_SECS   = 3     # seconds to sample per run

print("ResQNet — Frequency Scanner")
print("=" * 50)
print("This finds the best frequencies for chirp detection")
print("on YOUR specific laptop microphone.")
print()
print("STEP 1: Make sure room is quiet (no chirp playing)")
print("Press Enter when ready to scan background noise...")
input()

# Record background noise
audio_obj = pyaudio.PyAudio()
stream    = audio_obj.open(
    format=pyaudio.paInt16, channels=1,
    rate=SAMPLE_RATE, input=True,
    frames_per_buffer=CHUNK_SIZE)

print(f"Recording {SCAN_SECS} seconds of background noise...")
n_chunks  = int(SAMPLE_RATE * SCAN_SECS / CHUNK_SIZE)
all_ffts  = []

for i in range(n_chunks):
    raw   = stream.read(CHUNK_SIZE, exception_on_overflow=False)
    audio = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    fft_vals = np.abs(np.fft.rfft(audio * np.hanning(len(audio))))
    freqs    = np.fft.rfftfreq(len(audio), 1.0 / SAMPLE_RATE)
    fft_norm = fft_vals / (np.max(fft_vals) + 1e-10)
    all_ffts.append(fft_norm)
    print(f"\r  Sampling... {i+1}/{n_chunks}", end='', flush=True)

print("\nDone!")

# Average background spectrum
avg_fft = np.mean(all_ffts, axis=0)
freqs   = np.fft.rfftfreq(CHUNK_SIZE, 1.0 / SAMPLE_RATE)

# Find frequencies between 500Hz and 8000Hz
mask = (freqs >= 500) & (freqs <= 8000)
freq_subset   = freqs[mask]
energy_subset = avg_fft[mask]

# Find the 20 quietest frequency bands (100Hz wide)
candidates = []
for center in range(500, 8000, 100):
    band_mask  = (freq_subset >= center-50) & (freq_subset <= center+50)
    if np.any(band_mask):
        band_energy = float(np.mean(energy_subset[band_mask]))
        candidates.append((center, band_energy))

candidates.sort(key=lambda x: x[1])  # sort by energy (quietest first)

print()
print("=" * 50)
print("QUIETEST FREQUENCIES ON YOUR LAPTOP MIC:")
print("(lower energy = less background noise = better for detection)")
print()
print(f"  {'Frequency':>10}  {'Background Energy':>20}  Quality")
print("  " + "-" * 50)

for freq, energy in candidates[:15]:
    if energy < 0.1:
        quality = "EXCELLENT ✓"
    elif energy < 0.2:
        quality = "GOOD ✓"
    elif energy < 0.4:
        quality = "OK"
    else:
        quality = "NOISY ✗"
    print(f"  {freq:>8} Hz   {energy:>18.4f}   {quality}")

print()
print("=" * 50)
print("RECOMMENDATION:")
print("Pick 2-3 frequencies from the EXCELLENT or GOOD list")
print("that are at least 300Hz apart from each other.")
print()

# Suggest best pair
excellent = [(f, e) for f, e in candidates if e < 0.2]
if len(excellent) >= 2:
    # Find pair at least 300Hz apart
    best_pair = None
    for i in range(len(excellent)):
        for j in range(i+1, len(excellent)):
            f1, f2 = excellent[i][0], excellent[j][0]
            if abs(f1 - f2) >= 300:
                best_pair = (f1, f2)
                break
        if best_pair:
            break

    if best_pair:
        print(f"BEST PAIR FOR YOUR LAPTOP: {best_pair[0]}Hz and {best_pair[1]}Hz")
        print()
        print(f"Update in chirp_service.dart:")
        print(f"  const List<double> _chirpFrequencies = [{best_pair[0]}, {best_pair[1]}];")
        print()
        print(f"Update in chirp_detector.py:")
        print(f"  CHIRP_FREQUENCIES = [{best_pair[0]}, {best_pair[1]}]")
    else:
        print("No ideal pair found — try frequencies:")
        for f, e in excellent[:3]:
            print(f"  {f} Hz (energy={e:.4f})")
else:
    print("Your laptop has high background noise across all frequencies.")
    print("Best available frequencies:")
    for f, e in candidates[:5]:
        print(f"  {f} Hz (energy={e:.4f})")

stream.stop_stream()
stream.close()
audio_obj.terminate()

print()
print("After updating frequencies restart Flask and test again.")
