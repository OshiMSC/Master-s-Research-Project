"""
ResQNet — WAV File Direct Inspector
======================================
Reads the multi_band_chirp.wav file DIRECTLY (no mic, no speaker, no
room) and reports:
  1. The file's own declared sample rate / channels / bit depth
  2. The actual dominant frequencies in its raw samples

This bypasses the entire playback chain (phone speaker, room acoustics,
laptop mic) to answer one question precisely: does the WAV file ITSELF
actually contain 3200Hz + 4500Hz tones, or was something already wrong
before the sound ever left the phone's speaker?

The live recording showed dominant peaks at ~11025Hz and ~22050Hz —
which are exactly 44100/4 and 44100/2. That's a strong signature of a
sample-rate mismatch somewhere in the chain (e.g. a WAV authored at a
different rate than assumed during playback, or a naive resample
introducing an aliased image). This script settles whether the WAV
file itself is the source.

USAGE:
    python inspect_chirp_wav.py path/to/multi_band_chirp.wav

If you don't have the file on this machine, pull it off the phone's
assets first, e.g. via:
    adb shell run-as <package> cat /data/data/<package>/.../assets/flutter_assets/assets/audio/multi_band_chirp.wav > multi_band_chirp.wav
(exact asset extraction path varies — easiest is usually to grab the
original file from your Flutter project's assets/audio/ folder
directly, since it's a build input, not something generated at
runtime.)
"""

import sys
import wave
import numpy as np

if len(sys.argv) < 2:
    print("Usage: python inspect_chirp_wav.py <path_to_wav>")
    sys.exit(1)

path = sys.argv[1]

with wave.open(path, 'rb') as wf:
    n_channels = wf.getnchannels()
    sample_rate = wf.getframerate()
    sample_width = wf.getsampwidth()
    n_frames = wf.getnframes()
    duration = n_frames / sample_rate

    print("=" * 70)
    print(f"WAV FILE HEADER: {path}")
    print("=" * 70)
    print(f"Declared sample rate : {sample_rate} Hz")
    print(f"Channels             : {n_channels}")
    print(f"Bit depth            : {sample_width * 8}-bit")
    print(f"Frame count          : {n_frames}")
    print(f"Duration             : {duration:.3f} s")
    print()

    raw = wf.readframes(n_frames)

# Convert based on actual bit depth found in the header
if sample_width == 2:
    audio = np.frombuffer(raw, dtype=np.int16).astype(np.float64) / 32768.0
elif sample_width == 1:
    audio = np.frombuffer(raw, dtype=np.uint8).astype(np.float64)
    audio = (audio - 128) / 128.0
elif sample_width == 4:
    audio = np.frombuffer(raw, dtype=np.int32).astype(np.float64) / 2147483648.0
else:
    print(f"Unsupported sample width: {sample_width} bytes")
    sys.exit(1)

# If stereo, take just the first channel for analysis
if n_channels > 1:
    audio = audio[0::n_channels]

print(f"RMS of raw file samples: {np.sqrt(np.mean(audio**2)):.4f}")
print()

# FFT using the WAV's OWN declared sample rate — this is the ground truth
fft_vals = np.abs(np.fft.rfft(audio))
freqs = np.fft.rfftfreq(len(audio), d=1.0 / sample_rate)

mask = freqs > 50
peak_indices = np.argsort(fft_vals[mask])[::-1][:10]
peak_freqs = freqs[mask][peak_indices]
peak_mags = fft_vals[mask][peak_indices]

print("Top 10 dominant frequencies in the RAW FILE (using its own "
      f"declared rate of {sample_rate}Hz):")
print(f"{'Frequency (Hz)':>15}  {'Relative Magnitude':>20}")
max_mag = peak_mags.max() if len(peak_mags) else 1
for f, m in sorted(zip(peak_freqs, peak_mags), key=lambda x: -x[1]):
    bar = '#' * int(30 * m / max_mag)
    print(f"{f:>15.1f}  {m:>20.1f}  {bar}")

print()
for target in (3200, 4500):
    idx = np.argmin(np.abs(freqs - target))
    nearby = fft_vals[max(0, idx - 5):idx + 6]
    pct = 100 * nearby.max() / max_mag
    print(f"Energy near {target}Hz: peak={nearby.max():.1f} "
          f"({pct:.1f}% of the file's own dominant peak)")

print()
print("=" * 70)
print("INTERPRETATION")
print("=" * 70)
if sample_rate != 44100:
    print(f"*** FOUND IT: this WAV's own header declares "
          f"{sample_rate}Hz, NOT 44100Hz. ***")
    print(f"If something in the playback chain (audioplayers, the OS "
          f"media pipeline, or the phone's audio HAL) plays this file "
          f"assuming/forcing {44100}Hz instead of respecting its actual "
          f"{sample_rate}Hz rate, every frequency in it gets scaled by "
          f"a factor of {44100/sample_rate:.4f}x when it comes out the "
          f"speaker. A tone authored at 3200Hz would actually play at "
          f"~{3200 * 44100 / sample_rate:.0f}Hz, and 4500Hz would play "
          f"at ~{4500 * 44100 / sample_rate:.0f}Hz — which would "
          f"explain the live recording showing energy somewhere other "
          f"than where chirp_detector.py is listening.")
else:
    print("This WAV's header correctly declares 44100Hz, matching the "
          "detector's assumption. If 3200Hz/4500Hz are still weak here "
          "(in the RAW FILE, before any playback), the WAV's actual "
          "audio CONTENT doesn't match what chirp_service.dart's "
          "comments/code claim it should be — i.e. the file itself was "
          "generated incorrectly, independent of any playback or "
          "capture issue. Check whatever script/tool generated "
          "multi_band_chirp.wav originally.")
