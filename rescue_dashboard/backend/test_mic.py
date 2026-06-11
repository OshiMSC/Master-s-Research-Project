"""
ResQNet — Microphone Test
==========================
Run this BEFORE starting Flask to verify mic is working.
Stop Flask first if it's running.

Run: python mic_test.py
"""

import numpy as np
import time
import sys

try:
    import pyaudio
except ImportError:
    print("pip install pyaudio"); sys.exit()

SAMPLE_RATE = 44100
CHUNK_SIZE  = 4096

audio = pyaudio.PyAudio()

print("ResQNet — Mic Test")
print("=" * 40)
print("\nAll input devices:")
for i in range(audio.get_device_count()):
    info = audio.get_device_info_by_index(i)
    if info['maxInputChannels'] > 0:
        print(f"  [{i:2d}] {info['name'][:50]}")

print("\nTesting each device for 1 second...\n")

working = []
for i in range(audio.get_device_count()):
    info = audio.get_device_info_by_index(i)
    if info['maxInputChannels'] < 1:
        continue
    try:
        s = audio.open(
            format=pyaudio.paInt16, channels=1,
            rate=SAMPLE_RATE, input=True,
            input_device_index=i,
            frames_per_buffer=CHUNK_SIZE)
        vals = []
        for _ in range(10):
            raw = s.read(CHUNK_SIZE, exception_on_overflow=False)
            d   = np.frombuffer(raw, dtype=np.int16).astype(np.float32)/32768
            vals.append(float(np.sqrt(np.mean(d**2))))
        s.stop_stream(); s.close()
        avg = sum(vals)/len(vals)
        mx  = max(vals)
        status = "✓ WORKING" if avg > 0.0001 else "⚠ SILENCE"
        print(f"  [{i:2d}] {status}  avg={avg:.6f}  max={mx:.6f}  {info['name'][:35]}")
        if avg > 0.0001:
            working.append((i, info['name'], avg))
    except Exception as e:
        print(f"  [{i:2d}] ✗ ERROR   {info['name'][:35]}  ({e})")

audio.terminate()

print()
if working:
    print(f"✓ {len(working)} working device(s) found:")
    for idx, name, rms in working:
        print(f"    [{idx}] {name[:50]}  RMS={rms:.6f}")
    best = max(working, key=lambda x: x[2])
    print(f"\n  Best device: [{best[0]}] {best[1][:50]}")
    print(f"\nNow run: python app.py")
    print("Then play chirp on phone — it should detect!")
else:
    print("✗ No working microphone found!")
    print("  → Close Teams/Discord/Zoom/any app using the mic")
    print("  → Check Settings → Privacy → Microphone → Allow")
    print("  → Restart the terminal and try again")