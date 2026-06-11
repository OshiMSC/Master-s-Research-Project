"""
ResQNet — Find correct microphone device
Tests each input device at multiple sample rates
Run: python find_working_mic.py
"""
import numpy as np
try:
    import pyaudio
except ImportError:
    print("pip install pyaudio")
    exit()

CHUNK = 4096
RATES = [44100, 16000, 48000, 22050]

audio = pyaudio.PyAudio()

print("ResQNet — Microphone Scanner")
print("=" * 60)
print("Testing all input devices at multiple sample rates...")
print("Make NOISE near laptop mic while this runs!\n")

working = []

for i in range(audio.get_device_count()):
    info = audio.get_device_info_by_index(i)
    if info['maxInputChannels'] < 1:
        continue
    name = info['name']
    
    for rate in RATES:
        try:
            stream = audio.open(
                format=pyaudio.paInt16,
                channels=1,
                rate=rate,
                input=True,
                input_device_index=i,
                frames_per_buffer=CHUNK,
            )
            # Read 3 chunks and measure RMS
            rms_values = []
            for _ in range(3):
                raw = stream.read(CHUNK, exception_on_overflow=False)
                data = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
                rms_values.append(float(np.sqrt(np.mean(data**2))))
            
            stream.stop_stream()
            stream.close()
            
            avg_rms = sum(rms_values) / len(rms_values)
            # Skip stereo mix (has constant non-zero signal even in silence)
            is_stereo_mix = 'Stereo Mix' in name or 'stereo mix' in name.lower()
            
            status = '✓ WORKS'
            if avg_rms < 0.00001:
                status = '✗ SILENCE'
            elif is_stereo_mix:
                status = '⚠ STEREO MIX (not real mic)'
            
            print(f"  Device {i:2d} @ {rate}Hz: {status}  RMS={avg_rms:.5f}  [{name[:40]}]")
            
            if avg_rms > 0.00001 and not is_stereo_mix:
                working.append((i, rate, avg_rms, name))
            break  # found working rate for this device
            
        except Exception as e:
            if rate == RATES[-1]:  # only print error on last attempt
                print(f"  Device {i:2d}: ✗ FAILED  [{name[:40]}]")

audio.terminate()

print()
print("=" * 60)
if working:
    # Sort by RMS (highest = most sensitive to real sound)
    working.sort(key=lambda x: x[2], reverse=True)
    print("RECOMMENDED DEVICES (highest RMS = most responsive to sound):")
    for idx, rate, rms, name in working[:3]:
        print(f"  INPUT_DEVICE_INDEX = {idx}  SAMPLE_RATE = {rate}")
        print(f"  Name: {name}")
        print(f"  RMS:  {rms:.5f}")
        print()
    best = working[0]
    print(f"USE THIS IN chirp_detector.py:")
    print(f"  INPUT_DEVICE_INDEX = {best[0]}")
    print(f"  SAMPLE_RATE = {best[1]}")
else:
    print("No working real microphones found!")
    print("Close Teams/Zoom/Discord and try again")