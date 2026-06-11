"""
ResQNet — Frequency Scanner
============================
Plays test tones through laptop speaker and measures
which frequencies the Intel mic actually captures.

BUT since we can't play through laptop speakers easily,
this script instead analyses what frequencies the mic
picks up FROM THE PHONE when you hold it close.

Run while playing different sounds from your phone:
  - Normal speech
  - Music  
  - The chirp beacon
  - A whistle

Instructions:
  1. Run this script
  2. Hold phone near laptop mic
  3. Play different sounds
  4. Watch which frequencies show HIGH energy
"""

import numpy as np
import pyaudio
import time

SAMPLE_RATE  = 44100
CHUNK_SIZE   = 8192
DEVICE_INDEX = 5

audio  = pyaudio.PyAudio()
stream = audio.open(
    format=pyaudio.paInt16, channels=1,
    rate=SAMPLE_RATE, input=True,
    input_device_index=DEVICE_INDEX,
    frames_per_buffer=CHUNK_SIZE)

# Frequency bands to monitor
BANDS = [
    (200,  400,  '200-400Hz  (low rumble)'),
    (400,  800,  '400-800Hz  (voice low) '),
    (800,  1600, '800-1.6kHz (voice mid) '),
    (1600, 2400, '1.6-2.4kHz (voice high)'),
    (2400, 3200, '2.4-3.2kHz (upper voice)'),
    (3200, 4000, '3.2-4.0kHz (chirp zone)'),
    (4000, 5000, '4.0-5.0kHz (above voice)'),
    (5000, 8000, '5.0-8.0kHz (high)      '),
]

print("ResQNet — Frequency Scanner")
print("=" * 60)
print("Hold phone near laptop mic and play sounds")
print("Watch which frequency bands light up")
print("Press Ctrl+C to stop\n")
print(f"{'Band':<30} {'Level':>8}  {'Bar'}")
print("-" * 60)

chunk_count = 0
while True:
    try:
        raw   = stream.read(CHUNK_SIZE, exception_on_overflow=False)
        audio_data = np.frombuffer(raw, dtype=np.int16).astype(np.float32)/32768
        rms   = float(np.sqrt(np.mean(audio_data**2)))
        chunk_count += 1

        if chunk_count % 3 != 0:
            continue

        # FFT
        w    = np.hanning(len(audio_data))
        fft  = np.abs(np.fft.rfft(audio_data * w))
        freq = np.fft.rfftfreq(len(audio_data), 1/SAMPLE_RATE)

        # Measure energy in each band
        results = []
        for lo, hi, name in BANDS:
            mask   = (freq >= lo) & (freq <= hi)
            energy = float(np.mean(fft[mask])) if np.any(mask) else 0
            results.append((name, energy))

        # Normalise to max band
        max_e = max(r[1] for r in results) + 1e-10

        # Print
        print(f"\033[{len(BANDS)+2}A")  # move cursor up
        print(f"RMS: {rms:.5f}  ({'SOUND!' if rms > 0.01 else 'quiet'})")
        print("-" * 60)
        for name, energy in results:
            norm = energy / max_e
            bar  = '█' * int(norm * 30)
            pct  = int(norm * 100)
            mark = ' ←' if pct > 60 else ''
            print(f"  {name}  {pct:>3}%  {bar:<30}{mark}   ")

    except KeyboardInterrupt:
        break

stream.stop_stream()
stream.close()
audio.terminate()
print("\n\nDone!")
