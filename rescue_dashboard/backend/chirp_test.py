"""
ResQNet — Chirp Signal Diagnostic
==================================
Run this WHILE playing the chirp from the phone.
Shows detailed frequency analysis to understand
what the laptop mic is actually receiving.

Run: python chirp_test.py
"""

import numpy as np
import time
import sys

try:
    import pyaudio
except ImportError:
    print("pip install pyaudio"); sys.exit()

SAMPLE_RATE = 44100
CHUNK_SIZE  = 8192
DEVICE_INDEX = 5   # Intel Smart Sound (best real mic)

TARGET_FREQS = [3200, 4500]  # what phone plays

print("ResQNet Chirp Diagnostic")
print("=" * 55)
print(f"Device: [{DEVICE_INDEX}] Intel Smart Sound Technology")
print(f"Looking for: {TARGET_FREQS} Hz")
print()
print("Instructions:")
print("  1. Wait for 'LISTENING' message")
print("  2. Play chirp on phone, hold near laptop mic")
print("  3. Watch the ratio values")
print("  4. Press Ctrl+C to stop")
print()

audio  = pyaudio.PyAudio()
stream = audio.open(
    format=pyaudio.paInt16, channels=1,
    rate=SAMPLE_RATE, input=True,
    input_device_index=DEVICE_INDEX,
    frames_per_buffer=CHUNK_SIZE)

print("LISTENING — play chirp now...")
print()
print(f"{'RMS':>10}  {'3200Hz ratio':>14}  {'4500Hz ratio':>14}  {'Max':>8}")
print("-" * 55)

max_3200 = 0
max_4500 = 0
chunk_count = 0

try:
    while True:
        raw = stream.read(CHUNK_SIZE, exception_on_overflow=True)
        audio_data = np.frombuffer(raw, dtype=np.int16).astype(np.float32)/32768
        rms   = float(np.sqrt(np.mean(audio_data**2)))

        # FFT
        w    = np.hanning(len(audio_data))
        fft  = np.abs(np.fft.rfft(audio_data * w))
        freq = np.fft.rfftfreq(len(audio_data), 1/SAMPLE_RATE)
        norm = fft / (np.max(fft) + 1e-10)

        ratios = {}
        for f in TARGET_FREQS:
            tol = 200
            off = 500
            wid = 200
            chirp = float(np.max(norm[(freq >= f-tol) & (freq <= f+tol)]) if np.any((freq >= f-tol) & (freq <= f+tol)) else 0)
            lo    = float(np.max(norm[(freq >= f-off-wid) & (freq <= f-off+wid)]) if np.any((freq >= f-off-wid) & (freq <= f-off+wid)) else 0)
            hi    = float(np.max(norm[(freq >= f+off-wid) & (freq <= f+off+wid)]) if np.any((freq >= f+off-wid) & (freq <= f+off+wid)) else 0)
            ratios[f] = chirp / ((lo+hi)/2 + 1e-6)

        r32 = ratios[3200]
        r45 = ratios[4500]
        max_3200 = max(max_3200, r32)
        max_4500 = max(max_4500, r45)
        chunk_count += 1

        # Show every chunk
        flag = " *** HIGH ***" if r32 > 1.5 or r45 > 1.5 else ""
        print(f"  RMS:{rms:.5f}  3200Hz:{r32:6.3f}  4500Hz:{r45:6.3f}  max({max_3200:.2f},{max_4500:.2f}){flag}")

        # Every 20 chunks show summary
        if chunk_count % 20 == 0:
            print(f"\n  --- SUMMARY after {chunk_count} chunks ---")
            print(f"  Peak 3200Hz ratio: {max_3200:.3f}")
            print(f"  Peak 4500Hz ratio: {max_4500:.3f}")
            if max_3200 > 1.5 or max_4500 > 1.5:
                print("  → Signal IS detectable! Use threshold below peak")
            else:
                print("  → Signal not reaching mic — move phone closer")
            print()

except KeyboardInterrupt:
    print(f"\n\nFINAL RESULTS:")
    print(f"  Total chunks: {chunk_count}")
    print(f"  Peak 3200Hz:  {max_3200:.3f}")
    print(f"  Peak 4500Hz:  {max_4500:.3f}")
    if max_3200 > 1.3 or max_4500 > 1.3:
        safe_thresh = min(max_3200, max_4500) * 0.7
        print(f"\n  RECOMMENDED threshold: {safe_thresh:.2f}")
        print(f"  Set in chirp_detector.py:")
        print(f"    self._peak_ratio = {safe_thresh:.2f}")
    else:
        print("\n  Signal too weak — mic cannot detect phone chirp")
        print("  Options:")
        print("    1. Use USB microphone")  
        print("    2. Use phone self-report (phone confirms beacon active)")

finally:
    stream.stop_stream()
    stream.close()
    audio.terminate()
